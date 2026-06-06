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
    tests/render_test.m Sources/BarView.m Sources/Pomodoro.m Sources/PreviewData.m Sources/AppIndex.m Sources/Log.m \
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

### Stable signing (so permission grants persist)
Ad-hoc signing changes the app's code identity every build, so macOS TCC
re-prompts for Accessibility / Microphone / Speech after each rebuild. Create a
one-off self-signed code-signing identity and `build.sh` will use it
automatically (else it falls back to ad-hoc):

```bash
openssl req -x509 -newkey rsa:2048 -keyout k.pem -out c.pem -days 3650 -nodes \
  -subj "/CN=PulseBar Local Signing" \
  -addext "extendedKeyUsage=critical,codeSigning" -addext "keyUsage=critical,digitalSignature"
openssl pkcs12 -export -inkey k.pem -in c.pem -out pb.p12 -name "PulseBar Local Signing" \
  -passout pass:pulsebar -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg SHA1   # macOS-importable
security import pb.p12 -k ~/Library/Keychains/login.keychain-db -P pulsebar -A -T /usr/bin/codesign
rm -f k.pem c.pem pb.p12
```
Grant the permissions once after the first stable-signed install; they then
survive every later rebuild. (Delete the cert in Keychain Access to revert.)

## Architecture

```
Sources/
  main.m                     accessory NSApplication (no Dock icon)
  AppDelegate.m              the composition root: 1 Hz sampling, action
                             handlers, LaunchAgent, sleep/wake pause, settings.
                             Delegates the Touch Bar SPI to TouchBarPresenter,
                             the mirror to MirrorController, ⌃/⌥ to
                             ModifierMonitor, and the agent to AgentCoordinator.
                             Also: safe-area "Fit" insets, compact toggle, and the
                             unmutable session break reminder.
  BarView.m                  all rendering + hit-testing. Modes, accordion tabs,
                             tiles, sliders, swipe, size-aware priority layout,
                             safe-area insets, compact (icon-only) layout, and
                             drag-to-arrange (long-press the active pill).
                             (Drawn in a flipped view.)
  Stats.m                    cpu / per-core / mem(+swap) / net / battery / gpu /
                             disk io+space / top-process / uptime  (pure C, testable)
  Controls.m                 volume·mute (CoreAudio) · brightness (DisplayServices)
                             · media now-playing+transport+scrubber (MediaRemote)
  Pomodoro.m                 work/break timer model
  TouchBarPresenter.m        Touch Bar SPI: present/dismiss + reversible takeover
  MirrorController.m         desktop mirror panel (floating, clickable copy)
  ModifierMonitor.m          debounced ⌃/⌥ hold detection (NSEvent + Accessibility).
                             ⌃ = momentary peek of the previous mode; ⌥ = app overlay.
  AgentCoordinator.m         PBAgent + chat window + push-to-talk + safe action dispatch
  Agent.m                    intent resolver: deterministic fast-path → Gemma fallback
  VoiceCommands.m            closed command vocabulary + offline intent parser
  AppIndex.m                 fuzzy app-launcher index (scans /Applications etc.)
  Queries.m                  read-only spoken status answers (battery/cpu/…)
  VoiceNotes.m               Focus side-notes: walkie-talkie capture → notes.jsonl + CSV export
  AgentWindowController.m    chat window: bubbles, quick chips, voice capture
  SettingsWindowController.m sectioned settings window — tabs: General, Fit (safe-area
                             squeeze + compact), Focus (pomodoro + break reminder), Notes (history)
  LayoutEditorWindowController.m  size editor: per-tile size/priority/visibility + preview
  PBDefaults.m               NSUserDefaults key constants (single source of truth)
  PreviewData.m              canned sample telemetry for the editor preview + harnesses
  PrivateAPI.h               Touch Bar SPI declarations
build.sh · run.command · tests/ · AGENTS.md · README.md
```

Tile layout overrides from the size editor persist under
`PBTile.<modeToken>.<tileToken>` keys; the editor and renderer share the key
builder and the packing logic via `+[BarView overrideKeyForMode:type:]` and
`+[BarView visibleTileNamesForMode:contentWidth:]` (the latter is unit-tested in
`tests/layout_test.m`).

### Voice / agent commands (safe by construction)
`PBVoiceCommands` defines a **closed, vetted action vocabulary** in five
categories — Controls (volume/brightness/mute/media), Bar (mode, Pomodoro,
caffeine, mirror, settings/editor, show·hide·resize a tile), System (lock,
sleep display, dark mode, Mission Control — reversible only), Query (read-only
status via `PBQueries`), and App (fuzzy launcher via `PBAppIndex`). `PBAgent.ask`
parses deterministically first (instant, offline) and only falls back to Gemma,
which is constrained to the SAME vocabulary and prompted from
`+[PBVoiceCommands promptVocabulary]`; any action failing `+isKnownAction:` is
refused. There is deliberately no destructive action (quit/delete/shutdown), so
the agent declines such requests. New commands go in `PBVoiceCommands` (parse +
vocabulary) and the dispatch switch in `AgentCoordinator -agentRunAction:args:`.

### How the "full Touch Bar regardless of focus" works
Public `NSTouchBar` is focus-bound. PulseBar uses the same private SPI as
Pock/MTMR/BetterTouchTool, all resolved/guarded at runtime:
- `DFRFoundation`: `DFRElementSetControlStripPresenceForIdentifier`,
  `DFRSystemModalShowsCloseBoxWhenFrontMost` (via `dlsym`).
- `+[NSTouchBarItem addSystemTrayItem:]`, `+[NSTouchBar presentSystemModalTouchBar:placement:systemTrayItemIdentifier:]`.
- **Hide the Control Strip (no flicker)**: present with `placement:1` (MTMR's trick) —
  this hides the right-edge Control Strip (brightness/volume/Siri) *natively*, with
  no `defaults` write or server restart. `-attach` uses it whenever `PBKeyFullBar`
  is on; the plain `…:systemTrayItemIdentifier:` (no placement) keeps the strip.
- **Hide the close box (✕)**: call `DFRSystemModalShowsCloseBoxWhenFrontMost(NO)` at
  *setup, before the first present* (MTMR does this; calling it only after is
  unreliable), and again after each present.
- **Heavy fallback** (menu → "Re-take Over the Touch Bar", ⌘R): also writes
  `com.apple.touchbar.agent PresentationModeGlobal=app` and restarts
  `TouchBarServer`/`ControlStrip` (~1s flicker). Reversible; backs up/restores the
  previous value on quit. There is **no** automatic re-attach on app switch (it
  flickered); app switches just quietly re-suppress the ✕.
- **Fit around residual chrome**: where the ✕ still shifts the bar or the strip
  overlaps, `BarView.safeAreaLeftInset`/`safeAreaRightInset` reserve px so tiles &
  the agent orb stay clear (Settings → Fit, keys `PBKeySafeLeft`/`PBKeySafeRight`;
  defaults 0 / 110). The orb lives outside the packed set so it's always drawn.
- Other SPI: `DisplayServices` (brightness), `MediaRemote` (media), CoreAudio (volume).

> Private API → not App-Store-shippable; Touch Bar Macs only. Built & verified on a
> MacBookPro17,1 (M1 13", macOS 15.6). Everything degrades gracefully where SPI is absent.

### Modes & tiles (where most features go)
`BarView` has 5 modes (`BarMode`). Each mode is a list of **tiles** returned by
`tilesForMode()`. A tile is a `TileType` + weight; `drawTile:` renders it and
`fireTap:` handles taps. The active mode is an accordion pill on the left; swipe or
tap to switch (synced to the mirror via `barDidChangeMode:`). The Classic tab uses
the `apple.logo` symbol.

**Compact layout** (`BarView.compactLayout`, `PBKeyCompact`, menu + Settings → Fit):
the active pill drops its text label (icon-only, narrower) and `drawTile:`'s
`action:` tiles render icon-only — denser, for tight bars. Rendering-only; the
visible set / packing is unchanged.

**Drag-to-arrange**: long-press the active pill → arrange mode (amber dashed frame
+ ⟷ pill); drag a tile left/right to reorder, tap the pill to finish. Persists via
the `@"order"` override (same as the layout editor), keyed per-instance so the
Actions launchers reorder individually (`orderKeyForType`/`effectiveOrderForDef`).

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
