#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
BENCH=$PWD
TAG=b12774
REL=https://github.com/ggml-org/llama.cpp/releases/download/$TAG
CPU_TGZ=llama-$TAG-bin-ubuntu-x64.tar.gz
CPU_SHA=ab5837cca2317cfb7ecb5f85b550934e7355cd9df74cdde6e106581457034dbb
VK_TGZ=llama-$TAG-bin-ubuntu-vulkan-x64.tar.gz
VK_SHA=75b7044df1232bd5bc78ffc753f14a5a44d9f3b5c67228b6103705c57084d02d
QWEN=Qwen3.5-4B-LokalBot-v4-Q4_K_M.gguf
QWEN_URL=https://huggingface.co/stevyhacker/Qwen3.5-4B-LokalBot-GGUF/resolve/b7c9e3308abcf996350e35c9dc97d9590bf6a00a/$QWEN
QWEN_SHA=678f3d49c92ece8cd9425bad9e30cd626d35149b00f5dc2b661cb78ad9346ab0
GEMMA=Gemma-4-E2B-LokalBot-v4-i1-Q6_K.gguf
GEMMA_URL=https://huggingface.co/stevyhacker/Gemma-4-E2B-LokalBot-GGUF/resolve/e089648312aee558514a13dbbd4efb19a0b3eb25/$GEMMA
GEMMA_SHA=ea8c01dd28abaae0a6664eb9c1324f6bf6cd0ffef99dace496510f7cceb40581
mkdir -p dl models runtime/cpu runtime/vulkan results
log() { echo "[$(date +%T)] $*"; }

fetch() { # url dest sha
  if [ -f "$2" ] && [ "$(sha256sum "$2" | cut -d' ' -f1)" = "$3" ]; then log "have $2"; return 0; fi
  log "download $2"; curl -fL --retry 3 -C - -o "$2" "$1" || return 1
  [ "$(sha256sum "$2" | cut -d' ' -f1)" = "$3" ] || { log "SHA MISMATCH $2"; return 1; }
}
fetch "$REL/$CPU_TGZ" dl/$CPU_TGZ $CPU_SHA || exit 1
fetch "$REL/$VK_TGZ" dl/$VK_TGZ $VK_SHA || exit 1
fetch "$QWEN_URL" models/$QWEN $QWEN_SHA || exit 1
fetch "$GEMMA_URL" models/$GEMMA $GEMMA_SHA || exit 1
for b in cpu vulkan; do
  tgz=$CPU_TGZ; [ $b = vulkan ] && tgz=$VK_TGZ
  [ -x runtime/$b/llama-$TAG/llama-bench ] || tar -xzf dl/$tgz -C runtime/$b
done
BIN_cpu=runtime/cpu/llama-$TAG
BIN_vulkan=runtime/vulkan/llama-$TAG

VK_OK=0
LD_LIBRARY_PATH=$BIN_vulkan $BIN_vulkan/llama-bench --list-devices > results/vulkan-devices.txt 2>&1
log "vulkan devices:"; cat results/vulkan-devices.txt
grep -qi 'Vulkan' results/vulkan-devices.txt && grep -qiE 'Intel|Iris' results/vulkan-devices.txt && VK_OK=1
BACKENDS="cpu"; [ $VK_OK = 1 ] && BACKENDS="cpu vulkan"

meta() { # file
  { echo "time: $(date -Is)"; echo "loadavg: $(cut -d' ' -f1-3 /proc/loadavg)"
    echo "ac_online: $(cat /sys/class/power_supply/A*/online /sys/class/power_supply/AC*/online 2>/dev/null | head -1)"
    echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
    echo "cpu_temp_c: $(for z in /sys/class/thermal/thermal_zone*; do t=$(cat $z/type); [ "$t" = x86_pkg_temp ] && echo $(( $(cat $z/temp) / 1000 )); done | head -1)"
    echo "cpu_mhz_now: $(awk '/cpu MHz/{s+=$4;n++}END{printf "%d",s/n}' /proc/cpuinfo)"; } > "$1"
}
env_for() { [ $1 = vulkan ] && echo "LD_LIBRARY_PATH=$BIN_vulkan" || echo "LD_LIBRARY_PATH=$BIN_cpu"; }
runbench() { # backend model out args...
  local be=$1 model=$2 out=$3; shift 3
  local bin=BIN_$be; bin=${!bin}
  local ngl=0; [ $be = vulkan ] && ngl=99
  env $(env_for $be) /usr/bin/time -v -o "$out.time" $bin/llama-bench -m models/$model -ngl $ngl "$@" -o json > "$out.raw" 2> "$out.err"
}

for be in $BACKENDS; do
  log "smoke $be"
  runbench $be $GEMMA results/smoke-$be -p 64 -n 16 -r 1 || log "SMOKE FAILED $be (see results/smoke-$be.err)"
done

SIZE_NOTE=results/size-notes.txt; : > $SIZE_NOTE
PASS=0
for pass in 1 2 3; do
  case $pass in 1) be=cpu;; 2) be=vulkan;; 3) be=cpu;; esac
  case " $BACKENDS " in *" $be "*) ;; *) continue;; esac
  tag=$be; [ $pass = 3 ] && tag=cpu-closing
  for model in $QWEN $GEMMA; do
    out=results/${model%.gguf}.$tag
    [ -s $out.json ] && { log "have $out.json"; continue; }
    meta $out.meta
    if [ $be = cpu ]; then
      rate=$(python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(int([r for r in d if r.get("n_prompt")==64][0]["avg_ts"]))' results/smoke-cpu.raw 2>/dev/null || echo 0)
    fi
    log "run $out"
    if [ $be = cpu ] && [ "${rate:-0}" -gt 0 ] && [ $((4096 / rate)) -gt 1800 ]; then
      echo "$out: pp4096 reduced to -r 1 (est $((4096/rate))s/run)" >> $SIZE_NOTE
      runbench $be $model $out.a -p 512 -n 128 -r 3 && runbench $be $model $out.b -p 4096 -n 0 -r 1
      python3 -I -c 'import json,sys
r=json.load(open(sys.argv[1]))+json.load(open(sys.argv[2]));json.dump(r,open(sys.argv[3],"w"))' $out.a.raw $out.b.raw $out.raw
      cat $out.a.time $out.b.time > $out.time
    else
      runbench $be $model $out -p 512,4096 -n 128 -r 3
    fi
    rc=$?
    python3 -I - "$out" <<'PY'
import json, os, sys
out = sys.argv[1]
try:
    d = json.load(open(out + ".raw"))
except Exception as e:
    print("no json for", out, e); sys.exit(0)
for r in d:
    r["model_filename"] = os.path.basename(r.get("model_filename", ""))
rss = 0
for line in open(out + ".time"):
    if "Maximum resident set size" in line:
        rss = max(rss, int(line.split(":")[1]))
    if "Elapsed (wall clock)" in line:
        wall = line.split("):", 1)[1].strip()
json.dump({"runs": d, "peak_rss_kb": rss, "wall": wall}, open(out + ".json", "w"), indent=1)
PY
    log "done $out rc=$rc"
  done
done
log "sweep finished; report via report step"
python3 -I - "$BENCH" <<'PY'
import json, glob, os, sys, subprocess
b = sys.argv[1]
r = os.path.join(b, "results")
rows = []
for f in sorted(glob.glob(r + "/*.json")):
    name = os.path.basename(f)[:-5]
    if name.startswith("smoke"): continue
    model, tag = name.rsplit(".", 1)
    d = json.load(open(f))
    cell = {}
    for x in d["runs"]:
        t = "pp%d" % x["n_prompt"] if x["n_prompt"] else "tg%d" % x["n_gen"]
        cell[t] = "%.2f ± %.2f" % (x["avg_ts"], x["stddev_ts"])
    rows.append((model, tag, cell, d["peak_rss_kb"], d["wall"], name))
open(os.path.join(b, "table.md"), "w").write("\n".join(
    "| %s | %s | %s | %s | %s | %.2f |" % (m, t, c.get("pp512", "-"), c.get("pp4096", "-"), c.get("tg128", "-"), rss / 1048576)
    for m, t, c, rss, w, n in rows) + "\n")
PY
