# Portside

An [Omarchy](https://omarchy.org/) shell plugin for the ports on your
machine: which dev servers are running, which project each belongs to,
and whether anything can actually be reached from the network. Portside
**tells you** when that changes instead of waiting for you to look.

- **Alerts.** A notification when a dev server starts, when a port becomes
  reachable from the network, and when a port you are watching goes down.
  Each has buttons (Open, Copy URL, Stop). A server has to stay up for three
  seconds before it counts, so hot reloads and test runs stay quiet.
- **Exposure that checks the firewall.** A server bound to `0.0.0.0` is not
  automatically "exposed". Portside reads UFW's saved rules and default
  policy, so with Omarchy's default `DROP` policy it shows as **Blocked**
  unless a rule lets it through.
- **Docker ports are flagged.** Ports published by Docker or Podman get a
  **Published** label because Docker's own firewall rules bypass UFW.
- **Named by project.** `5173 · Vite` under `checkout-api`, not `node`.
- **Safe stop.** Only your own processes can be stopped. Before anything is
  signalled, Portside checks the process is still the one you saw, and it
  sends the signal through a pidfd. It can also stop the `npm`/`pnpm`/`tsx`
  wrapper so the server does not come straight back. If a server survives
  the first stop, the next stop offers a force kill; it never force-kills by
  itself.

## Install

```bash
omarchy plugin add https://github.com/Saikomantisu/omarchy-portside.git --enable --yes
```

The icon lands on the right of the bar. Move it with
`omarchy bar move io.github.saikomantisu.portside`.

Plugins run as unsandboxed code inside `omarchy-shell`, so read the source
first: `Service.qml`, `BarWidget.qml`, `lib/Model.js` and the Python helper
`bin/portside`.

### Removing it

```bash
omarchy plugin remove io.github.saikomantisu.portside --yes
```

That deletes the plugin folder and its bar entry, including its settings.
Portside keeps no other state and leaves no background process: its helper
exits with the shell.

### Requirements

All of these ship with Omarchy:

| Dependency | Used for |
|---|---|
| `python3` 3.9+ (standard library only) | the scanner and stop helper, `bin/portside` |
| `ip` (iproute2) | telling LAN, VPN and container-bridge addresses apart |
| `notify-send` (libnotify) | alerts |
| `xdg-open`, `wl-copy`, `xdg-terminal-exec`, `uwsm-app` | open, copy and terminal actions |
| `docker` or `podman` (optional) | naming and stopping published container ports |

No root, no polkit prompt, no daemon, and no network access beyond one
`HEAD` request to each of your own new local servers to see whether it
speaks HTTP.

## Using it

Click the icon to open the panel. Right-click rescans; middle-click opens the
most recently started dev server. The icon turns the theme's urgent colour
while anything is **Open** or **Published**.

In the panel:

- **Click a row** to open it in the browser. **Middle-click** copies its URL.
- **Hover a row** to show its buttons: open, copy URL, terminal in the project
  folder, watch (alert if it goes down), and stop.
- **Hover a row's text** to see the full command, folder and bind addresses.
- **Right-click or Ctrl-click** rows to select several. A bar then appears
  with Open, Copy, Stop and Clear for the whole selection.
- **Click a section header** (System, Other apps…) to expand or collapse it.
- Use the **search box** and the **Dev · Mine · Exposed · All** chips to
  narrow the list, and the switch in the header to turn alerts on or off.

Stopping always asks first. If a server survives the stop, stopping it again
offers a force kill. Esc clears the search box, or closes the panel.

### Reach labels

| Label | Meaning |
|---|---|
| **Local** | loopback only |
| **Bridge** | a container bridge address (e.g. `docker0`), reachable by containers only |
| **VPN** | a Tailscale, WireGuard or other VPN address only |
| **Blocked** | bound past loopback, but UFW's default policy drops it and no rule allows it |
| **Open** | reachable from the network: no firewall, or a UFW rule allows it |
| **Published** | a Docker or Podman published port; UFW does not filter these |
| **LAN?** | bound past loopback, and UFW is not enabled, so Portside cannot tell |

The UFW check reads the **saved** configuration (`/etc/ufw/ufw.conf`,
`/etc/default/ufw`, `/etc/ufw/user*.rules`). These files are readable without
root, but they are not the live ruleset. Rules added only at runtime, other
firewalls (raw nftables, firewalld) and application-profile rules are not
taken into account.

## Settings

Change them in the bar's widget settings, or with `omarchy bar set`:

```bash
omarchy bar set io.github.saikomantisu.portside alertNewServer All
```

| Key | Default | What it does |
|---|---|---|
| `alerts` | `true` | master switch for notifications (also the switch in the panel) |
| `alertNewServer` | `Dev only` | `Off`, `Dev only` or `All`: alert when a server starts |
| `alertExposed` | `true` | alert when a port becomes Open or Published |
| `alertWatchedDown` | `true` | alert when a watched port stops |
| `refreshIntervalSec` | `2` | seconds between scans, 1–30 |
| `ignoredPorts` | `53,631,5353` | ports or ranges to leave out everywhere, e.g. `53,8000-8010` |
| `hiddenNames` | empty | comma-separated process, project or container names to leave out |
| `includeContainers` | `true` | name and stop Docker and Podman published ports |
| `includeUdp` | `false` | list UDP sockets too |
| `stopParent` | `true` | also stop a dev wrapper (`npm`, `pnpm`, `yarn`, `bun`, `tsx`, `nodemon`, `cargo-watch`…); shells and terminals are never stopped |
| `showCount` | `true` | show the dev server count next to the icon |
| `hideWhenEmpty` | `false` | hide the icon when nothing is running |

Watched ports are kept in the same settings entry, as `watched`.

## From a script or a keybinding

```bash
omarchy-shell portside list          # JSON: port, title, project, framework, reach, url
omarchy-shell portside open 3000
omarchy-shell portside stop 3000     # asks first, in a notification
omarchy-shell portside toggle        # open or close the panel
omarchy-shell portside refresh
```

For example, in `~/.config/hypr/bindings.lua`, bind a key to
`omarchy-shell portside toggle`.

## How it works

`bin/portside watch` runs for as long as the shell does. Every couple of
seconds it re-reads `/proc/net/tcp` and `tcp6` (and `udp`/`udp6` if enabled)
and maps sockets to your processes through `/proc/<pid>/fd`. It only walks
`/proc` for sockets it has not seen before, and prints a line of JSON only
when something changed. Sockets owned by root or other users are visible,
but not the process behind them; those are named from a table of well-known
ports as a guess (`DNS?`) and cannot be stopped.

The project is the nearest folder above the server's working directory that
holds `.git`, `package.json`, `Cargo.toml`, `go.mod`, `pyproject.toml` and
similar. The framework comes from the command line and, for Node, the
project's dependencies.

## Development

```bash
python3 -m unittest discover tests    # helper: parsing, UFW, events, stop safety
node tests/run.js                     # lib/Model.js
bin/portside scan --pretty            # one snapshot, as the panel sees it
```

`Service.qml` is a kept service, so changes to it only take effect after
`omarchy restart shell`. `BarWidget.qml` reloads on save.

## License

MIT
