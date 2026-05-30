# AGENTS.md — working on PulseBar

Guidance for any agent (or human) hacking on this project. Read this first.

## What PulseBar is — and the vision

PulseBar is a **native macOS** app that takes over the **entire Touch Bar**
(regardless of which app is focused) and turns it into a fast, glanceable,
**interactive** control surface: a system monitor *and* a set of real controls
you can press.

The bigger idea: make the Touch Bar the **best ambient dashboard + launch bar on
the Mac** — multiple swipeable *modes* (System, Media, Focus, Classic, Actions),
every element interactive, plus a **desktop mirror** so the same surface works as
a floating widget bar (and is debuggable, since the Touch Bar can't be
screenshotted). It should feel instant, look sharp, and sip power.

Design principles:
- **Glanceable + actionable** — never just readouts; tap/drag/swipe does things.
- **Full width, always there** — own the whole bar, persist across apps.
- **Cheap** — sample only what's shown; pause when the screen is asleep.
- **Self-contained & verifiable** — one `clang` build, tests, and an offscreen
  render harness + desktop mirror for visual verification.

## Build · Run · Test

```bash
./build.sh            # one clang invocation -> build/PulseBar.app (ad-hoc signed) + bare binary
./run.command         # build-if-needed, then launch
./tests/run_tests.sh  # unit tests (samplers) + smoke test (presents bar, clean exit)
```

Requirements: Xcode command-line tools (for the macOS SDK). No Xcode project, no
SwiftPM — just `clang` over `Sources/*.m`.

**Visual verification (important — the Touch Bar is not screenshot-able on M1):**
- `tests/render_test.m` renders every mode offscreen to `/tmp/pulsebar_modes.png`.
  Build & run it, then look at the PNG:
  ```bash
  clang -fobjc-arc -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    tests/render_test.m Sources/BarView.m Sources/Pomodoro.m \
    -framework AppKit -framework Foundation -o build/render_test && ./build/render_test
  ```
- The **Desktop Mirror** (a floating panel, shown by default) is an exact, clickable
  copy of the bar. `screencapture -x /tmp/d.png` captures it for inspection.

## Conventions

- **Atomic commits**, one logical change each; run the tests before committing.
  Commit messages end with the `Co-Authored-By:` trailer.
- Keep the build warning-clean. Deployment target is macOS 12.
- When changing the bar's look, re-run `render_test` and eyeball the PNG.
- Don't make system changes (the full-bar takeover restarts the Touch Bar agent)
  under test — the code skips them when `PULSEBAR_SELFQUIT` is set.

## Architecture

```
Sources/
  main.m                     accessory NSApplication (no Dock icon)
  AppDelegate.m              the brain: presents the bar (SPI), 1 Hz sampling,
                             action handlers, full-bar takeover, LaunchAgent,
                             sleep/wake pause, desktop mirror, settings
  BarView.m                  all rendering + hit-testing. Modes, accordion tabs,
                             tiles, sliders, swipe. (Drawn in a flipped view.)
  Stats.m                    cpu / per-core / mem(+swap) / net / battery / gpu /
                             disk io+space / top-process / uptime  (pure C, testable)
  Controls.m                 volume·mute (CoreAudio) · brightness (DisplayServices)
                             · media now-playing+transport+scrubber (MediaRemote)
  Pomodoro.m                 work/break timer model
  SettingsWindowController.m desktop settings window (full-bar, login, top-proc, pomodoro)
  PrivateAPI.h               Touch Bar SPI declarations
build.sh · run.command · tests/ · AGENTS.md · README.md
```

### How the "full Touch Bar regardless of focus" works
Public `NSTouchBar` is focus-bound. PulseBar uses the same private SPI as
Pock/MTMR/BetterTouchTool, all resolved/guarded at runtime:
- `DFRFoundation`: `DFRElementSetControlStripPresenceForIdentifier`,
  `DFRSystemModalShowsCloseBoxWhenFrontMost` (via `dlsym`).
- `+[NSTouchBarItem addSystemTrayItem:]`, `+[NSTouchBar presentSystemModalTouchBar:systemTrayItemIdentifier:]`.
- **Full width**: set `com.apple.touchbar.agent PresentationModeGlobal=app` and
  restart `TouchBarServer`/`ControlStrip` (hides the Control Strip; also makes the
  bar persist over apps with per-app function-key overrides). Reversible; backs up
  and restores the previous value; restores on quit so you're never stuck.
- Other SPI: `DisplayServices` (brightness), `MediaRemote` (media), CoreAudio (volume).

> Private API → not App-Store-shippable; Touch Bar Macs only. Built & verified on a
> MacBookPro17,1 (M1 13", macOS 15.6). Everything degrades gracefully where SPI is absent.

### Modes & tiles (where most features go)
`BarView` has 5 modes (`BarMode`). Each mode is a list of **tiles** returned by
`tilesForMode()`. A tile is a `TileType` + weight; `drawTile:` renders it and
`fireTap:` handles taps. The active mode is an accordion pill on the left; swipe or
tap to switch (synced to the mirror via `barDidChangeMode:`).

**To add a tile:** add a `TileType`, a `drawTile:` case, a `fireTap:` case (if
interactive), and include it in `tilesForMode()`. If it needs new data, add a
sampler to `Stats`/`Controls` and feed it through `AppDelegate -tick` →
`BarView -updateWith…`. Gate expensive sampling by mode in `-tick`.

**To add a mode:** extend `BarMode`, add `modeIcon()`/`modeLabel()`, a
`tilesForMode()` case, and (optionally) sampling gating in `-tick`.

## Roadmap / cool feature ideas

**Near-term**
- CPU **temperature + fan RPM** via `IOHIDEventSystemClient` thermal sensors (the
  Apple-Silicon-correct path; SMC keys don't cover M-series temps).
- **Scrub-to-seek** media (drag the scrubber → `MRMediaRemoteSetElapsedTime`), now-playing **artwork**.
- **Per-app modes** — auto-switch mode based on the frontmost app (e.g. Media in Spotify, System in Activity Monitor).
- **JSON-configurable layouts** — let users pick/reorder tiles per mode without recompiling.
- Wi-Fi **SSID/IP**, VPN state, Bluetooth/AirPods **battery**.

**Bigger**
- **Launch bar** — pin app/shortcut tiles (the desktop mirror becomes a real dock/widget bar).
- **macOS Shortcuts** integration — run any Shortcut from a tile (`shortcuts run …`).
- **Widgets** — calendar next-event (EventKit), weather, stocks/crypto, world clocks, timers.
- **Alerts** — flash a tile red on high temp / low battery / critical memory pressure / calendar reminder.
- **Themes** — accent + density customization; light/dark.
- **Menu-bar companion** — mirror one key stat to the menu bar; **history** persistence + tap-to-expand graphs.
- **Haptics / sounds** on actions; richer gesture set (two-finger, long-press secondary actions).

## The Agent (local Gemma) — how inference works

- **Ollama** runs as a local launchd service (`brew services start ollama`, port
  `11434`). It loads **Gemma 3 4B** (a quantized GGUF) and serves an HTTP API.
- `PBAgent` POSTs to `/api/chat` with a **system prompt** (defining a strict JSON
  tool protocol + the allowed actions), the conversation history, and the user
  message. Gemma runs on the M1 **GPU via Metal** (llama.cpp backend) and returns
  a single JSON object `{action, args, say}`.
- PulseBar parses it and executes the action through `-agentRunAction:args:`
  (CoreAudio / DisplayServices / MediaRemote / NSTask). 100% **on-device, offline,
  private** — nothing leaves the Mac.
- Voice: the mic button runs on-device `SFSpeechRecognizer` (offline when
  supported) + `AVAudioEngine`; partial text streams into the input and is sent to
  Gemma on final. Needs Microphone + Speech-Recognition permission (first use).

**Memory & speed (Gemma 3 4B, Q4 on a 16 GB M1):** ~3.3 GB on disk; ~3.5–4.5 GB
resident **only while loaded**. Ollama keeps it warm for ~5 min after the last
request (`keep_alive`), then frees the RAM. ~25–40 tok/s; JSON replies are short
(~30–60 tok) → ~1–2 s warm, ~3–5 s cold (first call loads the model). Swap to
`gemma3:1b` (~0.8 GB, faster) or `gemma3:12b` (~8 GB, smarter) by changing
`PBAgent.model`. The integration test (`tests/agent_test.sh`) confirms the model
is up and answers with an action.

## Function keys (Fn → F1–F12)

Because PulseBar owns the whole bar, the system's "hold Fn for F-keys" is
suppressed — so PulseBar re-implements it: a global flags-changed monitor detects
Fn and the bar switches to a full-width F1–F12 keypad (`BarView.fnMode`); tapping a
key posts the real function key via `CGEvent`. Needs **Accessibility** permission
(observe Fn + post keys). Toggle: menu → "Function Keys on Fn".

## Known caveats
- Some Actions prompt for permission once (Screenshot → Screen Recording,
  Dark Mode → Automation/System Events).
- Toggling the full-bar takeover briefly restarts the Touch Bar (~1s flicker).
- The Touch Bar can't be screenshotted on Apple Silicon — use the render harness
  or the Desktop Mirror to see/verify the UI.
