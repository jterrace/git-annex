{- git-annex assistant change tracking and committing
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -}

module Assistant.Committer where

import Common.Annex
import Assistant.ThreadedMonad
import qualified Annex.Queue
import qualified Git.Command
import qualified Command.Add
import Utility.ThreadScheduler

import Control.Concurrent.STM
import Data.Time.Clock

data ChangeType = PendingAddChange | LinkChange | RmChange | RmDirChange
	deriving (Show, Eq)

type ChangeChan = TChan Change

data Change = Change
	{ changeTime :: UTCTime
	, changeFile :: FilePath
	, changeType :: ChangeType
	}
	deriving (Show)

runChangeChan :: STM a -> IO a
runChangeChan = atomically

newChangeChan :: IO ChangeChan
newChangeChan = atomically newTChan

{- Handlers call this when they made a change that needs to get committed. -}
madeChange :: FilePath -> ChangeType -> Annex (Maybe Change)
madeChange f t = do
	-- Just in case the commit thread is not flushing the queue fast enough.
	when (t /= PendingAddChange) $
		Annex.Queue.flushWhenFull
	liftIO $ Just <$> (Change <$> getCurrentTime <*> pure f <*> pure t)

noChange :: Annex (Maybe Change)
noChange = return Nothing

{- Gets all unhandled changes.
 - Blocks until at least one change is made. -}
getChanges :: ChangeChan -> IO [Change]
getChanges chan = runChangeChan $ do
	c <- readTChan chan
	go [c]
	where
		go l = do
			v <- tryReadTChan chan
			case v of
				Nothing -> return l
				Just c -> go (c:l)

{- Puts unhandled changes back into the channel.
 - Note: Original order is not preserved. -}
refillChanges :: ChangeChan -> [Change] -> IO ()
refillChanges chan cs = runChangeChan $ mapM_ (writeTChan chan) cs

{- This thread makes git commits at appropriate times. -}
commitThread :: ThreadState -> ChangeChan -> IO ()
commitThread st changechan = runEvery (Seconds 1) $ do
	-- We already waited one second as a simple rate limiter.
	-- Next, wait until at least one change has been made.
	cs <- getChanges changechan
	-- Now see if now's a good time to commit.
	time <- getCurrentTime
	if shouldCommit time cs
		then do
			handleAdds st changechan cs
			void $ tryIO $ runThreadState st commitStaged
		else refillChanges changechan cs

{- If there are PendingAddChanges, the files have not yet actually been
 - added to the annex, and that has to be done now, before committing.
 -
 - Deferring the adds to this point causes batches to be bundled together,
 - which allows faster checking with lsof that the files are not still open
 - for write by some other process.
 -
 - When a file is added, Inotify will notice the new symlink. So this waits
 - for one new LinkChange to be received per file that's successfully
 - added, to ensure that its symlink has been staged before returning.
 -}
handleAdds :: ThreadState -> ChangeChan -> [Change] -> IO ()
handleAdds st changechan cs
	| null added = noop
	| otherwise = do
		r <- forM added $ catchBoolIO . runThreadState st . add
		let numadded = length $ filter id r
		handleAdds st changechan =<< waitforlinkchanges [] numadded
	where
		added = map changeFile $ filter isPendingAdd cs

		isPendingAdd (Change { changeType = PendingAddChange }) = True
		isPendingAdd _ = False
		isLinkChange (Change { changeType = LinkChange }) = True
		isLinkChange _ = False

		add file = do
			showStart "add" file
			handle file =<< Command.Add.ingest file

		handle _ Nothing = do
			showEndFail
			return False
		handle file (Just key) = do
			Command.Add.link file key True
			showEndOk
			return True

		waitforlinkchanges c n
			| n < 1 = return $ concat c
			| otherwise = do
				(done, rest) <- partition isLinkChange 
					<$> getChanges changechan
				let n' = (n - length done)
				waitforlinkchanges (rest:c) n'

commitStaged :: Annex ()
commitStaged = do
	Annex.Queue.flush
	inRepo $ Git.Command.run "commit"
		[ Param "--allow-empty-message"
		, Param "-m", Param ""
		-- Empty commits may be made if tree changes cancel
		-- each other out, etc
		, Param "--allow-empty"
		-- Avoid running the usual git-annex pre-commit hook;
		-- watch does the same symlink fixing, and we don't want
		-- to deal with unlocked files in these commits.
		, Param "--quiet"
		]

{- Decide if now is a good time to make a commit.
 - Note that the list of change times has an undefined order.
 -
 - Current strategy: If there have been 10 changes within the past second,
 - a batch activity is taking place, so wait for later.
 -}
shouldCommit :: UTCTime -> [Change] -> Bool
shouldCommit now changes
	| len == 0 = False
	| len > 10000 = True -- avoid bloating queue too much
	| length (filter thisSecond changes) < 10 = True
	| otherwise = False -- batch activity
	where
		len = length changes
		thisSecond c = now `diffUTCTime` changeTime c <= 1