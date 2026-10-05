# How Tally is built

Tally is a Swift package: a native SwiftUI and AppKit app for macOS 15 and later. It uses Swift 6 tools in Swift 5 language mode, and has no third-party dependencies.

## Targets

| Target            | Owns                                                                                          |
| ----------------- | --------------------------------------------------------------------------------------------- |
| `TallyCore`       | Models, protocols, store, sampling engine, settings, router, formatters and the design system |
| `TallySystem`     | `SystemSampler`: CPU, memory, disk, network, GPU and battery                                  |
| `TallyProcesses`  | `ProcessSampler`: every process, per-process rates, and grouping processes into apps          |
| `TallySensors`    | `SensorReader`: temperatures, fans and peripheral batteries                                   |
| `TallyHistory`    | `HistoryStore` (SQLite, kept for good) and `AlertEngine` (notifications)                      |
| `TallyProjects`   | `ProjectScanner` and `ProjectsView`: dev servers and open ports by project folder             |
| `TallyDashboard`  | `OverviewView`, `MetricTabView`, `SensorsView` and `AppInspectorView`                         |
| `TallyMenuBar`    | `StatusItemController` and `MenuBarPanelView`                                                 |
| `TallyExtras`     | Settings, the welcome screen, image export, updates and the logo mark                         |
| `TallyFanControl` | The fan card on the Sensors tab and the code that installs and talks to the fan helper        |
| `TallyFanHelper`  | The root fan helper: a small daemon with no SwiftUI or AppKit, copied into the app bundle     |
| `Tally`           | The app shell: `AppDelegate`, `WindowManager`, `MainView`, `MainMenu` and the render harness  |
| `Probes/probe-*`  | Tiny command-line tools that print one subsystem's output                                     |

Every feature target depends only on `TallyCore`. The `Tally` target wires them together.

## Data flow

`SamplingEngine` (`Sources/TallyCore/Engine.swift`) calls the samplers on a background queue and publishes each result to `TallyStore.shared` on the main thread. Views observe `TallyStore.shared`, `AppSettings.shared` and `AppRouter.shared`.

The engine samples at the user's update interval (default 5 seconds; 1, 2, 5 or 10) while a window or the menu bar panel is open, and every `max(interval, 5)` seconds otherwise. Code that needs faster updates for a while, such as an open panel, calls `AppRouter.shared.engine?.beginFastSampling("reason")` and later `endFastSampling("reason")`. Slower work, such as asking `nettop` for per-app network use or `system_profiler` for Bluetooth batteries, runs on its own longer cadence and less often off screen.

The main window drops its SwiftUI view tree when it closes, so a closed window costs nothing.

## Design system

`Sources/TallyCore/Design/` holds the shared look: `Palette` (every colour, light and dark), `Typography`, and components such as `Card`, `CardHeader`, `BigFigure`, `Chip`, `StatColumn`, `KeyValueRow`, `Meter`, `SegmentedMeter`, `Pill`, `AppIconView`, `LegendRow`, `TabPills`, `BarSparkline`, `AreaChart`, `DonutChart`, the gauges in `Gauges.swift` (`RingGauge`, `BatteryGlyph`, `ThermometerGlyph`, `FanGauge`, `LevelTile`) and `.quitConfirmation`. Number formatting lives in `Format` (`Formatters.swift`). Build new views by composing these rather than adding one-off styles.

The look is deliberately quiet. Type is SF Pro throughout. Every chart, gauge and selection draws in one accent (`Palette.accent`), with `accentSecond` and `accentThird` for a second and third series such as system CPU or wired and compressed memory. Green, amber and red (`Palette.good`, `.caution`, `.red`) mark status only. A card is a grey symbol and title, a bold figure over a quiet detail line, small grey chips, a gauge on the right and a bar chart on faint tracks along the bottom.

## Building

```bash
swift build                               # every target, debug
swift build --product Tally               # just the app executable
./scripts/build-app.sh debug              # build.noindex/Tally.app, with the fan helper inside
./scripts/build-app.sh                    # the same, release
TALLY_UNIVERSAL=1 ./scripts/build-app.sh  # Apple silicon and Intel in one binary
```

`build-app.sh` compiles the Icon Composer document in `Resources/AppIcon.icon` with `actool`, stamps both binaries with the real SDK version so macOS 26 and later draw the app in the current style, and signs the app and helper with the hardened runtime, ad hoc unless `TALLY_SIGNING_IDENTITY` names a certificate. The `build.noindex` folder keeps test builds out of Spotlight.

`TALLY_SCRATCH_PATH` and `TALLY_APP` point a build at another build folder and app path, so several builds can run side by side.

## Seeing your UI without opening it

The app has a headless render harness. It starts the real engine, waits for data, and writes PNGs:

```bash
swift build --product Tally
.build/debug/Tally --render overview,cpu,memory --out /tmp/tally-render --wait 6 --scheme both
```

Screen names: `overview cpu memory disk network gpu battery sensors projects popover settings welcome export inspector`. Add `--width 620` to render at another width, as the website screenshots are, and `--open-panel cpu` (or any tab name) to render that section of the menu bar panel as `popover`.

`ImageRenderer` can't draw `ScrollView` contents, AppKit views or popovers, so top-level views stay free of `ScrollView` (the shell adds scrolling) and have a natural height.

Snapshot mode captures the real app windows, the status item, the menu bar panel and Settings through the layer tree, which works even without screen recording permission:

```bash
./scripts/build-app.sh debug
build.noindex/Tally.app/Contents/MacOS/Tally --snapshot /tmp/tally-snap --wait 6
```

## Measuring cost

Always measure a release build:

```bash
./scripts/build-app.sh release
build.noindex/Tally.app/Contents/MacOS/Tally --no-window &
sleep 20; top -l 20 -s 3 -pid $! -stats pid,cpu,mem
```

`--no-window` starts Tally with only the menu bar item. Like this, Tally should average under half a percent of one core. Measure again with the main window open, and compare both figures before and after your change. `sample <pid> 8`, `footprint <pid>`, `vmmap --summary <pid>` and `leaks <pid>` help find where time and memory go.

## Fan control

The fan controls are a card on the Sensors tab, beside the temperatures they affect. The `Tally` target hands `FanControlView` to `SensorsView`, so the dashboard never depends on the fan helper. Changing fan speeds needs root, so it lives in a separate helper (`TallyFanHelper`). When the user turns fan control on, `FanHelperInstaller` asks for an administrator password once and installs the helper as a launch daemon. The app talks to it over a Unix socket that only root and that user can open. The helper sets fans back to automatic when the app quits or the helper has been idle for a while.

For testing without installing anything, start the helper by hand with `--socket <path>` (add `--dry-run` to avoid touching the fans) and point the app at it with `TALLY_FAN_HELPER_SOCKET=<path>`.

## Apple design notes

[HIG-2026-brief.md](HIG-2026-brief.md) collects notes on the macOS 26 and 27 Human Interface Guidelines, Liquid Glass and the new layered app icons.
