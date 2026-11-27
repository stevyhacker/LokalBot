# llama-bench on a MacBook Pro (M4 Pro, 48 GB)

The same two pinned models and the same `llama.cpp` release as the two Linux laptop reports beside this one, so the three machines can be compared directly. Not one of the 8 to 24 GB Macs the hardware request asks for.

## Machine and build

- **Machine:** MacBook Pro (Mac16,8), Apple M4 Pro (14 cores: 10 performance, 4 efficiency), 48 GB, macOS 26.7.3.
- **llama.cpp:** release `b12774` (build 12774, commit 171527522), official `llama-b12774-bin-macos-arm64.tar.gz` (SHA-256 `70311c4751ed3221e63f47769327dd088d7400f76dcfb81c66ec843db165814d`). This is the upstream release build, not the runtime LokalBot's `fetch-llama.sh` builds for the app.
- **Models:** `Qwen3.5-4B-LokalBot-v4-Q4_K_M.gguf` (SHA-256 `678f3d49c92ece8cd9425bad9e30cd626d35149b00f5dc2b661cb78ad9346ab0`) and `Gemma-4-E2B-LokalBot-v4-i1-Q6_K.gguf` (SHA-256 `ea8c01dd28abaae0a6664eb9c1324f6bf6cd0ffef99dace496510f7cceb40581`).
- **Power and load:** on AC, in normal desktop use (other apps open), 5 repetitions, 1 minute idle before each run, one pass with no closing baseline.
- **Command:** `llama-bench -m MODEL -ngl 99|0 -p 512,4096 -n 128 -r 5 -o json` under `/usr/bin/time -l`. `run.sh` downloads, verifies and runs everything.

## Result

| Model | Backend | pp512 t/s | pp4096 t/s | tg128 t/s | Peak RSS (GB) |
| --- | --- | --- | --- | --- | --- |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | Metal, all layers | 799.1 ± 0.2 | 767.9 ± 6.9 | 67.6 ± 0.7 | 2.90 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU (-ngl 0), 10 threads | 254.7 ± 6.1 | 196.2 ± 9.4 | 51.0 ± 0.8 | 5.53 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | Metal, all layers | 4199.6 ± 100.5 | 4011.0 ± 2.8 | 94.8 ± 1.4 | 3.83 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU (-ngl 0), 10 threads | 1119.6 ± 6.1 | 891.2 ± 17.8 | 76.9 ± 0.7 | 5.68 |

## Per-repetition samples

| Model | Backend | Test | Samples (t/s) |
| --- | --- | --- | --- |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | Metal, all layers | pp512 | 798.9, 799.2, 799.4, 799.0, 799.1 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | Metal, all layers | pp4096 | 771.3, 771.3, 771.4, 769.9, 755.5 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | Metal, all layers | tg128 | 68.4, 67.1, 67.8, 68.1, 66.7 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU (-ngl 0), 10 threads | pp512 | 260.7, 258.8, 256.2, 252.7, 245.1 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU (-ngl 0), 10 threads | pp4096 | 205.2, 202.3, 200.5, 182.8, 190.2 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU (-ngl 0), 10 threads | tg128 | 50.4, 52.0, 50.4, 50.6, 51.8 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | Metal, all layers | pp512 | 4054.5, 4338.0, 4210.2, 4189.6, 4205.7 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | Metal, all layers | pp4096 | 4007.1, 4009.7, 4013.8, 4013.3, 4011.0 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | Metal, all layers | tg128 | 95.4, 95.2, 95.2, 92.2, 95.7 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU (-ngl 0), 10 threads | pp512 | 1114.6, 1122.2, 1129.2, 1116.1, 1115.9 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU (-ngl 0), 10 threads | pp4096 | 904.4, 903.2, 899.5, 887.0, 861.9 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU (-ngl 0), 10 threads | tg128 | 77.4, 77.6, 76.6, 77.1, 75.9 |
