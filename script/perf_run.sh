#!/bin/zsh
# Unattended CPU sampling of the assembled .app, one %CPU sample per second via top.
#
#   script/perf_run.sh <label> <out dir> idle  [seconds]            # app open, no session
#   script/perf_run.sh <label> <out dir> pipeline [seconds] <audio> # configured engines, file capture
#
# The file-driven 系统声 lane (FileCapture) runs the full GUI session without a process tap, so
# no consent dialog blocks the run. Writes top.log, two screenshots and summary.txt into <out dir>.
# The summary skips the first top sample (cumulative), the launch / model warm-up and the stop /
# quit tail. Compare runs built with the same configuration (use --release for both).
set -u
LABEL="$1"; OUT="$2"; MODE="$3"; SECS="${4:-60}"; AUDIO="${5:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/LiveLearn.app"
if [[ "$MODE" != "idle" && ! -f "$AUDIO" ]]; then
  echo "usage: perf_run.sh <label> <out dir> idle|pipeline [seconds] <audio file>  (audio required for pipeline)"; exit 2
fi
mkdir -p "$OUT"
pkill -x LiveLearn 2>/dev/null; sleep 0.5

case "$MODE" in
  idle)  open "$APP" ;;
  pipeline) open "$APP" --args --autostart "file:$AUDIO" --autostop "$SECS" ;;
  *) echo "unknown mode $MODE"; exit 2 ;;
esac
START=$(date +%H:%M:%S)
for i in {1..40}; do PID=$(pgrep -x LiveLearn) && break; sleep 0.25; done
[[ -n "${PID:-}" ]] || { echo "app did not start" | tee "$OUT/summary.txt"; exit 1; }
echo "label=$LABEL mode=$MODE pid=$PID start=$START" > "$OUT/summary.txt"

TOTAL=$(( SECS + 8 ))
[[ "$MODE" == "idle" ]] && TOTAL=$SECS
( top -l "$TOTAL" -s 1 -pid "$PID" -stats pid,cpu,th,mem,time 2>/dev/null > "$OUT/top.log" ) &
TOPJOB=$!
( sleep 8; screencapture -x "$OUT/shot-08s.png" ) &
( sleep $(( TOTAL - 6 )); screencapture -x "$OUT/shot-late.png" ) &
wait $TOPJOB
if [[ "$MODE" == "idle" ]]; then pkill -x LiveLearn; fi
sleep 1
END=$(date +%H:%M:%S)

awk -v pid="$PID" -v mode="$MODE" -v start="$START" -v end="$END" '
  $1 == pid { n++; cpu[n] = $2 + 0; thr[n] = $3; mem[n] = $4 }
  END {
    lo = (mode == "idle") ? 3 : 7; hi = (mode == "idle") ? n : n - 4;
    if (hi < lo) { print "too few samples: " n; exit }
    sum = 0; max = 0; cnt = 0
    for (i = lo; i <= hi; i++) { sum += cpu[i]; cnt++; if (cpu[i] > max) max = cpu[i] }
    for (i = lo; i <= hi; i++) v[i - lo + 1] = cpu[i]
    m = cnt; for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (v[j] < v[i]) { t = v[i]; v[i] = v[j]; v[j] = t }
    med = v[int((m + 1) / 2)]
    printf("samples=%d window=[%d,%d] cpu_avg=%.1f%% cpu_p50=%.1f%% cpu_max=%.1f%% threads_last=%s mem_last=%s start=%s end=%s\n", n, lo, hi, sum / cnt, med, max, thr[n], mem[n], start, end)
  }' "$OUT/top.log" | tee -a "$OUT/summary.txt"
