# PulseBar — an advanced, interactive Touch Bar

A **native macOS** menu-bar agent that takes over the Touch Bar — **regardless of
which app is focused** — and turns it into a live system monitor *and* a control
surface you can actually press.

```
[ SYSTEM | ♪ | ⏱ | ◐ | ⚡ ]  ◀ active mode panel (animates open) ▶   …always:  BATT · CLOCK · ⚙
  └ accordion mode tabs: the active one expands with a label; tap to switch (content cross-fades)
```

## Modes (animated accordion)

Tap a tab on the left to switch modes — the active tab expands (the "accordion"),
the panel cross-fades, and your choice is remembered:

| Mode | Contents |
|------|----------|
| **System**  | CPU · MEM · GPU · NET · DISK · **temp/fan** · uptime/session · battery |
| **Media**   | now-playing transport (◀ ⏯ ▶) · scrubber (tap to seek) · volume |
| **Focus**   | adaptive Pomodoro · **session** · voice side-note (hold to talk) · ☕ caffeine · Reminder · Lock |
| **Classic** | brightness · volume · media (the Control-Strip basics) |
| **Actions** | colourful app launcher (Arc · Termius · Zed · Claude · Claude Code · Dynalist) · Screenshot · Lock |

The agent orb stays pinned on the right in every mode; the clock and ⚙ settings
live in the menu bar (not the bar).

**Tap a metric tile to cycle its view** (dynamic ↔ fundamental): CPU sparkline↔cores,
MEM usage↔pressure/swap, GPU spark↔bar, NET rates↔readout, DISK rates↔space,
and the uptime chip toggles **uptime ↔ session**.

### Adaptive Pomodoro
The focus timer's length adapts to how long you've actually been working. While
the timer is idle, PulseBar sets the next focus block from your current
**uninterrupted working session** (the "session" chip): **25 min + 5 min for every
30 min of session, clamped to 20–50 min**. Tap the time to override it manually
(cycles 20 → 25 → 30 → 45 → 50; the "auto" label switches to "set"); tap the play
icon to start. The working session itself is time since your last >5-minute input
gap (system-wide keyboard/mouse/Touch-Bar idle).

### Focus side-notes
Hold the **NOTE** tile in Focus mode and just talk (walkie-talkie) — release and
keep working. The transcript is captured on-device and appended to
`~/Library/Logs/PulseBar/notes.jsonl`; nothing opens, no agent runs. Export them
as a table any time via the menu bar → **Export Side-Notes (CSV)** (writes
`notes.csv`).

## Tiles (across modes)

**Metrics (glanceable):**
- **CPU** — % + sparkline + the current **top CPU process**. *Tap* to switch to a per-core view (P+E cores).
- **MEM** — used / total GB + gauge (active + wired + compressed); shows **swap** used when memory spills over.
- **GPU** — utilisation % + sparkline (IOAccelerator).
- **NET** — live ↓ / ↑ throughput + sparkline.
- **DISK** — read/write I/O + free space.
- **TEMP** — CPU die temperature (°C, green→amber→red ramp) + fan RPM. Apple-Silicon temps come from the IOHIDEventSystemClient thermal sensors (not the SMC); fans from AppleSMC.
- **World Clock** — any city from a master list, DST/summer-time correct, with a live ±offset vs. local and a next/prev-day badge. Add several; mix into any mode.

**Controls (tap / drag):**
- **Now Playing** — track + ◀ / ⏯ / ▶ (MediaRemote).
- **Volume** — drag the slider; tap the speaker to mute (CoreAudio).
- **Brightness** — drag the slider (DisplayServices).
- **Pomodoro** — tap to start/pause; auto-advances work↔break with a chime.
- **⚙ Settings** — opens a real **settings window on the desktop**.
- **BATT / CLOCK** — battery glyph + charge, and time/date pinned right.

Runs as a background **accessory app** (no Dock icon; `▦` menu-bar icon), updating
once a second even when another app is frontmost.

## Take over the *entire* bar (hide the Control Strip)

By default macOS keeps the system **Control Strip** (volume/brightness/Siri) on the
right. Open **⚙ Settings → "Take over the entire Touch Bar"** to hide it so PulseBar
fills the whole width *and* stays put across all apps. Because PulseBar has its own
volume/brightness/media, you lose nothing.

PulseBar hides the Control Strip the no-flicker way — it **presents with `placement:1`**
(MTMR's trick), which suppresses it natively without restarting the Touch Bar agent —
and suppresses the system close box (✕) at setup. If a stray ✕ or Control Strip still
creeps in, **Settings → Layout** lets you *squeeze* the layout (live sliders + presets) so every tile
and the agent orb stay clear, and the menu's **"Re-take Over the Touch Bar"** (⌘R) does
the heavy reset (writes `PresentationModeGlobal=app` + restarts the agent). All
reversible: it backs up your previous value and restores it on quit. It does **not**
touch your per-app Touch Bar overrides.

## Settings window (the ⚙ button)

Tapping the gear (or the `▦` menu bar icon → Settings) brings up a sectioned desktop
window:
- **General** — full-bar takeover, desktop mirror, modifier shortcuts (⌃ peek · ⌥ app),
  show top CPU process, start at login, media app.
- **Fit** — *squeeze* the layout around residual system chrome (live sliders, previewed
  on the mirror) and toggle **Compact layout** (icon-only mode pill + action tiles).
- **Focus** — Pomodoro work/break, adaptive length, and the unmutable **break reminder**
  (a full-width "take a break" nudge after a long unbroken session, repeating every 15 min).
- **Notes** — your captured side-notes history, with CSV export.

Other shortcuts: hold **⌃** to peek your previous mode (release to snap back); **long-press
the active mode pill** to enter *arrange mode* and drag tiles left/right to reorder them.

**Collapse the mode tabs** (menu bar → *Collapse Mode Tabs*, or Settings → Layout) to show only
the active mode pill and reclaim the other tabs' width for tiles; tap the **›** chevron on the bar
to expand again.

### Customize layout (add / remove widgets)
**Settings → Layout → Customize layout…** (or the menu bar) opens a per-mode editor. Pick a
mode and: drag **Size/Min** to resize a tile, toggle **Show** to hide it, lower **Priority** so it
drops first when space is tight, **▲/▼** to reorder, **✕** to remove. **Add tile…** adds a
**World Clock** (any city from the master list — DST-correct), an **App Launcher**, or any other
tile — and the same tile can live in several modes. Changes are per-mode and reversible
(**Reset this mode**). The layout engine caches packing so none of this costs a frame.

Some Actions prompt for permission the first time (Screenshot → Screen Recording,
Dark Mode → Automation); macOS will ask once.

## How "full bar regardless of focus" works

The public `NSTouchBar` API is focus-bound; to own the bar persistently PulseBar uses
the same private SPI as Pock / MTMR / BetterTouchTool — all verified at runtime on the
build machine before use:
- `DFRFoundation` control-strip presence + `presentSystemModalTouchBar:placement:` (focus-independent; `placement:1` hides the Control Strip natively) + `DFRSystemModalShowsCloseBoxWhenFrontMost(NO)` (suppress the ✕)
- `DisplayServices` brightness, `MediaRemote` now-playing/transport, CoreAudio volume

> ⚠️ Private API → not App-Store-shippable; Touch Bar Macs only. Built & tested on a
> MacBookPro17,1 (M1 13″, macOS 15.6). Guarded so it degrades to a menu-bar item where
> the SPI is missing.

## Build · Run · Test

```bash
./build.sh             # → build/PulseBar.app (ad-hoc signed) + bare binary
./run.command          # build-if-needed, then launch
./tests/run_tests.sh   # unit tests (all samplers) + smoke test (presents bar, clean exit)
```
There's also `tests/render_test.m` → renders the bar to `/tmp/pulsebar_bar.png` so the
layout can be inspected without a physical Touch Bar.

Quit via the `▦` menu-bar icon → **Quit PulseBar** (or `pkill -x PulseBar`, now graceful).

## Source map

```
Sources/
  main.m                    accessory NSApplication (no Dock)
  AppDelegate.m             SPI presentation · 1 Hz sampling · actions · full-bar · LaunchAgent
  BarView.m                 interactive tile rendering + hit-testing (drives the PBLayout engine)
  PBLayout.m                AppKit-free tile model + size-aware packing engine + per-mode composition (unit-tested)
  PBClock.m                 world-clock master city list + DST-correct formatting
  PBThermal.m               CPU temperature (IOHIDEventSystemClient) + fan RPM (AppleSMC)
  PBFormat.m · PBProcess.m  pure value formatters · shared NSTask helpers
  PBLoginItem.m · PBBreakReminder.m  login LaunchAgent · session break-reminder nudge
  Stats.m                   cpu/per-core/mem/net/battery/gpu/disk/top-process
  Controls.m                volume·mute (CoreAudio) · brightness (DisplayServices) · media (MediaRemote)
  Pomodoro.m                work/break timer model
  TouchBarPresenter.m       Touch Bar SPI: present/dismiss + reversible full-bar takeover
  MirrorController.m        desktop mirror panel (floating, clickable copy)
  ModifierMonitor.m         debounced ⌃/⌥ hold detection (⌃ peek previous mode · ⌥ app overlay)
  AgentCoordinator.m        agent + chat window + push-to-talk + safe action dispatch
  Agent.m · AgentWindowController.m   intent resolver (fast-path → Gemma) · chat/voice window
  VoiceCommands.m           closed command vocabulary + offline intent parser
  AppIndex.m · Queries.m    fuzzy app launcher · read-only spoken status answers
  VoiceNotes.m              Focus side-notes: walkie-talkie capture → notes.jsonl / CSV
  SettingsWindowController.m  sectioned settings window (General · Fit · Focus · Notes)
  LayoutEditorWindowController.m  layout editor: per-tile size/priority/visibility/order + add/remove (world clocks, apps, any tile)
  PBDefaults.m              NSUserDefaults key constants
  PreviewData.m             canned sample telemetry for previews/harnesses
  PrivateAPI.h              Touch Bar SPI declarations
```

## Tweak

| What | Where |
|------|-------|
| Tiles shown / order / widths | `BarView.m` → `tilesForMode()` (weight·priority·minW), or the in-app **Customize layout…** editor |
| Sample rate | `AppDelegate.m` → `timerWithTimeInterval:1.0` |
| Colours / thresholds | `BarView.m` colour helpers |
| Pomodoro defaults | Settings window, or `Pomodoro.m` |
