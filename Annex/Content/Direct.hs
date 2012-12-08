{- git-annex file content managing for direct mode
 -
 - Copyright 2010,2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Annex.Content.Direct (
	associatedFiles,
	unmodifed,
	updateCache,
	removeCache
) where

import Common.Annex
import qualified Git

import System.Posix.Types

{- Files in the tree that are associated with a key.
 -
 - When no known associated files exist, returns the gitAnnexLocation. -}
associatedFiles :: Key -> Annex [FilePath]
associatedFiles key = do
	mapping <- inRepo $ gitAnnexMapping key
	files <- liftIO $ catchDefaultIO [] $ lines <$> readFile mapping
	if null files
		then do
			l <- inRepo $ gitAnnexLocation key
			return [l]
		else do
			top <- fromRepo Git.repoPath
			return $ map (top </>) files

{- Checks if a file in the tree, associated with a key, has not been modified.
 -
 - To avoid needing to fsck the file's content, which can involve an
 - expensive checksum, this relies on a cache that contains the file's
 - expected mtime and inode.
 -}
unmodifed :: Key -> FilePath -> Annex Bool
unmodifed key file = withCacheFile key $ \cachefile -> do
	curr <- getCache file
	old <- catchDefaultIO Nothing $ readCache <$> readFile cachefile
	return $ isJust curr && curr == old

{- Stores a cache of attributes for a file that is associated with a key. -}
updateCache :: Key -> FilePath -> Annex ()
updateCache key file = withCacheFile key $ \cachefile ->
	maybe noop (writeFile cachefile . showCache) =<< getCache file

{- Removes a cache. -}
removeCache :: Key -> Annex ()
removeCache key = withCacheFile key nukeFile

withCacheFile :: Key -> (FilePath -> IO a) -> Annex a
withCacheFile key a = liftIO . a =<< inRepo (gitAnnexCache key)

{- Cache a file's inode, size, and modification time to determine if it's
 - been changed. -}
data Cache = Cache FileID FileOffset EpochTime
  deriving (Eq)

showCache :: Cache -> String
showCache (Cache inode size mtime) = unwords
	[ show inode
	, show size
	, show mtime
	]

readCache :: String -> Maybe Cache
readCache s = case words s of
	(inode:size:mtime:_) -> Cache
		<$> readish inode
		<*> readish size
		<*> readish mtime
	_ -> Nothing

getCache :: FilePath -> IO (Maybe Cache)
getCache f = catchDefaultIO Nothing $ toCache <$> getFileStatus f

toCache :: FileStatus -> Maybe Cache
toCache s
	| isRegularFile s = Just $ Cache
		(fileID s)
		(fileSize s)
		(modificationTime s)
	| otherwise = Nothing