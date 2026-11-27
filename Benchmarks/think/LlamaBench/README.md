# llama-bench hardware rows

`llama-bench` throughput for the two pinned models on machines other than the M4 Max baseline, as asked for in [Contribute Hardware Benchmarks](../../README.md#contribute-hardware-benchmarks). Every row uses `llama.cpp` release `b12774`, `Qwen3.5-4B-LokalBot-v4-Q4_K_M.gguf` and `Gemma-4-E2B-LokalBot-v4-i1-Q6_K.gguf`, `-p 512,4096 -n 128 -r 5`. Each folder has its own `REPORT.md` with the machine, build, checksums, per-repetition samples, the raw `llama-bench` JSON and the script that produced it.

Tokens per second (prefill at 512 and 4,096 tokens, decode over 128):

| Machine | Backend | Qwen3.5 4B pp512 | pp4096 | tg128 | Gemma 4 E2B pp512 | pp4096 | tg128 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| [MacBook Pro, M4 Pro, 48 GB](2026-11-27-macbook-pro-m4-pro-48gb/REPORT.md) | Metal | 799 | 768 | 67.6 | 4,200 | 4,011 | 94.8 |
| | CPU, 10 threads | 255 | 196 | 51.0 | 1,120 | 891 | 76.9 |
| [ThinkPad X1 Carbon Gen 13, Core Ultra 7 258V, 32 GB, Linux](2026-11-27-thinkpad-x1c13-ultra7-258v-32gb/REPORT.md) | Vulkan (Arc 140V) | 457 | 383 | 11.4 | 1,506 | 1,300 | 9.0 |
| | CPU, 8 threads | 60 | 47 | 10.3 | 500 | 319 | 23.9 |
| | CPU, 2 threads (default) | 29 | 23 | 8.5 | 240 | 167 | 14.9 |
| [ThinkPad X1 Carbon Gen 9, i5-1135G7, 16 GB, Linux](2026-11-27-thinkpad-x1c9-i5-1135g7-16gb/REPORT.md) | Vulkan (Iris Xe) | 158 | 86 | 7.9 | 456 | 124 | 9.1 |
| | CPU, 4 threads (default) | 55 | 37 | 8.4 | 442 | 235 | 16.4 |

What stands out on the two Intel laptops:

- **Vulkan prefills fast and decodes slowly.** On the Core Ultra 7 it prefills Qwen 7 to 8 times faster than 8 CPU threads but decodes no faster, and for Gemma the CPU decodes more than twice as fast as the GPU. On the M4 Pro, Metal is faster at both.
- **The default thread count is low on the Core Ultra 7.** `llama-bench` picked 2 of 8 cores; 8 threads doubled prefill.
- **The i5 laptop is heat-limited.** Its numbers depend on how warm it already is, and on the `performance` power profile it shut itself down. Its report has the details.
