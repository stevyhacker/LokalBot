| run | questions | meeting R@1 | R@4 | R@10 | MRR | gold turn in Ask/agent evidence | median evidence chars | passage hit@1 | hit@5 | p50 ms | p95 ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| lokalbot-keyword | 1576 | 0.193 | 0.335 | 0.456 | 0.274 | 0.260 | 718 | 0.145 | 0.265 | 6 | 17 |
| gbrain-keyword | 1576 | 0.253 | 0.412 | 0.468 | 0.325 | 0.402 | 97444 | 0.190 | 0.314 | 388 | 549 |

lokalbot-keyword - gbrain-keyword: r1 -0.060 [-0.084, -0.037], r4 -0.077 [-0.103, -0.054], evidence_hit -0.142 [-0.167, -0.119], p5 -0.049 [-0.073, -0.026]

| system | mode | current shown | stale shown | both shown, current first | items | chars | read p50 ms |
|---|---|---:|---:|---:|---:|---:|---:|
| lb | edit | 39/40 | 0/40 | 0/0 | 23.1 | 1989 | 0.22 |
| lb | restate | 39/40 | 40/40 | 28/39 | 23.4 | 1983 | 0.32 |
| lb | forget | 0/40 | 0/40 | 0/0 | 30.0 | 2001 | 0.09 |
| gb | edit | 38/40 | 0/40 | 0/0 | 1.2 | 168 | 19.75 |
| gb | restate | 38/40 | 40/40 | 23/38 | 2.5 | 330 | 26.89 |
| gb | forget | 0/40 | 0/40 | 0/0 | 0.1 | 14 | 20.35 |

| run | newer in top 4 | older in top 4 | newer ranked above older | current in evidence | stale in evidence | current before stale |
|---|---:|---:|---:|---:|---:|---:|
| lb-before | 19/20 | 19/20 | 3/20 | 19/20 | 19/20 | 3/20 |
| lb-after | 19/20 | 0/20 | 19/20 | 19/20 | 0/20 | 19/20 |
| gb-before | 15/20 | 17/20 | 6/20 | 17/20 | 19/20 | 6/20 |
| gb-after | 15/20 | 0/20 | 19/20 | 19/20 | 0/20 | 19/20 |
