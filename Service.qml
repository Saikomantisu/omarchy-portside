import QtQuick
import Quickshell
import Quickshell.Io
import "lib/Model.js" as Model

// Headless half of Portside. Owns the helper process, the listener list, the
// alerts, and every action, so the panel, notifications and IPC all share one
// code path. The bar widget pushes its settings in with applySettings().
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.saikomantisu.portside"
  readonly property string helper: decodeURIComponent(Qt.resolvedUrl("bin/portside").toString().replace(/^file:\/\//, ""))

  readonly property var defaults: ({
    alerts: true, alertNewServer: "Dev only", alertExposed: true, alertWatchedDown: true,
    refreshIntervalSec: 2, ignoredPorts: "53,631,5353", hiddenNames: "",
    includeContainers: true, includeUdp: false, stopParent: true, watched: []
  })
  property var settings: defaults

  property var rows: []                 // everything the helper reports
  readonly property var visibleRows: Model.visibleRows(rows, settings)
  readonly property var summary: Model.summary(visibleRows)
  property var ufw: ({})
  property bool ready: false
  property string helperError: ""
  property var alertMemory: ({})
  readonly property var watched: settings.watched instanceof Array ? settings.watched : []

  // Result of the last action, shown in the panel.
  property string status: ""
  property bool statusIsError: false
  // Rows whose stop was sent a TERM but that are still listening; the next
  // stop on them offers SIGKILL instead.
  property var stubborn: ({})
  property var busyKeys: ({})

  signal detailsRequested(string key)
  signal toggleRequested()

  function setting(name) {
    return settings[name]
  }

  function applySettings(next) {
    var merged = {}
    for (var k in defaults) merged[k] = Model.coerce(next ? next[k] : undefined, defaults[k])
    if (next && next.watched instanceof Array) merged.watched = next.watched
    var restart = merged.includeUdp !== settings.includeUdp
      || merged.includeContainers !== settings.includeContainers
      || merged.refreshIntervalSec !== settings.refreshIntervalSec
    settings = merged
    if (restart) restartWatcher()
  }

  function watcherCommand() {
    var interval = Math.max(1, Math.min(30, setting("refreshIntervalSec")))
    var cmd = ["python3", helper, "watch", "--interval", String(interval)]
    if (setting("includeUdp")) cmd.push("--udp")
    if (!setting("includeContainers")) cmd.push("--no-containers")
    return cmd
  }

  property bool restartPending: false

  // A running Process ignores a new command, so stop it and start again from
  // onExited rather than toggling `running` twice in one turn.
  function restartWatcher() {
    watcher.command = watcherCommand()
    if (watcher.running) {
      restartPending = true
      watcher.running = false
    } else {
      watcher.running = true
    }
  }

  function refresh() {
    restartWatcher()
  }

  function handleLine(line) {
    var data
    try { data = JSON.parse(line) } catch (e) { return }
    if (data.type !== "state") return
    rows = data.rows || []
    ufw = data.ufw || {}
    ready = true
    helperError = ""
    var clean = {}
    for (var k in stubborn) if (rowByKey(k)) clean[k] = stubborn[k]
    stubborn = clean
    if (data.events && data.events.length) {
      var notes = Model.alerts(data.events, visibleRows, settings, watched, alertMemory, Date.now())
      for (var i = 0; i < notes.length; i++) notify(notes[i])
    }
  }

  function rowByKey(key) {
    for (var i = 0; i < rows.length; i++) if (rows[i].key === key) return rows[i]
    return null
  }

  function rowByPort(port) {
    port = Number(port)
    for (var i = 0; i < visibleRows.length; i++)
      if (visibleRows[i].ports.indexOf(port) !== -1) return visibleRows[i]
    return null
  }

  function setStatus(text, isError) {
    status = text
    statusIsError = !!isError
    statusClear.restart()
  }

  // ---------------------------------------------------------------- actions

  function launch(args, cwd) {
    var proc = detachedComponent.createObject(root, { command: args, workingDirectory: cwd || "" })
    proc.startDetached()
    proc.destroy()
  }

  function open(row, port) {
    if (!Model.canOpen(row)) return
    launch(["uwsm-app", "--", "xdg-open", Model.url(row, port)])
  }

  function copy(text) {
    if (!text) return
    launch(["wl-copy", "--", String(text)])
    setStatus("Copied " + text, false)
  }

  function copyUrl(rows) {
    var urls = rows.filter(Model.canOpen).map(function(r) { return Model.url(r) })
    if (!urls.length) urls = rows.map(function(r) { return "localhost:" + r.ports[0] })
    copy(urls.join("\n"))
  }

  // --dir alone is not enough: Ghostty in single-instance mode (Omarchy's
  // default) opens the window in the running instance, which ignores the
  // requested folder and inherits the focused terminal's instead. So the
  // shell changes into the folder itself; the folder travels as an argument,
  // never through the command string.
  function terminal(row) {
    var dir = row && (row.project || row.cwd)
    if (!dir) return
    launch(["uwsm-app", "--", "xdg-terminal-exec", "--dir=" + dir, "--",
            "sh", "-c", "cd \"$1\" && exec \"${SHELL:-/bin/bash}\"", "portside", dir])
  }

  function isWatched(row) {
    return watched.indexOf(Model.portKey(row)) !== -1
  }

  // Returns the new watched list; the widget persists it with the settings.
  function toggledWatch(row) {
    var key = Model.portKey(row)
    var list = watched.slice()
    var i = list.indexOf(key)
    if (i === -1) list.push(key)
    else list.splice(i, 1)
    return list
  }

  function stopPlan(row) {
    // What a stop on this row would signal, for the confirmation text.
    if (!row) return null
    if (row.container) return { row: row, kill: false, parent: null }
    var parent = setting("stopParent") && row.parent && row.parent.supervisor ? row.parent : null
    return { row: row, kill: !!stubborn[row.key], parent: parent }
  }

  function stop(row, forceKill) {
    if (!Model.canStop(row) || busyKeys[row.key]) return
    var cmd
    if (row.container) {
      cmd = ["python3", helper, "container-stop", "--runtime", row.container.runtime, "--id", row.container.id]
    } else {
      cmd = ["python3", helper, "stop", "--pid", String(row.pid), "--start", String(row.start)]
      var plan = stopPlan(row)
      if (forceKill || plan.kill) cmd.push("--kill")
      if (plan.parent) cmd.push("--parent", plan.parent.pid + ":" + plan.parent.start)
    }
    var busy = Object.assign({}, busyKeys)
    busy[row.key] = true
    busyKeys = busy
    actionComponent.createObject(root, { command: cmd, row: row }).running = true
  }

  function stopDone(row, text, code) {
    var busy = Object.assign({}, busyKeys)
    delete busy[row.key]
    busyKeys = busy
    var res = {}
    try { res = JSON.parse(text) } catch (e) { res = { ok: false, error: String(text).trim() || "helper failed" } }
    var name = Model.title(row)
    if (res.ok) {
      var s = Object.assign({}, stubborn)
      delete s[row.key]
      stubborn = s
      setStatus((row.container ? "Stopped " + row.container.name : "Stopped " + name), false)
    } else if (res.stillRunning && res.stillRunning.length) {
      var s2 = Object.assign({}, stubborn)
      s2[row.key] = true
      stubborn = s2
      setStatus(name + " is still running. Stop it again to force kill.", true)
    } else {
      var errors = (res.results || []).filter(function(r) { return !r.ok }).map(function(r) { return r.error })
      setStatus(errors[0] || res.error || "Could not stop " + name, true)
    }
  }

  // ---------------------------------------------------------------- alerts

  function notify(note) {
    var args = ["notify-send", "--app-name=Portside", "--icon=network-server",
                "--urgency=" + note.urgency]
    if (note.transient) args.push("--transient")
    for (var i = 0; i < note.actions.length; i++)
      args.push("--action=" + note.actions[i][0] + "=" + note.actions[i][1])
    args.push(note.summary, note.body || "")
    notifyComponent.createObject(root, { command: args, note: note }).running = true
  }

  function notifyAction(note, action) {
    var row = note.row ? (rowByKey(note.row.key) || note.row) : null
    if (action === "open") open(row)
    else if (action === "copy") copyUrl([row])
    else if (action === "stop") stop(row, false)
    else if (action === "details" && row) detailsRequested(row.key)
  }

  // ---------------------------------------------------------------- processes

  Process {
    id: watcher
    stdout: SplitParser {
      onRead: function(line) { root.handleLine(line) }
    }
    stderr: StdioCollector {
      onStreamFinished: if (text.trim() !== "") root.helperError = text.trim().split("\n").pop()
    }
    onExited: function(code) {
      if (root.restartPending) {
        root.restartPending = false
        watcher.running = true
      } else if (code !== 0) {
        retry.restart()
      }
    }
  }

  Timer {
    id: retry
    interval: 5000
    onTriggered: if (!watcher.running) watcher.running = true
  }

  Timer {
    id: statusClear
    interval: 6000
    onTriggered: root.status = ""
  }

  Component {
    id: detachedComponent
    Process {}
  }

  Component {
    id: actionComponent
    Process {
      id: proc
      property var row: null
      stdout: StdioCollector { id: out; waitForEnd: true }
      onExited: function(code) {
        root.stopDone(proc.row, out.text, code)
        proc.destroy()
      }
    }
  }

  Component {
    id: notifyComponent
    Process {
      id: proc
      property var note: null
      stdout: StdioCollector { id: chosen; waitForEnd: true }
      onExited: function() {
        var action = chosen.text.trim()
        if (action) root.notifyAction(proc.note, action)
        proc.destroy()
      }
    }
  }

  Component.onCompleted: restartWatcher()

  // ---------------------------------------------------------------- IPC
  //   omarchy-shell portside list
  //   omarchy-shell portside open 3000
  //   omarchy-shell portside stop 3000     (asks through a notification first)
  //   omarchy-shell portside toggle
  IpcHandler {
    target: "portside"

    function list(): string {
      return JSON.stringify(root.visibleRows.map(function(r) {
        return { port: r.ports[0], ports: r.ports, title: Model.title(r), project: r.projectName,
                 framework: r.framework, reach: r.reach, pid: r.pid, url: Model.canOpen(r) ? Model.url(r) : "",
                 canStop: Model.canStop(r) }
      }))
    }

    function open(port: string): string {
      var row = root.rowByPort(port)
      if (!row || !Model.canOpen(row)) return "no http server on " + port
      root.open(row, Number(port))
      return "ok"
    }

    function stop(port: string): string {
      var row = root.rowByPort(port)
      if (!row || !Model.canStop(row)) return "nothing you can stop on " + port
      root.notify({ kind: "confirm", urgency: "normal", transient: true, row: row,
                    summary: "Stop " + Model.title(row) + "?",
                    body: (row.projectName || "") + (row.pid ? " · pid " + row.pid : ""),
                    actions: [["stop", "Stop"]] })
      return "confirm in the notification"
    }

    function toggle(): void {
      root.toggleRequested()
    }

    function refresh(): void {
      root.refresh()
    }
  }
}
