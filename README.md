# Portside

Portside is an [Omarchy](https://omarchy.org/) shell plugin that lists the
ports listening on your machine. It shows which dev servers are running,
which project each one belongs to, and whether the network can reach it.
When any of that changes, it sends a notification, so you don't have to keep
checking.

Omarchy's marketplace already has plenty of port lists. I wrote this one for
the parts they skip.

**Alerts.** Portside notifies you when a dev server starts, when a port
becomes reachable from the network, and when a port you watch goes down. Each
notification has Open, Copy URL and Stop buttons. A server has to stay up for
three seconds before it counts, so hot reloads and test runs don't set it off.

**Exposure that checks the firewall.** Binding to `0.0.0.0` doesn't make a
server reachable if the firewall drops the traffic. Portside reads UFW's saved
rules and default policy. Omarchy ships with a `DROP` policy, so a server on
`0.0.0.0` shows as Blocked unless a rule lets it through.

**Docker ports get their own label.** Docker writes its own firewall rules,
and those skip UFW entirely. A port published by Docker or Podman shows as
Published, whatever UFW says.

**Rows named by project.** You see `5173 · Vite` under `checkout-api`, not a
bare `node`.

**Stop that won't hit the wrong process.** You can only stop your own
processes. Before sending a signal, Portside checks that the PID still belongs
to the process you saw, then signals it through a pidfd. It can also stop the
`npm`, `pnpm` or `tsx` wrapper, which would otherwise restart the server a
second later. If a server survives the first stop, the next stop offers a
force kill. Portside never force-kills on its own.

## Install

```bash
omarchy plugin add https://github.com/Saikomantisu/omarchy-portside.git --enable --yes
```

The icon goes on the right of the bar. To move it, run
`omarchy bar move io.github.saikomantisu.portside`.

Plugins run inside `omarchy-shell` with no sandbox, so read the source before
you install. It's four files: `Service.qml`, `BarWidget.qml`, `lib/Model.js`
and the Python helper `bin/portside`.

### Removing it

```bash
omarchy plugin remove io.github.saikomantisu.portside --yes
```

This deletes the plugin folder and its bar entry, settings included. Portside
stores nothing anywhere else. Its helper exits when the shell does, so no
process is left behind.

### Requirements

Omarchy ships all of these.

| Dependency | Used for |
|---|---|
| `python3` 3.9 or newer, standard library only | `bin/portside`, the scanner and stop helper |
| `ip` from iproute2 | telling LAN, VPN and container bridge addresses apart |
| `notify-send` from libnotify | alerts |
| `xdg-open`, `wl-copy`, `xdg-terminal-exec`, `uwsm-app` | the open, copy and terminal actions |
| `docker` or `podman`, optional | naming and stopping published container ports |

Portside needs no root, no polkit prompt and no daemon of its own. Its only
network traffic is one `HEAD` request to each new local server, to check
whether it speaks HTTP.

## Using it

Click the icon to open the panel. Right-click rescans. Middle-click opens the
dev server that started most recently. The icon switches to the theme's
urgent colour while any port is Open or Published.

In the panel:

- Click a row to open it in the browser. Middle-click copies its URL.
- Hover a row to show its buttons. They open the URL, copy it, open a terminal
  in the project folder, watch the port so you get an alert if it goes down,
  and stop the server.
- Hover the row's text to see the full command, folder and bind addresses.
- Right-click or Ctrl-click to select several rows. A bar appears with Open,
  Copy, Stop and Clear for the whole selection.
- Click a section header such as System or Other apps to fold it.
- Type in the search box, or pick one of the Dev, Mine, Exposed and All chips,
  to narrow the list. The switch in the header turns alerts on and off.

Stop always asks first. Esc cancels an open confirmation, clears the search
box if it has text, and otherwise closes the panel.

### Reach labels

| Label | Meaning |
|---|---|
| Local | bound to loopback only |
| Bridge | bound to a container bridge such as `docker0`, so only containers can reach it |
| VPN | bound only to a Tailscale, WireGuard or other VPN address |
| Blocked | bound beyond loopback, but UFW's default policy drops the traffic and no rule allows it |
| Open | reachable from the network, because there is no firewall or a UFW rule allows it |
| Published | published by Docker or Podman, which UFW does not filter |
| LAN? | bound beyond loopback with UFW off, so Portside can't tell |

The UFW check reads the saved configuration in `/etc/ufw/ufw.conf`,
`/etc/default/ufw` and `/etc/ufw/user*.rules`. Any user can read those files,
which is why Portside needs no root. They are not the live ruleset, though.
Portside misses rules added only at runtime, application profile rules, and
other firewalls such as raw nftables or firewalld.

## Settings

Change them in the bar's widget settings, or with `omarchy bar set`:

```bash
omarchy bar set io.github.saikomantisu.portside alertNewServer All
```

| Key | Default | What it does |
|---|---|---|
| `alerts` | `true` | turns all notifications on or off, same as the switch in the panel |
| `alertNewServer` | `Dev only` | `Off`, `Dev only` or `All`, for alerts when a server starts |
| `alertExposed` | `true` | alert when a port becomes Open or Published |
| `alertWatchedDown` | `true` | alert when a watched port stops |
| `refreshIntervalSec` | `2` | seconds between scans, from 1 to 30 |
| `ignoredPorts` | `53,631,5353` | ports or ranges to hide everywhere, like `53,8000-8010` |
| `hiddenNames` | empty | comma-separated process, project or container names to hide |
| `includeContainers` | `true` | name and stop ports published by Docker and Podman |
| `includeUdp` | `false` | list UDP sockets too |
| `stopParent` | `true` | also stop the dev wrapper, such as `npm`, `pnpm`, `yarn`, `bun`, `tsx`, `nodemon` or `cargo-watch`. It never stops shells or terminals |
| `showCount` | `true` | show the number of dev servers next to the icon |
| `hideWhenEmpty` | `false` | hide the icon when nothing is running |

Portside keeps the list of watched ports in the same settings entry, under
`watched`.

## Scripts and keybindings

```bash
omarchy-shell portside list          # JSON with port, title, project, framework, reach, url
omarchy-shell portside open 3000
omarchy-shell portside stop 3000     # asks first, in a notification
omarchy-shell portside toggle        # open or close the panel
omarchy-shell portside refresh
```

To open the panel from the keyboard, bind a key to
`omarchy-shell portside toggle` in `~/.config/hypr/bindings.lua`.

## How it works

`bin/portside watch` runs as long as the shell does. Every two seconds by
default, it reads `/proc/net/tcp` and `/proc/net/tcp6`, plus the UDP files if
you turned them on. It then maps each socket to a process through
`/proc/<pid>/fd`. It only walks `/proc` for sockets it hasn't seen before, and
it prints a line of JSON only when something changed.

Portside can see sockets that belong to root or other users, but not the
process behind them. It guesses a name for those from a table of well-known
ports, shown with a question mark like `DNS?`, and you can't stop them.

The project is the closest folder at or above the server's working directory
that contains `.git`, `package.json`, `Cargo.toml`, `go.mod`,
`pyproject.toml` or a similar marker. Portside reads the framework from the
command line, and for Node it also checks the project's dependencies.

## Development

```bash
python3 -m unittest discover tests    # helper: parsing, UFW, events, stop safety
node tests/run.js                     # lib/Model.js
bin/portside scan --pretty            # one snapshot, as the panel sees it
```

The shell keeps `Service.qml` loaded, so edits to it need
`omarchy restart shell`. `BarWidget.qml` reloads when you save it.

## License

MIT
