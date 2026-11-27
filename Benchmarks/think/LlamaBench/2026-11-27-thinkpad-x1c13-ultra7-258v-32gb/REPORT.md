# llama-bench on a ThinkPad X1 Carbon Gen 13 (Core Ultra 7 258V, 32 GB, Intel Arc 140V), Linux

Hardware row for the "Contribute Hardware Benchmarks" request (#623): the two pinned models on `llama-bench`, CPU and Vulkan.

## Machine and build

- **Machine:** Lenovo ThinkPad X1 Carbon Gen 13, Intel Core Ultra 7 258V (Lunar Lake, 8 cores, 8 threads), 32 GB RAM (31,620 MB usable), integrated Intel Arc graphics (reported by Vulkan as "Intel(R) Graphics (LNL)", shared memory).
- **OS:** Ubuntu 24.04.5 LTS, kernel 6.17.0-1033-oem, Mesa 25.2.8 (Intel open-source Vulkan driver).
- **llama.cpp:** release `b12774` (build 12774, commit 171527522), the version the Linux port pins. Official `llama-b12774-bin-ubuntu-x64.tar.gz` (SHA-256 `ab5837cca2317cfb7ecb5f85b550934e7355cd9df74cdde6e106581457034dbb`) for CPU and `llama-b12774-bin-ubuntu-vulkan-x64.tar.gz` (SHA-256 `75b7044df1232bd5bc78ffc753f14a5a44d9f3b5c67228b6103705c57084d02d`) for Vulkan.
- **Models:** `Qwen3.5-4B-LokalBot-v4-Q4_K_M.gguf` (SHA-256 `678f3d49c92ece8cd9425bad9e30cd626d35149b00f5dc2b661cb78ad9346ab0`) and `Gemma-4-E2B-LokalBot-v4-i1-Q6_K.gguf` (SHA-256 `ea8c01dd28abaae0a6664eb9c1324f6bf6cd0ffef99dace496510f7cceb40581`), at the revisions the port's catalog pins.
- **Power and load:** on AC, `performance` power profile with the `powersave` governor (intel_pstate), lid closed, 5 repetitions, 3 minutes idle before every run.
- **Not a clean machine:** another llama-server with a 35B model loaded on the GPU stayed running, idle, through all runs. It held about 16 GB of the memory the integrated GPU shares (Vulkan reported 7.4 of 23.7 GB free), and its CPU time was recorded before and after each run to confirm it served no request meanwhile (it did not). Numbers on an otherwise empty machine could be higher.
- **Command:** `llama-bench -m MODEL -ngl 0|99 [-t N] -p 512,4096 -n 128 -r 5 -o json` under `/usr/bin/time -v` for peak RSS. `run.sh` is the sweep, `threads.sh` the extra CPU thread counts.

## Result

| Model | Backend | pp512 t/s | pp4096 t/s | tg128 t/s | Peak RSS (GB) | CPU temp at start |
| --- | --- | --- | --- | --- | --- | --- |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, 2 threads (default), opening | 29.5 ± 1.2 | 23.2 ± 0.7 | 8.5 ± 0.5 | 4.30 | 38 °C |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | Vulkan, all layers | 457.1 ± 9.0 | 383.3 ± 5.8 | 11.4 ± 0.0 | 0.34 | 47 °C |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, 2 threads (default), closing | 27.4 ± 1.1 | 22.2 ± 0.5 | 8.7 ± 0.3 | 4.38 | 47 °C |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, 4 threads (-t 4) | 39.0 ± 2.7 | 30.8 ± 0.7 | 11.8 ± 0.3 | 4.38 | 45 °C |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, 8 threads (-t 8) | 59.7 ± 5.9 | 47.1 ± 5.0 | 10.3 ± 4.8 | 4.38 | 49 °C |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, 2 threads (default), opening | 240.4 ± 3.8 | 167.3 ± 4.8 | 14.9 ± 0.5 | 3.81 | 50 °C |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | Vulkan, all layers | 1505.6 ± 8.7 | 1299.6 ± 4.0 | 9.0 ± 0.0 | 0.25 | 50 °C |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, 2 threads (default), closing | 239.2 ± 4.9 | 167.9 ± 5.9 | 14.6 ± 0.6 | 3.81 | 50 °C |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, 4 threads (-t 4) | 354.5 ± 7.1 | 228.6 ± 8.1 | 19.2 ± 1.3 | 3.82 | 50 °C |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, 8 threads (-t 8) | 500.0 ± 13.2 | 318.8 ± 16.7 | 23.9 ± 0.2 | 3.82 | 51 °C |

## What it shows

- **Vulkan prefill is fast:** 457 t/s at 512 tokens and 383 t/s at 4,096 on Qwen3.5 4B, and 1,506 / 1,300 t/s on Gemma 4 E2B, with almost no drop on the long prompt.
- **Vulkan decode is slow:** 11.4 t/s on Qwen and 9.0 t/s on Gemma, with no run-to-run spread. On Gemma the CPU decodes faster than the GPU at every thread count (14.9 t/s at 2 threads, 23.9 at 8).
- **The default thread count undersells the CPU.** `llama-bench` chose 2 threads on this 8-core chip. With `-t 8` Qwen prefill doubles (29 to 60 t/s at pp512) and Gemma decode goes from 14.9 to 23.9 t/s. Qwen decode at 8 threads was unstable (samples from 4.0 to 16.0 t/s); 4 threads gave a steady 11.8.
- **Peak RSS** is the process's resident memory. With Vulkan the weights sit in memory shared with the integrated GPU, which RSS does not count.
- **Heat:** the package temperature was 85 to 89 °C at the end of each run.

## Per-repetition samples

| Model | Backend | Test | Samples (t/s) |
| --- | --- | --- | --- |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, 2 threads (default), opening | pp512 | 31.3, 30.1, 29.3, 28.7, 28.3 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, 2 threads (default), opening | pp4096 | 24.1, 23.6, 23.0, 22.7, 22.5 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, 2 threads (default), opening | tg128 | 9.2, 8.6, 8.7, 8.1, 8.1 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | Vulkan, all layers | pp512 | 452.1, 457.3, 452.4, 451.1, 472.5 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | Vulkan, all layers | pp4096 | 386.3, 373.0, 385.7, 385.4, 385.9 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | Vulkan, all layers | tg128 | 11.4, 11.4, 11.4, 11.4, 11.4 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, 2 threads (default), closing | pp512 | 29.1, 27.7, 27.1, 26.6, 26.3 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, 2 threads (default), closing | pp4096 | 23.0, 22.4, 22.1, 21.9, 21.8 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, 2 threads (default), closing | tg128 | 9.0, 9.1, 8.8, 8.3, 8.5 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, 4 threads (-t 4) | pp512 | 42.8, 40.3, 38.9, 36.9, 36.0 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, 4 threads (-t 4) | pp4096 | 31.7, 31.2, 30.7, 30.4, 29.9 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, 4 threads (-t 4) | tg128 | 12.3, 11.3, 11.8, 11.8, 11.7 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, 8 threads (-t 8) | pp512 | 69.3, 61.3, 57.5, 55.8, 54.8 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, 8 threads (-t 8) | pp4096 | 51.6, 47.8, 47.6, 38.6, 49.9 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, 8 threads (-t 8) | tg128 | 14.0, 9.9, 4.0, 7.8, 16.0 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, 2 threads (default), opening | pp512 | 244.6, 243.7, 240.6, 236.9, 236.4 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, 2 threads (default), opening | pp4096 | 175.2, 167.8, 166.2, 164.9, 162.5 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, 2 threads (default), opening | tg128 | 15.3, 14.5, 15.4, 15.0, 14.4 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | Vulkan, all layers | pp512 | 1508.5, 1493.5, 1501.6, 1516.9, 1507.6 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | Vulkan, all layers | pp4096 | 1304.6, 1295.4, 1303.3, 1297.4, 1297.5 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | Vulkan, all layers | tg128 | 9.0, 9.0, 9.0, 9.0, 9.0 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, 2 threads (default), closing | pp512 | 245.2, 242.6, 239.0, 235.5, 233.4 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, 2 threads (default), closing | pp4096 | 175.5, 171.6, 167.6, 164.3, 160.5 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, 2 threads (default), closing | tg128 | 15.4, 15.2, 14.2, 14.0, 14.3 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, 4 threads (-t 4) | pp512 | 362.9, 359.1, 356.3, 348.0, 346.4 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, 4 threads (-t 4) | pp4096 | 241.4, 231.4, 224.3, 224.9, 221.1 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, 4 threads (-t 4) | tg128 | 20.5, 20.7, 18.7, 18.1, 17.9 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, 8 threads (-t 8) | pp512 | 511.9, 510.1, 505.1, 492.0, 480.9 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, 8 threads (-t 8) | pp4096 | 344.8, 324.8, 314.4, 306.3, 303.8 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, 8 threads (-t 8) | tg128 | 23.6, 23.8, 23.9, 24.1, 24.2 |

The JSON files in `sweep/` and `threads/` hold the unmodified `llama-bench` rows plus peak RSS.
