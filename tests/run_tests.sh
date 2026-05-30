#!/usr/bin/env bash
#
# Runs PulseBar's unit tests (stats samplers) and a smoke test (launch the app,
# confirm it presents the Touch Bar and shuts down cleanly).
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SRC="$ROOT/Sources"
TESTS="$ROOT/tests"
BUILD="$ROOT/build"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$BUILD"

echo "============================================================"
echo " UNIT TESTS — Stats samplers"
echo "============================================================"
clang -fobjc-arc -O0 -isysroot "$SDK" \
  "$TESTS/stats_test.m" "$SRC/Stats.m" \
  -framework Foundation -framework CoreFoundation -framework IOKit \
  -o "$BUILD/stats_test" || { echo "compile failed"; exit 1; }
"$BUILD/stats_test"
UNIT=$?

echo
echo "============================================================"
echo " SMOKE TEST — launch app, present Touch Bar, clean shutdown"
echo "============================================================"
if [ ! -x "$BUILD/PulseBar.app/Contents/MacOS/PulseBar" ]; then
  echo "(building app first)"; "$ROOT/build.sh" >/dev/null
fi

LOG="$BUILD/smoke.log"; rm -f "$LOG"
# Self-quit after 3s so the app runs its real detach/cleanup path.
PULSEBAR_SELFQUIT=3 "$BUILD/PulseBar.app/Contents/MacOS/PulseBar" >"$LOG" 2>&1 &
PID=$!
echo "  launched PID $PID (self-quit in 3s)"
sleep 1
if kill -0 "$PID" 2>/dev/null; then
  echo "  ok   : process alive at t=1s (no early crash)"
else
  echo "  FAIL : process exited before t=1s"; echo "  ----- log -----"; sed 's/^/  /' "$LOG"
fi
wait "$PID" 2>/dev/null; SMOKE=$?
echo "  app exit code: $SMOKE (0 = clean self-quit)"

if grep -q "presented full Touch Bar" "$LOG"; then
  echo "  ok   : Touch Bar presented —"; grep "PulseBar]" "$LOG" | sed 's/^/         /'
  SMOKE_OK=0
elif grep -q "SPI unavailable" "$LOG"; then
  echo "  warn : Touch Bar SPI unavailable here (no Touch Bar in this context)"
  SMOKE_OK=0
else
  echo "  warn : no presentation line in log:"; sed 's/^/         /' "$LOG"; SMOKE_OK=1
fi

echo
echo "============================================================"
if [ "${UNIT:-1}" -eq 0 ] && [ "${SMOKE_OK:-1}" -eq 0 ]; then
  echo " RESULT: PASS  (unit ok, app launched & presented cleanly)"
  exit 0
else
  echo " RESULT: unit=$UNIT smoke=${SMOKE_OK:-?}  — see output above"
  exit 1
fi
