# Security

## Reporting a problem

Please don't open a public issue for security problems. Report them privately through GitHub instead: open the [Security tab](https://github.com/dheerajkoppu/tally/security) and choose **Report a vulnerability**. You'll get a reply within a week.

Include what you found, how to reproduce it, and which version of Tally and macOS you tested on.

## What to look at

Tally reads a lot about your Mac, so these parts matter most:

- **The fan helper.** Fan control needs a small helper that runs as root, installed only if you choose to and after macOS asks for your password. Before installing it, Tally checks the helper's SHA-256 against the one sealed into the signed app, and writes the launch settings directly instead of reading them from a temporary file. It listens on a Unix socket that only root and the user who installed it can use, accepts fan-speed commands only, and puts every fan back to automatic when Tally quits or the helper goes idle. Its code is in `Sources/TallyFanHelper`.
- **Quitting and stopping processes.** Tally only sends a signal after you confirm, and checks that the process is still the one you picked before it does.
- **Per-app volume.** Audio from each app is tapped and played straight back out. Nothing is recorded or written to disk.
- **Local data.** History is kept in a SQLite file in `~/Library/Application Support/Tally`. Nothing leaves the Mac. Tally makes no network connections of its own.

## Supported versions

Only the latest release gets security fixes.
