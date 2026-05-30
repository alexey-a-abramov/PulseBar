#!/usr/bin/env bash
#
# Build (if needed) and launch PulseBar. Double-click in Finder or run ./run.command
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
APP="$DIR/build/PulseBar.app"

printf '\n  \xE2\x96\xA6  PulseBar — the advanced Touch Bar system monitor\n'
printf '  ------------------------------------------------------\n'
if [ ! -d "$APP" ]; then
  printf '  building...\n'
  "$DIR/build.sh"
fi
printf '  >  launching. Look at your Touch Bar.\n'
printf '     Tap the bar to toggle the per-core CPU view.\n'
printf '     Quit via the menu-bar (top-right) icon  ->  Quit PulseBar.\n\n'
open "$APP"
