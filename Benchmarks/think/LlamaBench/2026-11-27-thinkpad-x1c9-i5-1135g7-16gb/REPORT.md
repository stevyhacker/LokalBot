# llama-bench on a ThinkPad X1 Carbon Gen 9 (i5-1135G7, 16 GB, Iris Xe), Linux

Hardware row for the "Contribute Hardware Benchmarks" request (#623): the two pinned models on `llama-bench`, CPU and Vulkan.

## Machine and build

- **Machine:** Lenovo ThinkPad X1 Carbon Gen 9, 11th Gen Intel Core i5-1135G7 (4 cores, 8 threads), 16 GB RAM (15,708 MB usable), Intel Iris Xe Graphics (TGL GT2, integrated, shared memory).
- **OS:** Ubuntu 24.04.5 LTS, kernel 7.0.0-43-generic, Mesa 25.2.8 (Intel open-source Vulkan driver).
- **llama.cpp:** release `b12774` (build 12774, commit 171527522), the version the Linux port pins. Official `llama-b12774-bin-ubuntu-x64.tar.gz` (SHA-256 `ab5837cca2317cfb7ecb5f85b550934e7355cd9df74cdde6e106581457034dbb`) for CPU and `llama-b12774-bin-ubuntu-vulkan-x64.tar.gz` (SHA-256 `75b7044df1232bd5bc78ffc753f14a5a44d9f3b5c67228b6103705c57084d02d`) for Vulkan. LokalBot checkout `532f21f8`.
- **Models:** `Qwen3.5-4B-LokalBot-v4-Q4_K_M.gguf` (SHA-256 `678f3d49c92ece8cd9425bad9e30cd626d35149b00f5dc2b661cb78ad9346ab0`) and `Gemma-4-E2B-LokalBot-v4-i1-Q6_K.gguf` (SHA-256 `ea8c01dd28abaae0a6664eb9c1324f6bf6cd0ffef99dace496510f7cceb40581`), at the revisions the port's catalog pins.
- **Power and load:** on AC, `balanced` power profile for sweeps 1 and 2, lid closed, `powersave` governor (the Ubuntu default, not changed), desktop session idle, no other heavy job. 4 threads (the llama-bench default).
- **Command:** `llama-bench -m MODEL -ngl 0|99 -p 512,4096 -n 128 -r N -o json` under `/usr/bin/time -v` for peak RSS. `run.sh` beside this file downloads, verifies and runs everything.

## Result (sweep 2: 5 repetitions, 3 minutes idle before each run)

| Model | Backend | pp512 t/s | pp4096 t/s | tg128 t/s | Peak RSS (GB) | CPU temp at start |
| --- | --- | --- | --- | --- | --- | --- |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, opening | 54.9 ± 7.9 | 37.5 ± 2.7 | 8.3 ± 2.2 | 4.37 | 45 °C |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | Vulkan, all layers | 158.1 ± 0.3 | 85.9 ± 6.8 | 7.9 ± 1.8 | 0.20 | 43 °C |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, closing | 55.7 ± 5.3 | 36.7 ± 1.9 | 8.5 ± 2.0 | 4.36 | 43 °C |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, opening | 441.8 ± 7.6 | 234.9 ± 45.1 | 16.4 ± 0.2 | 3.81 | 44 °C |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | Vulkan, all layers | 455.7 ± 0.5 | 123.9 ± 29.5 | 9.1 ± 1.7 | 0.23 | 46 °C |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, closing | 436.7 ± 7.2 | 234.8 ± 43.7 | 14.4 ± 3.2 | 3.81 | 43 °C |

## What it shows

- **Qwen3.5 4B:** Vulkan on the Iris Xe prefills about 2.9 times faster than CPU at 512 tokens (158 vs 55 t/s) and 2.3 times faster at 4,096 (86 vs 37 t/s). Decode is no faster (7.9 vs 8.3 to 8.5 t/s, inside the run-to-run spread).
- **Gemma 4 E2B:** Vulkan is level with a cool CPU at 512 tokens (456 vs 437 to 442 t/s), about half the CPU's speed at 4,096 (124 vs 235 t/s), and slower at decode (9.1 vs 14.4 to 16.4 t/s).
- **Peak RSS** is the process's resident memory. With Vulkan the weights sit in memory shared with the integrated GPU, which RSS does not count, so the Vulkan figures are not the model's footprint.

## The `performance` power profile (sweep 3, incomplete)

Sweeps 1 and 2 ran on Ubuntu's default `balanced` power profile. Sweep 3 repeated sweep 2 with `powerprofilesctl set performance`. Four of its six runs completed:

| Model | Backend | pp512 t/s | pp4096 t/s | tg128 t/s |
| --- | --- | --- | --- | --- |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU | 62.4 ± 2.2 | 46.7 ± 4.1 | 9.1 ± 0.1 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | Vulkan, all layers | 158.0 ± 0.3 | 103.1 ± 10.2 | 8.5 ± 0.1 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU | 431.0 ± 7.6 | 309.6 ± 6.3 | 17.3 ± 1.9 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | Vulkan, all layers | 434.7 ± 1.1 | 129.9 ± 1.4 | 13.4 ± 0.2 |

- **CPU prefill on long prompts is about 25 to 30% faster** than on `balanced` (Qwen pp4096 46.7 vs 37 t/s, Gemma pp4096 310 vs 235 t/s). Decode moves little (Qwen 9.1 vs 8.4 t/s, Gemma 17.3 vs 15.4 t/s). Vulkan prefill at 512 tokens is unchanged.
- **The laptop could not hold it.** During the first attempt at the fifth run the kernel logged `critical temperature reached` and `HARDWARE PROTECTION shutdown (Temperature too high)` and powered the machine off; the lid was closed and another running laptop was stacked on top of it. Resumed with the lid open and a temperature guard, the fifth run completed, and the guard stopped the sixth (the closing CPU pass) 30 seconds in, at 96 °C on the ACPI thermal zone. So this sweep has no closing baseline, and its Vulkan rows come from two sessions.
- The lid was also closed, with the other laptop on top, during sweeps 1 and 2, which will have cost them some sustained throughput.

## Thermal behaviour (why there are two sweeps)

Sweep 1 ran the six runs back to back with 3 repetitions. Its CPU numbers moved with how warm the laptop already was: Gemma's CPU pp512 was 184 t/s straight after Qwen's eight-minute CPU run, against 437 to 442 t/s from a cool start in sweep 2, and Qwen's closing CPU pass fell to 38 t/s at pp512 (samples 51, 35, 29) against 52 in the opening pass. Sweep 2 added a 3-minute idle before every run and 5 repetitions, and its opening and closing CPU passes agree. The samples inside a CPU run still decline as it heats (tables below), so sustained CPU throughput on this laptop is lower than a short burst. Frequency and power limits were not logged during the runs, so the thermal explanation is an inference from the start temperatures and the order of the runs.

### Sweep 1 (3 repetitions, back to back)

| Model | Backend | pp512 t/s | pp4096 t/s | tg128 t/s | Peak RSS (GB) | CPU temp at start |
| --- | --- | --- | --- | --- | --- | --- |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, opening | 52.1 ± 2.9 | 38.3 ± 2.8 | 10.0 ± 1.6 | 4.37 | 64 °C |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | Vulkan, all layers | 158.5 ± 0.1 | 91.6 ± 16.5 | 6.5 ± 1.5 | 0.23 | 59 °C |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, closing | 38.5 ± 11.7 | 36.4 ± 2.0 | 6.9 ± 1.4 | 4.38 | 62 °C |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, opening | 183.8 ± 0.5 | 220.4 ± 61.1 | 15.3 ± 2.2 | 3.80 | 60 °C |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | Vulkan, all layers | 431.7 ± 0.6 | 104.7 ± 14.5 | 8.4 ± 0.9 | 0.35 | 62 °C |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, closing | 232.5 ± 73.5 | 200.8 ± 48.6 | 16.6 ± 0.2 | 3.81 | 57 °C |

### Per-repetition samples, sweep 2

| Model | Backend | Test | Samples (t/s) |
| --- | --- | --- | --- |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, opening | pp512 | 65.1, 61.5, 49.4, 50.4, 48.0 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, opening | pp4096 | 40.8, 35.8, 39.9, 34.4, 36.5 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, opening | tg128 | 6.8, 10.9, 10.4, 7.3, 6.2 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | Vulkan, all layers | pp512 | 158.3, 158.3, 158.3, 158.1, 157.6 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | Vulkan, all layers | pp4096 | 88.4, 81.2, 94.8, 87.7, 77.4 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | Vulkan, all layers | tg128 | 9.6, 6.8, 5.7, 7.5, 9.6 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, closing | pp512 | 61.9, 60.5, 54.9, 50.3, 51.0 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, closing | pp4096 | 37.9, 37.3, 35.0, 39.0, 34.5 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, closing | tg128 | 10.2, 10.9, 8.2, 6.1, 7.2 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, opening | pp512 | 451.9, 445.9, 441.8, 437.2, 432.2 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, opening | pp4096 | 271.8, 263.6, 266.4, 197.0, 175.6 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, opening | tg128 | 16.7, 16.6, 16.3, 16.3, 16.2 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | Vulkan, all layers | pp512 | 455.6, 455.7, 456.6, 455.4, 455.2 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | Vulkan, all layers | pp4096 | 161.2, 90.8, 142.8, 98.8, 126.0 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | Vulkan, all layers | tg128 | 8.7, 7.9, 7.9, 9.0, 12.0 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, closing | pp512 | 444.8, 441.9, 437.9, 431.3, 427.5 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, closing | pp4096 | 280.1, 242.6, 265.9, 170.2, 215.1 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, closing | tg128 | 16.7, 16.5, 16.4, 13.2, 9.3 |

### Per-repetition samples, sweep 1

| Model | Backend | Test | Samples (t/s) |
| --- | --- | --- | --- |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, opening | pp512 | 55.5, 50.1, 50.7 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, opening | pp4096 | 38.8, 40.8, 35.3 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, opening | tg128 | 11.0, 10.8, 8.1 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | Vulkan, all layers | pp512 | 158.5, 158.4, 158.6 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | Vulkan, all layers | pp4096 | 89.6, 76.3, 109.0 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | Vulkan, all layers | tg128 | 5.7, 5.7, 8.2 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, closing | pp512 | 51.4, 35.4, 28.7 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, closing | pp4096 | 34.5, 38.5, 36.2 |
| Qwen3.5-4B-LokalBot-v4-Q4_K_M | CPU, closing | tg128 | 8.6, 6.1, 6.0 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, opening | pp512 | 183.3, 183.7, 184.3 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, opening | pp4096 | 269.8, 239.2, 152.1 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, opening | tg128 | 12.8, 16.6, 16.5 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | Vulkan, all layers | pp512 | 432.3, 431.1, 431.8 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | Vulkan, all layers | pp4096 | 110.4, 88.3, 115.5 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | Vulkan, all layers | tg128 | 7.8, 8.0, 9.5 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, closing | pp512 | 182.8, 197.7, 316.9 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, closing | pp4096 | 246.3, 149.6, 206.5 |
| Gemma-4-E2B-LokalBot-v4-i1-Q6_K | CPU, closing | tg128 | 16.8, 16.5, 16.5 |

The JSON files in `sweep-1/`, `sweep-2/` and `sweep-3-performance/` hold the unmodified `llama-bench` rows plus peak RSS and wall time.
