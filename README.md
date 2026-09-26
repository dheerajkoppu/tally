<p align="center">
  <img src="docs/images/icon-256.png" width="128" height="128" alt="Tally app icon">
</p>

<h1 align="center">Tally</h1>

<p align="center">
  A free, open-source system monitor for your Mac.<br>
  It adds every helper process to the app it works for. On the Mac that built it, 2,147 running processes come down to 79 apps.
</p>

<p align="center">
  <a href="https://github.com/dheerajkoppu/tally/releases/latest"><img src="https://img.shields.io/github/v/release/dheerajkoppu/tally?label=download" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-blue" alt="macOS 15 or later">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/dheerajkoppu/tally" alt="MIT License"></a>
  <br>
  <a href="https://dheerajkoppu.github.io/tally/">Website</a> · <a href="https://github.com/dheerajkoppu/tally/releases/latest/download/Tally.zip">Download</a> · <a href="CONTRIBUTING.md">Contribute</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/overview-dark.png">
    <img src="docs/images/overview-light.png" width="860" alt="Tally's Overview tab showing CPU, memory, GPU, disk, network and battery, with the apps using the most">
  </picture>
</p>

## Download

1. [Download **Tally.zip**](https://github.com/dheerajkoppu/tally/releases/latest/download/Tally.zip) from the latest release.
2. Unzip it and drag **Tally** into your **Applications** folder.
3. Open Tally. The first time, macOS says it can't check the app for malicious software, because Tally isn't signed with a paid Apple developer certificate. Click **Done**, then open **System Settings › Privacy & Security**, scroll down and click **Open Anyway**.

Prefer Terminal? This does the same as step 3:

```bash
xattr -dr com.apple.quarantine /Applications/Tally.app
```

Tally needs macOS 15 Sequoia or later and runs on both Apple silicon and Intel Macs. Sensor and power readings are richer on Apple silicon.

## What it does

- **Apps, not processes.** Helper processes (renderers, GPU helpers, plugins, language servers) count toward the app that started them. One row per app, with its totals for CPU, memory, power, disk and network.
- **Separate views for each part of your Mac.** CPU, memory, disk, network, GPU and battery, each with a live chart and a ranked list of the apps driving it.
- **A month of history.** Scroll back to see what was busy while you were away, and which apps were responsible. It all lives in a single local database.
- **Alerts for runaway apps.** Get a heads-up when something pins the CPU, leaks memory, or won't stop writing to disk.
- **Local servers by project.** Servers and listening ports are filed under the repo they run from. Forgotten ones that haven't done anything in days get flagged, with a stop button that asks before it acts.
- **Menu bar monitor.** Choose a symbol, a live number, a mini chart or a stack of readings. Click it for the full picture.
- **Every network connection.** Ethernet and Wi‑Fi each show their own speed when you're on both.
- **Heat, fans and accessories.** How hot the chip is running, how fast the fans spin, and charge levels for wireless accessories. Manual fan control if you want it.
- **Volume per app.** Lower one noisy app without touching anything else.
- **Quit and force quit.** From any list, and never without your confirmation.
- **Snapshots.** Save or copy an image of your stats or the whole dashboard, in light or dark.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/menu-bar-dark.png">
    <img src="docs/images/menu-bar-light.png" width="380" alt="The Tally menu bar panel with every metric and the busiest apps">
  </picture>
</p>

## Light on your Mac

A system monitor shouldn't show up in its own list of busy apps. Tally refreshes every 5 seconds by default (you can pick 1, 2, 5 or 10), slows down further when no window is open, and runs its heavier checks far less often while you're not looking.

## Privacy

Tally makes no network connections of its own. There's no account, no analytics and no update server. Your apps, history and project names stay on your Mac. The code is all here, so you can check.

It asks for these permissions, and only when you use the feature that needs them:

| Permission                      | Why                                                               |
| ------------------------------- | ----------------------------------------------------------------- |
| Notifications                   | Alerts about runaway apps                                         |
| Bluetooth                       | Charge levels of wireless accessories                     |
| Screen & System Audio Recording | Per-app volume. Audio passes straight through and is never saved. |
| Administrator password          | Only if you install the optional fan-control helper               |

## Build from source

You need Xcode 27 or later (Xcode 26 works too, with the older tab style).

```bash
git clone https://github.com/dheerajkoppu/tally.git
cd tally
./scripts/build-app.sh
open build.noindex/Tally.app
```

`./scripts/build-app.sh debug` makes a debug build. See [CONTRIBUTING.md](CONTRIBUTING.md) for how the project is laid out and how to test your changes.

## Contributing

Bug reports, ideas and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first. For security issues, see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE). Use it, change it, share it.
