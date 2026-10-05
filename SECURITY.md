# Security

## Reporting a problem

Please don't open a public issue for security problems. Report them privately through GitHub instead: open the [Security tab](https://github.com/dheerajkoppu/tally/security) and choose **Report a vulnerability**. You'll get a reply within a week.

Include what you found, how to reproduce it, and which version of Tally and macOS you tested on.

## What to look at

Tally reads a lot about your Mac, so these parts matter most:

- **The fan helper.** Fan control needs a small helper that runs as root, installed only if you choose to and after macOS asks for your password. Before installing it, Tally checks the helper's SHA-256 against the one sealed into the signed app, and writes the launch settings directly instead of reading them from a temporary file. It listens on a Unix socket that only root and the user who installed it can use, accepts fan-speed commands only, and puts every fan back to automatic when Tally quits or the helper goes idle. Its code is in `Sources/TallyFanHelper`.
- **Updates.** Tally replaces itself only with a download that satisfies the designated requirement of the copy already installed (the same bundle identifier and Developer ID team), has every file intact, carries Apple's notarization ticket and has a higher version number. The download address is built from the release tag, never read from GitHub's answer. Its code is in `Sources/TallyExtras/UpdateInstaller.swift`.
- **Quitting and stopping processes.** Tally only sends a signal after you confirm, and checks that the process is still the one you picked before it does.
- **Local data.** History is kept in a SQLite file in `~/Library/Application Support/Tally`. Nothing about the Mac leaves it. The only network requests are the update check, which runs when you choose Check for Updates and asks GitHub's API for the latest release, and the download of that release if you choose to install it.

## Supported versions

Only the latest release gets security fixes.
