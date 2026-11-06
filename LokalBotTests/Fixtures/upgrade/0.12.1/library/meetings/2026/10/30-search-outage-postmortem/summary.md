## TL;DR
29-minute search outage from a stale cache after deploy; fix is versioned cache keys.

## Decisions
- Cache keys carry the index version from now on.

## Action items
- [ ] Fold versioned keys into the eviction-policy doc — Me