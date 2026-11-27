## TL;DR
The team chose Redis for caching and deferred cluster mode pending a failover benchmark.

## Decisions
- Adopt Redis for the caching layer (pub-sub support won the comparison).
- Session store stays in Postgres for now; one migration at a time.

## Action items
- [ ] Draft the eviction-policy document by Thursday — Me
- [ ] Benchmark failover latency before committing to cluster mode — Them

## Open questions
- Do we need Redis cluster mode at launch, or can it wait?