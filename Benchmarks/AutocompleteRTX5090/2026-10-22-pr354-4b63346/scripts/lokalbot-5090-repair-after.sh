set -euo pipefail
for attempt in $(seq 1 240); do
  if test -f /workspace/pr354-validation/full-validation-exit-code.txt; then
    test "$(cat /workspace/pr354-validation/full-validation-exit-code.txt)" = 0
    exec bash /tmp/lokalbot-5090-system-repair.sh
  fi
  sleep 5
done
exit 124
