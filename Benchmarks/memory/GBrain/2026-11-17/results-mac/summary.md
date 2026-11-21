<!-- Output of score.py on the Mac run (Apple M4 Max, 48 GB), copied from Local/gbrain-bench/summary.md in the run's worktree. Raw per-question files stayed on that Mac. -->
| run | questions | meeting R@1 | R@4 | R@10 | MRR | gold turn in Ask/agent evidence | median evidence chars | passage hit@1 | hit@5 | p50 ms | p95 ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| lokalbot-keyword | 1576 | 0.193 | 0.335 | 0.456 | 0.274 | 0.260 | 718 | 0.145 | 0.265 | 3 | 8 |
| gbrain-keyword | 1576 | 0.253 | 0.412 | 0.468 | 0.325 | 0.402 | 97444 | 0.190 | 0.314 | 159 | 212 |
| lokalbot-hybrid | 1576 | 0.280 | 0.475 | 0.595 | 0.379 | 0.367 | 1248 | 0.145 | 0.265 | 39 | 52 |
| gbrain-hybrid | 1576 | 0.239 | 0.367 | 0.370 | 0.295 | 0.340 | 96761 | 0.149 | 0.268 | 255 | 342 |

lokalbot-keyword - gbrain-keyword: r1 -0.060 [-0.084, -0.037], r4 -0.077 [-0.103, -0.054], evidence_hit -0.142 [-0.167, -0.119], p5 -0.049 [-0.073, -0.026]
lokalbot-keyword - lokalbot-hybrid: r1 -0.087 [-0.105, -0.069], r4 -0.140 [-0.161, -0.121], evidence_hit -0.107 [-0.124, -0.089], p5 -0.001 [-0.002, +0.000]
lokalbot-keyword - gbrain-hybrid: r1 -0.046 [-0.069, -0.022], r4 -0.032 [-0.058, -0.007], evidence_hit -0.080 [-0.106, -0.055], p5 -0.004 [-0.029, +0.022]
gbrain-keyword - lokalbot-hybrid: r1 -0.027 [-0.049, -0.003], r4 -0.063 [-0.088, -0.038], evidence_hit +0.036 [+0.011, +0.061], p5 +0.049 [+0.025, +0.072]
gbrain-keyword - gbrain-hybrid: r1 +0.015 [-0.008, +0.036], r4 +0.046 [+0.023, +0.069], evidence_hit +0.062 [+0.038, +0.084], p5 +0.046 [+0.023, +0.069]
lokalbot-hybrid - gbrain-hybrid: r1 +0.041 [+0.019, +0.062], r4 +0.109 [+0.082, +0.133], evidence_hit +0.027 [+0.001, +0.051], p5 -0.003 [-0.028, +0.022]

| system | mode | current shown | stale shown | both shown, current first | items | chars | read p50 ms |
|---|---|---:|---:|---:|---:|---:|---:|
| lb | edit | 39/40 | 0/40 | 0/0 | 23.1 | 1989 | 0.13 |
| lb | restate | 39/40 | 40/40 | 28/39 | 23.4 | 1983 | 0.20 |
| lb | forget | 0/40 | 0/40 | 0/0 | 30.0 | 2001 | 0.06 |
| gb | edit | 40/40 | 0/40 | 0/0 | 50.0 | 6430 | 32.72 |
| gb | restate | 40/40 | 40/40 | 2/40 | 50.0 | 6347 | 36.10 |
| gb | forget | 0/40 | 0/40 | 0/0 | 40.0 | 4758 | 25.57 |

| run | newer in top 4 | older in top 4 | newer ranked above older | current in evidence | stale in evidence | current before stale |
|---|---:|---:|---:|---:|---:|---:|
| lb-before | 19/20 | 19/20 | 7/20 | 19/20 | 19/20 | 7/20 |
| lb-after | 19/20 | 0/20 | 19/20 | 19/20 | 0/20 | 19/20 |
| gb-before | 15/20 | 14/20 | 8/20 | 15/20 | 14/20 | 8/20 |
| gb-after | 19/20 | 0/20 | 19/20 | 19/20 | 0/20 | 19/20 |

Mean query ms: lokalbot-keyword 3.46, gbrain-keyword 158.4, lokalbot-hybrid 40.7, gbrain-hybrid 261.2.
Evidence rows the scorer could not map to transcript turns: LokalBot 0, gbrain-keyword 133, gbrain-hybrid 333.
Write ms per correction: LokalBot edit 0.080, restate 0.096, forget 0.0009 (in memory, before the encrypted save); GBrain edit 42.1, restate 39.9, forget 50.0 (MCP round trip).
