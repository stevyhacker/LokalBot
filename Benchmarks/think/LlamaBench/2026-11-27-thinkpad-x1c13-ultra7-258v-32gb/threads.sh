#!/bin/bash
cd "$(dirname "$0")"; mkdir -p results-threads
BIN=runtime/cpu/llama-b12774
for t in 4 8; do for m in Qwen3.5-4B-LokalBot-v4-Q4_K_M Gemma-4-E2B-LokalBot-v4-i1-Q6_K; do
  out=results-threads/$m.cpu-t$t; [ -s $out.raw ] && continue
  sleep 180
  { echo "time: $(date -Is)"; echo "loadavg: $(cut -d" " -f1-3 /proc/loadavg)"; echo "cpu_temp_c: $(for z in /sys/class/thermal/thermal_zone*; do [ "$(cat $z/type)" = x86_pkg_temp ] && echo $(( $(cat $z/temp)/1000 )); done | head -1)"; echo "other_llama_server_cpu_ticks: $(for p in $(pgrep -x llama-server); do awk "{print \$14+\$15}" /proc/$p/stat; done | paste -sd+ | bc)"; } > $out.meta
  echo "[$(date +%T)] run $out"
  LD_LIBRARY_PATH=$BIN /usr/bin/time -v -o $out.time $BIN/llama-bench -m models/$m.gguf -ngl 0 -t $t -p 512,4096 -n 128 -r 5 -o json > $out.raw 2> $out.err
  echo "other_llama_server_cpu_ticks_after: $(for p in $(pgrep -x llama-server); do awk "{print \$14+\$15}" /proc/$p/stat; done | paste -sd+ | bc)" >> $out.meta
  echo "[$(date +%T)] done $out rc=$?"
done; done
echo "[$(date +%T)] threads finished"
