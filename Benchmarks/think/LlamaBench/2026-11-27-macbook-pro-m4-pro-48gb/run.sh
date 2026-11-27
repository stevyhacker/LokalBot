#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
TAG=b12774
log(){ echo "[$(date +%T)] $*"; }
QWEN=Qwen3.5-4B-LokalBot-v4-Q4_K_M.gguf
QWEN_URL=https://huggingface.co/stevyhacker/Qwen3.5-4B-LokalBot-GGUF/resolve/b7c9e3308abcf996350e35c9dc97d9590bf6a00a/$QWEN
QWEN_SHA=678f3d49c92ece8cd9425bad9e30cd626d35149b00f5dc2b661cb78ad9346ab0
GEMMA=Gemma-4-E2B-LokalBot-v4-i1-Q6_K.gguf
GEMMA_URL=https://huggingface.co/stevyhacker/Gemma-4-E2B-LokalBot-GGUF/resolve/e089648312aee558514a13dbbd4efb19a0b3eb25/$GEMMA
GEMMA_SHA=ea8c01dd28abaae0a6664eb9c1324f6bf6cd0ffef99dace496510f7cceb40581
mkdir -p dl models rt results
fetch(){ if [ -f "$2" ] && [ "$(shasum -a 256 "$2" | cut -d' ' -f1)" = "$3" ]; then log "have $2"; return 0; fi
  log "download $2"; curl -fsL --retry 3 -C - -o "$2" "$1" || return 1
  [ -z "$3" ] || [ "$(shasum -a 256 "$2" | cut -d' ' -f1)" = "$3" ] || { log "SHA MISMATCH $2"; return 1; }; }
fetch https://github.com/ggml-org/llama.cpp/releases/download/$TAG/llama-$TAG-bin-macos-arm64.tar.gz dl/llama-macos.tar.gz "" || exit 1
shasum -a 256 dl/llama-macos.tar.gz > results/llama-archive.sha256
fetch "$QWEN_URL" models/$QWEN $QWEN_SHA || exit 1
fetch "$GEMMA_URL" models/$GEMMA $GEMMA_SHA || exit 1
[ -n "$(find rt -name llama-bench | head -1)" ] || tar -xzf dl/llama-macos.tar.gz -C rt
BENCH=$(find rt -name llama-bench | head -1); BDIR=$(dirname "$BENCH")
export DYLD_LIBRARY_PATH=$BDIR
"$BENCH" --version > results/version.txt 2>&1
for pass in metal cpu; do for m in $QWEN $GEMMA; do
  out=results/${m%.gguf}.$pass; [ -s $out.raw ] && continue
  ngl=99; [ $pass = cpu ] && ngl=0
  sleep 60; log "run $out"
  /usr/bin/time -l -o $out.time "$BENCH" -m models/$m -ngl $ngl -p 512,4096 -n 128 -r 5 -o json > $out.raw 2> $out.err
  log "done $out rc=$?"
done; done
log "mac finished"
