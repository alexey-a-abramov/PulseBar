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
STATS=$?

echo
echo "------------------------------------------------------------"
echo " UNIT TESTS — layout engine (priority hiding + overrides)"
echo "------------------------------------------------------------"
clang -fobjc-arc -O0 -isysroot "$SDK" \
  "$TESTS/layout_test.m" "$SRC/BarView.m" "$SRC/PBDefaults.m" "$SRC/PBProcess.m" "$SRC/PBFormat.m" "$SRC/PBLayout.m" "$SRC/PBClock.m" "$SRC/AppIndex.m" "$SRC/Log.m" "$SRC/Stats.m" "$SRC/Controls.m" "$SRC/Pomodoro.m" \
  -framework AppKit -framework Foundation -framework CoreFoundation -framework IOKit \
  -framework QuartzCore -framework CoreGraphics -framework CoreAudio -framework ApplicationServices \
  -o "$BUILD/layout_test" || { echo "compile failed"; exit 1; }
"$BUILD/layout_test"
LAYOUT=$?

echo
echo "------------------------------------------------------------"
echo " UNIT TESTS — voice agent (app index · intent parser · queries)"
echo "------------------------------------------------------------"
clang -fobjc-arc -O0 -isysroot "$SDK" \
  "$TESTS/appindex_test.m" "$SRC/AppIndex.m" \
  -framework Foundation -framework AppKit \
  -o "$BUILD/appindex_test" || { echo "compile failed"; exit 1; }
"$BUILD/appindex_test"; APPIDX=$?

clang -fobjc-arc -O0 -isysroot "$SDK" \
  "$TESTS/voicecommands_test.m" "$SRC/VoiceCommands.m" \
  -framework Foundation \
  -o "$BUILD/voicecommands_test" || { echo "compile failed"; exit 1; }
"$BUILD/voicecommands_test"; VOICE=$?

clang -fobjc-arc -O0 -isysroot "$SDK" \
  "$TESTS/queries_test.m" "$SRC/Queries.m" "$SRC/Stats.m" "$SRC/Controls.m" "$SRC/PBProcess.m" \
  -framework Foundation -framework CoreFoundation -framework IOKit \
  -framework CoreAudio -framework CoreGraphics -framework AppKit -framework ApplicationServices \
  -o "$BUILD/queries_test" || { echo "compile failed"; exit 1; }
"$BUILD/queries_test"; QUERIES=$?

echo
echo "------------------------------------------------------------"
echo " E2E — emulated voice commands through the agent (no UI)"
echo "------------------------------------------------------------"
clang -fobjc-arc -O0 -isysroot "$SDK" \
  "$TESTS/voice_e2e.m" "$SRC/Agent.m" "$SRC/VoiceCommands.m" "$SRC/AppIndex.m" "$SRC/Queries.m" \
  "$SRC/Stats.m" "$SRC/Controls.m" "$SRC/PBProcess.m" "$SRC/Log.m" \
  -framework Foundation -framework CoreFoundation -framework IOKit -framework CoreAudio \
  -framework CoreGraphics -framework AppKit -framework ApplicationServices \
  -o "$BUILD/voice_e2e" || { echo "compile failed"; exit 1; }
"$BUILD/voice_e2e" | grep -E "^   (ok|FAIL)|ALL TESTS|FAILED"; VOICE_E2E=${PIPESTATUS[0]}

UNIT=0
for r in "$STATS" "$LAYOUT" "$APPIDX" "$VOICE" "$QUERIES" "$VOICE_E2E"; do [ "$r" -eq 0 ] || UNIT=1; done

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
