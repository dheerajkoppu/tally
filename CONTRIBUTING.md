# Contributing to Tally

Thanks for helping. Bug reports, ideas, docs fixes and code are all welcome.

## Before you start

- **Small fixes** (typos, obvious bugs): open a pull request straight away.
- **Bigger changes** (a new feature, a new tab, anything that changes how Tally samples the system): open an issue first so we can agree on the approach before you spend time on it.
- Check the [open issues](https://github.com/dheerajkoppu/tally/issues). Ones labelled `good first issue` are a good place to start.

## Setting up

You need macOS 15 or later and Xcode 27 (Xcode 26 also builds, with the older tab style).

```bash
git clone https://github.com/dheerajkoppu/tally.git
cd tally
./scripts/build-app.sh debug
open build.noindex/Tally.app
```

Tally is a plain Swift package, so you can also open the folder in Xcode, or run `swift build` from Terminal. Some features (notifications, launch at login, the fan helper) only work when Tally runs as an app bundle, which is what `build-app.sh` makes.

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the code is laid out and how data flows from the samplers to the views.

## What Tally cares about

These are the things reviewers will check first.

1. **Stay light.** A system monitor shouldn't show up in its own list of busy apps. Tally averages under half a percent of one CPU core with only its menu bar item running, and changes should keep it there or lower. Measure with a release build (see [Measuring](#measuring)), not a debug build. Prefer slower cadences, caching and cheap system calls over spawning commands. No per-update animations.
2. **Feel like a Mac app.** Follow Apple's [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines). Use standard controls, support the keyboard and VoiceOver, respect Reduce Motion, and check your change in both light and dark mode. Colours come from `Palette` in `Sources/TallyCore/Design/`, never hard-coded.
3. **Ask before acting.** Every quit, force quit or stop asks for confirmation first (`QuitRequest` with `.quitConfirmation`).
4. **Never block the main thread** with sampling, subprocesses, file access or SQLite.
5. **Stay offline.** Apart from the update check someone starts with Check for Updates, Tally makes no network connections and has no analytics. Pull requests that add background connections or analytics won't be merged. If you think something needs the network (an update check, for example), open an issue to discuss it first.
6. **Real data only.** Figures come from the Mac Tally is running on. Nothing is simulated.

## Code style

- Match the code around you.
- Write variable names out in full: `response`, not `res`; `index`, not `idx`; `message`, not `msg`.
- Keep comments rare and short: one line explaining _why_ something exists, where that isn't obvious. No section-divider comments, TODOs or changelog notes in the code.
- Cross-target API must be `public`. Keep public API stable where you can, since other targets depend on it.
- The package uses Swift 6 tools in Swift 5 language mode.

## Testing your change

There's no automated UI test suite yet (help welcome). These tools make checking by hand quick.

**Probes** print one subsystem's live output in Terminal:

```bash
swift run probe-system      # CPU, memory, disk, network, GPU, battery
swift run probe-processes   # every process, grouped into apps
swift run probe-sensors     # temperatures, fans, peripheral batteries
swift run probe-history     # the 30-day history database
swift run probe-projects    # dev servers and ports by project
```

**The render harness** starts the real engine, waits, and writes PNGs of any screen in light and dark mode, without opening a window:

```bash
swift build --product Tally
.build/debug/Tally --render overview,cpu,network,popover --out /tmp/tally-render --wait 6 --scheme both
```

Screen names: `overview cpu memory disk network gpu battery sensors projects popover settings welcome export inspector`. Add `--open-panel cpu` (or any tab name) to render that section of the menu bar panel as `popover`.

**Snapshot mode** captures the real app windows, the menu bar item and panel, and Settings:

```bash
./scripts/build-app.sh debug
build.noindex/Tally.app/Contents/MacOS/Tally --snapshot /tmp/tally-snap --wait 6
```

### Measuring

```bash
./scripts/build-app.sh release
build.noindex/Tally.app/Contents/MacOS/Tally --no-window &
sleep 20; top -l 20 -s 3 -pid $! -stats pid,cpu,mem
```

`--no-window` starts Tally with only its menu bar item, to measure the background cost. Open the main window and measure again for the foreground cost. `sample <pid> 8`, `footprint <pid>` and `leaks <pid>` are useful too. Quit every copy you start.

If your change touches sampling, put the before and after figures in your pull request.

## Pull requests

- Keep each pull request to one change, and describe what it does and why.
- Include before and after screenshots for anything visible, in light and dark mode.
- Make sure `swift build` and `./scripts/build-app.sh debug` both succeed.
- Continuous integration builds every pull request. It needs to pass before merging.

## Reporting bugs

Use the [bug report form](https://github.com/dheerajkoppu/tally/issues/new?template=bug_report.yml). Include your macOS version, your Mac model (Apple silicon or Intel), the Tally version from **Settings › About**, what you did, and what happened. A screenshot helps a lot.

For security problems, don't open a public issue. See [SECURITY.md](SECURITY.md).

## Releases

Maintainers bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, then run:

```bash
./scripts/package-release.sh
```

It builds a universal app for Apple silicon and Intel, signs it with the maintainer's Developer ID certificate, has Apple notarize it so macOS opens it without a warning, zips it to `dist/Tally.zip`, and prints the commands to tag and publish the release.

Packaging a fork? Set `TALLY_SIGNING_IDENTITY` to your own Developer ID certificate and `TALLY_NOTARY_PROFILE` to your `notarytool` keychain profile, or set `TALLY_SIGNING_IDENTITY=-` for an ad hoc build that skips notarization.

## Code of Conduct

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
