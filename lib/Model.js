.pragma library

// Pure helpers for Portside. No QML types in here, so tests/run.js can load it.

var FILTERS = ["dev", "mine", "exposed", "all"]

var REACH = {
  local:     { label: "Local",     tone: "dim",    rank: 0 },
  bridge:    { label: "Bridge",    tone: "dim",    rank: 1 },
  vpn:       { label: "VPN",       tone: "normal", rank: 2 },
  blocked:   { label: "Blocked",   tone: "normal", rank: 3 },
  open:      { label: "Open",      tone: "urgent", rank: 4 },
  published: { label: "Published", tone: "urgent", rank: 5 }
}

// Settings can arrive as strings ("false") when set from the CLI, so coerce
// each one to the type of its default.
function coerce(value, fallback) {
  if (value === undefined || value === null || value === "") return fallback
  if (typeof fallback === "boolean") {
    if (typeof value === "string") return value.trim().toLowerCase() === "true"
    return !!value
  }
  if (typeof fallback === "number") {
    var n = Number(value)
    return isFinite(n) ? n : fallback
  }
  return value
}

function reachInfo(reach) {
  return REACH[reach] || { label: String(reach || "?"), tone: "dim", rank: 0 }
}

function isExposed(row) {
  return !!row && (row.reach === "open" || row.reach === "published")
}

// "53,631,8000-8010" -> function(port) -> bool
function portMatcher(spec) {
  var ranges = []
  String(spec || "").split(",").forEach(function(part) {
    part = part.trim()
    if (!part) return
    var m = part.match(/^(\d+)\s*-\s*(\d+)$/)
    if (m) ranges.push([Number(m[1]), Number(m[2])])
    else if (/^\d+$/.test(part)) ranges.push([Number(part), Number(part)])
  })
  return function(port) {
    for (var i = 0; i < ranges.length; i++)
      if (port >= ranges[i][0] && port <= ranges[i][1]) return true
    return false
  }
}

function nameList(spec) {
  return String(spec || "").split(",").map(function(s) { return s.trim().toLowerCase() })
    .filter(function(s) { return s !== "" })
}

function rowNames(row) {
  var out = [row.projectName, row.comm, row.framework, row.guess]
  if (row.container) out.push(row.container.name, row.container.image)
  return out.filter(function(s) { return !!s }).map(function(s) { return String(s).toLowerCase() })
}

// Rows the settings hide everywhere: counts, alerts and the panel.
function visibleRows(rows, settings) {
  var ignored = portMatcher(settings.ignoredPorts)
  var hidden = nameList(settings.hiddenNames)
  return (rows || []).filter(function(row) {
    if (row.ports.every(ignored)) return false
    if (hidden.length) {
      var names = rowNames(row)
      for (var i = 0; i < hidden.length; i++)
        if (names.indexOf(hidden[i]) !== -1) return false
    }
    return true
  })
}

function matchesQuery(row, query) {
  var q = String(query || "").trim().toLowerCase()
  if (!q) return true
  var hay = rowNames(row).concat(row.ports.map(String), [row.cwd || "", (row.cmd || []).join(" ")])
    .join(" ").toLowerCase()
  return q.split(/\s+/).every(function(word) { return hay.indexOf(word) !== -1 })
}

function filterRows(rows, filter, query) {
  return (rows || []).filter(function(row) {
    if (filter === "dev" && row.group !== "dev" && row.group !== "containers") return false
    if (filter === "mine" && !row.mine) return false
    if (filter === "exposed" && !isExposed(row)) return false
    return matchesQuery(row, query)
  })
}

// Sections in display order. Dev rows group by project; the rest by kind.
function sections(rows) {
  var byProject = {}
  var order = []
  var apps = [], containers = [], system = []
  rows.forEach(function(row) {
    if (row.group === "dev") {
      var name = row.projectName || row.comm || "?"
      if (!byProject[name]) { byProject[name] = []; order.push(name) }
      byProject[name].push(row)
    } else if (row.group === "containers") containers.push(row)
    else if (row.group === "apps") apps.push(row)
    else system.push(row)
  })
  var out = order.map(function(name) { return { id: "p:" + name, title: name, rows: byProject[name] } })
  if (containers.length) out.push({ id: "containers", title: "Containers", rows: containers })
  if (apps.length) out.push({ id: "apps", title: "Other apps", rows: apps })
  if (system.length) out.push({ id: "system", title: "System", rows: system })
  return out
}

// Flatten sections for a ListView: each entry carries its section title when
// it is the first row of that section.
function flatten(sectionList, collapsed) {
  var out = []
  sectionList.forEach(function(sec) {
    var closed = !!(collapsed && collapsed[sec.id])
    sec.rows.forEach(function(row, i) {
      if (closed && i > 0) return
      out.push({ row: row, section: i === 0 ? sec.title : "", sectionId: sec.id,
                 collapsed: closed, hiddenCount: closed ? sec.rows.length : 0 })
    })
  })
  return out
}

function title(row) {
  var port = row.ports.length ? String(row.ports[0]) : "?"
  var what = row.framework || row.guess && (row.guess + "?") || row.comm || "unknown"
  return port + " · " + what
}

function extraPorts(row) {
  return row.ports.length > 1 ? "+" + row.ports.slice(1).join(", ") : ""
}

function subtitle(row, now) {
  var parts = []
  if (row.container) parts.push(row.container.runtime + " · " + row.container.name)
  else if (row.pid) parts.push(row.comm + " · pid " + row.pid)
  else parts.push(row.uid === 0 ? "root" : "uid " + row.uid)
  if (row.startedAt) parts.push("up " + uptime(now - row.startedAt))
  return parts.join(" · ")
}

function uptime(seconds) {
  seconds = Math.max(0, Math.floor(seconds))
  if (seconds < 60) return seconds + "s"
  var m = Math.floor(seconds / 60)
  if (m < 60) return m + "m"
  var h = Math.floor(m / 60)
  if (h < 24) return h + "h " + (m % 60) + "m"
  return Math.floor(h / 24) + "d " + (h % 24) + "h"
}

function url(row, port) {
  port = port || row.ports[0]
  var scheme = (row.http && row.http[String(port)]) || "http"
  return scheme + "://localhost:" + port
}

function canOpen(row) {
  return !!row && row.proto.indexOf("tcp") !== -1 && !!row.http && Object.keys(row.http).length > 0
}

function canStop(row) {
  return !!row && (!!row.container || (row.mine && !!row.pid))
}

function summary(rows) {
  var dev = 0, exposed = 0
  rows.forEach(function(r) {
    if (r.group === "dev" || r.group === "containers") dev++
    if (isExposed(r)) exposed++
  })
  return { dev: dev, exposed: exposed, total: rows.length }
}

function tooltip(sum) {
  var parts = [sum.dev === 1 ? "1 dev server" : sum.dev + " dev servers"]
  if (sum.exposed) parts.push(sum.exposed + " open to the network")
  return parts.join(" · ")
}

// ---------------------------------------------------------------- alerts

// Turn helper events into notifications, applying settings, watched ports and
// a per-port cooldown. `memory` is { portKey: lastAlertMs } and is updated.
function alerts(events, rows, settings, watched, memory, nowMs) {
  var byKey = {}
  rows.forEach(function(r) { byKey[r.key] = r })
  var out = []
  if (settings.alerts === false) return out
  var cooldown = 60 * 1000
  ;(events || []).forEach(function(ev) {
    var id = ev.kind + ":" + ev.portKey
    if (memory[id] && nowMs - memory[id] < cooldown) return
    var row = ev.key ? byKey[ev.key] : null
    var note = null
    if (ev.kind === "new" && row) {
      var mode = settings.alertNewServer || "Dev only"
      if (mode === "Off") return
      if (mode === "Dev only" && row.group !== "dev" && row.group !== "containers") return
      if (isExposed(row)) return  // the "exposed" alert covers it
      note = { kind: "new", urgency: "low", transient: true, row: row,
               summary: title(row) + " is up",
               body: (row.projectName || "") + (canOpen(row) ? " · " + url(row) : ""),
               actions: canOpen(row) ? [["open", "Open"], ["copy", "Copy URL"]] : [] }
    } else if (ev.kind === "exposed" && row) {
      if (settings.alertExposed === false) return
      note = { kind: "exposed", urgency: "normal", transient: false, row: row,
               summary: title(row) + " is reachable from the network",
               body: (row.projectName || "") + " · " + (row.reachNote || reachInfo(row.reach).label),
               actions: canStop(row) ? [["stop", "Stop"], ["details", "Details"]] : [["details", "Details"]] }
    } else if (ev.kind === "down") {
      if (settings.alertWatchedDown === false || watched.indexOf(ev.portKey) === -1) return
      note = { kind: "down", urgency: "normal", transient: false, row: null,
               summary: ev.portKey.replace(/:(\d+)$/, " · $1") + " stopped",
               body: "A watched server is no longer listening.", actions: [] }
    }
    if (!note) return
    memory[id] = nowMs
    note.portKey = ev.portKey
    out.push(note)
  })
  return out
}

function portKey(row) {
  return (row.projectName || row.guess || "?") + ":" + Math.min.apply(null, row.ports)
}
