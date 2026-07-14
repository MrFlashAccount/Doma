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
