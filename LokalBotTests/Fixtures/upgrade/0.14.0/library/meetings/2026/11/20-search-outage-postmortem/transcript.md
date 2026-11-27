**[00:00] Me:** Timeline: deploy at 9:12, stale cache served until 9:41, search results were empty for 29 minutes.

**[00:18] Them:** Root cause was the cache key not including the index version.

**[00:36] Me:** Fix is versioned keys — and this feeds straight into the Redis eviction-policy doc.