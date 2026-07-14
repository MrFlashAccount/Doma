# Doma

**Doma** brings remote development services home to your Mac.

It is a native macOS menu bar app for automatic, lazy SSH port forwarding:

- Reads concrete aliases from `~/.ssh/config`.
- Maintains an app-owned SSH ControlMaster without changing normal interactive SSH.
- Mirrors remote TCP listeners from ports 1024–32767 to `127.0.0.1` with a 128-forward limit.
- Groups Docker Compose services by project/service and detects Vite, Node, and Python processes.
- Reconnects automatically and exposes manual reconnect/sync actions.
- Opens forwarded services in the browser and groups them into collapsible projects.

## Requirements

- macOS 14 or newer
- Swift 5.10 or newer
- OpenSSH and a working host alias in `~/.ssh/config`

## Build and install

```fish
./scripts/build-app.fish
open "$HOME/Applications/Doma.app"
```

Doma binds forwarded ports only to `127.0.0.1`.

## Installation from GitHub

[Download the latest release](https://github.com/MrFlashAccount/doma/releases/latest), open the DMG, and drag
`Doma.app` to `Applications`.

Doma is ad-hoc signed but not notarized. macOS may warn on the first launch; use right click → **Open** to confirm
that you want to run it.

## Releases

Releases are built by GitHub Actions on a macOS runner. Start the `Release` workflow manually and provide a semantic
version such as `0.1.0`. The workflow builds and verifies an ad-hoc signed app, packages `Doma-<version>.dmg`, creates
the matching `v<version>` tag, and publishes the DMG in a GitHub Release.
