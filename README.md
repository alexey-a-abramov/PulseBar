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
| **System**  | CPU (+ top process) · MEM (+ swap) · GPU · NET · DISK |
| **Media**   | now-playing transport (◀ ⏯ ▶) · volume |
| **Focus**   | Pomodoro · ☕ caffeine keep-awake · New Note · Lock |
| **Classic** | brightness · volume · media (the Control-Strip basics) |
| **Actions** | Lock · Display-Sleep · Screenshot · Dark Mode · Mission Control · caffeine |

Battery, clock and the ⚙ gear stay pinned on the right in every mode.

## Tiles (across modes)

**Metrics (glanceable):**
- **CPU** — % + sparkline + the current **top CPU process**. *Tap* to switch to a per-core view (P+E cores).
- **MEM** — used / total GB + gauge (active + wired + compressed); shows **swap** used when memory spills over.
- **GPU** — utilisation % + sparkline (IOAccelerator).
- **NET** — live ↓ / ↑ throughput + sparkline.
- **DISK** — read/write I/O + free space.

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

It's **reversible** and conservative: it backs up your current `PresentationModeGlobal`,
sets `app`, and restarts the Touch Bar agent; turning it off (or quitting PulseBar)
restores your Control Strip so you're never stuck. It does **not** touch your per-app
Touch Bar overrides.

## Settings window (the ⚙ button)

Tapping the gear on the Touch Bar brings up a desktop window with:
- **Take over the entire Touch Bar** (full-bar takeover, above)
- **Start at login** — installs/removes a LaunchAgent (`~/Library/LaunchAgents/com.fun.pulsebar.plist`)
- **Show top CPU process** — toggle off to skip the per-tick `ps` sampling (saves a little CPU)
- **Pomodoro** work / break durations
- **Quit PulseBar**

Some Actions prompt for permission the first time (Screenshot → Screen Recording,
Dark Mode → Automation); macOS will ask once.

## How "full bar regardless of focus" works

The public `NSTouchBar` API is focus-bound; to own the bar persistently PulseBar uses
the same private SPI as Pock / MTMR / BetterTouchTool — all verified at runtime on the
build machine before use:
- `DFRFoundation` control-strip presence + `presentSystemModalTouchBar:` (focus-independent presentation)
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
  BarView.m                 interactive tile rendering + hit-testing · size-aware layout
  Stats.m                   cpu/per-core/mem/net/battery/gpu/disk/top-process
  Controls.m                volume·mute (CoreAudio) · brightness (DisplayServices) · media (MediaRemote)
  Pomodoro.m                work/break timer model
  ModifierMonitor.m         debounced ⌘/⌥ hold detection
  AgentCoordinator.m        agent + chat window + push-to-talk + action dispatch
  Agent.m · AgentWindowController.m   Ollama (Gemma) client · chat/voice window
  SettingsWindowController.m  desktop settings window
  LayoutEditorWindowController.m  size editor (per-tile size/priority/visibility)
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
