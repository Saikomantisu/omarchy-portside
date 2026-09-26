// node tests/run.js — checks lib/Model.js against hand-made rows.
const load = require("./loader")
const M = load(require("path").join(__dirname, "..", "lib", "Model.js"))
let fails = 0
function eq(name, got, want) {
  const a = JSON.stringify(got), b = JSON.stringify(want)
  if (a !== b) { fails++; console.log("FAIL " + name + "\n  got  " + a + "\n  want " + b) }
}

const row = (o) => Object.assign({ key: "pid:1", ports: [3000], proto: "tcp", addrs: ["127.0.0.1"], uid: 1000, mine: true,
  pid: 1, start: 1, startedAt: null, comm: "node", cmd: [], cwd: "/home/u/app", project: "/home/u/app",
  projectName: "app", framework: "Vite", guess: null, container: null, parent: null, http: { "3000": "http" },
  group: "dev", reach: "local", reachNote: "loopback only" }, o)

const vite = row({ cmd: ["node", "vite"] })
const api = row({ key: "pid:2", pid: 2, ports: [8000, 8001], projectName: "api", framework: "FastAPI", comm: "python3",
  cmd: ["uvicorn", "main:app"], reach: "open", reachNote: "allowed by a UFW rule", http: {} })
const pg = row({ key: "ctr:abc:5432", pid: null, ports: [5432], projectName: "stack", framework: "postgres", group: "containers",
  container: { runtime: "docker", id: "abc", name: "stack-db-1", image: "postgres:16", port: 5432 }, reach: "published" })
const spotify = row({ key: "pid:3", pid: 3, ports: [57621], projectName: "spotify", framework: null, comm: "spotify", group: "apps", http: {} })
const dns = row({ key: "sys:tcp:53:977", pid: null, ports: [53], uid: 977, mine: false, projectName: null, framework: null,
  comm: null, guess: "DNS", group: "system", reach: "bridge", http: {} })
const rows = [vite, api, pg, spotify, dns]

// port specs and hiding
const m = M.portMatcher("53, 631,8000-8010,x")
eq("matcher", [53, 631, 8000, 8005, 8010, 8011, 22].map(m), [true, true, true, true, true, false, false])
eq("ignored all ports", M.visibleRows(rows, { ignoredPorts: "53,57621" }).map(r => r.key), ["pid:1", "pid:2", "ctr:abc:5432"])
eq("ignored some ports keeps row", M.visibleRows([api], { ignoredPorts: "8000" }).length, 1)
eq("hidden names", M.visibleRows(rows, { hiddenNames: "Spotify, postgres" }).map(r => r.key), ["pid:1", "pid:2", "sys:tcp:53:977"])

// filters and search
eq("dev filter", M.filterRows(rows, "dev", "").map(r => r.key), ["pid:1", "pid:2", "ctr:abc:5432"])
eq("mine filter", M.filterRows(rows, "mine", "").length, 4)
eq("exposed filter", M.filterRows(rows, "exposed", "").map(r => r.key), ["pid:2", "ctr:abc:5432"])
eq("search by port", M.filterRows(rows, "all", "5432").map(r => r.key), ["ctr:abc:5432"])
eq("search words", M.filterRows(rows, "all", "uvicorn api").map(r => r.key), ["pid:2"])
eq("search framework", M.filterRows(rows, "all", "vite").map(r => r.key), ["pid:1"])

// sections
eq("sections", M.sections(rows).map(s => s.title + ":" + s.rows.length), ["app:1", "api:1", "Containers:1", "Other apps:1", "System:1"])
const flat = M.flatten(M.sections([vite, row({ key: "pid:9", ports: [3001] }), dns]), { "p:app": true })
eq("collapsed section keeps its header row", flat.map(f => [f.section, f.collapsed, f.hiddenCount]), [["app", true, 2], ["System", false, 0]])

// labels
eq("title", [M.title(vite), M.title(dns), M.title(spotify)], ["3000 · Vite", "53 · DNS?", "57621 · spotify"])
eq("extra ports", [M.extraPorts(api), M.extraPorts(vite)], ["+8001", ""])
eq("uptime", [5, 125, 3 * 3600 + 120, 26 * 3600].map(M.uptime), ["5s", "2m", "3h 2m", "1d 2h"])
eq("url", [M.url(vite), M.url(row({ http: { "3000": "https" } }))], ["http://localhost:3000", "https://localhost:3000"])
eq("canOpen", [vite, api, pg].map(M.canOpen), [true, false, true])
eq("canStop", [vite, pg, dns].map(M.canStop), [true, true, false])
eq("summary", M.summary(rows), { dev: 3, exposed: 2, total: 5 })
eq("tooltip", [M.tooltip({ dev: 1, exposed: 0 }), M.tooltip({ dev: 2, exposed: 1 })], ["1 dev server", "2 dev servers · 1 open to the network"])
eq("reach label", M.reachInfo("published").label, "Published")

// alerts
const settings = { alertNewServer: "Dev only", alertExposed: true, alertWatchedDown: true }
let mem = {}
let got = M.alerts([{ kind: "new", key: "pid:1", portKey: "app:3000" }], rows, settings, [], mem, 1000)
eq("new dev alert", got.map(a => [a.kind, a.summary, a.actions.length]), [["new", "3000 · Vite is up", 2]])
eq("cooldown", M.alerts([{ kind: "new", key: "pid:1", portKey: "app:3000" }], rows, settings, [], mem, 30000).length, 0)
eq("after cooldown", M.alerts([{ kind: "new", key: "pid:1", portKey: "app:3000" }], rows, settings, [], mem, 70000).length, 1)
eq("non-dev skipped in Dev only", M.alerts([{ kind: "new", key: "pid:3", portKey: "spotify:57621" }], rows, settings, [], {}, 0).length, 0)
eq("non-dev in All", M.alerts([{ kind: "new", key: "pid:3", portKey: "spotify:57621" }], rows, { alertNewServer: "All" }, [], {}, 0).length, 1)
eq("off", M.alerts([{ kind: "new", key: "pid:1", portKey: "app:3000" }], rows, { alertNewServer: "Off" }, [], {}, 0).length, 0)
eq("exposed new server gets one alert, not two",
  M.alerts([{ kind: "new", key: "pid:2", portKey: "api:8000" }, { kind: "exposed", key: "pid:2", portKey: "api:8000" }], rows, settings, [], {}, 0).map(a => a.kind),
  ["exposed"])
eq("exposed actions", M.alerts([{ kind: "exposed", key: "pid:2", portKey: "api:8000" }], rows, settings, [], {}, 0)[0].actions.map(a => a[0]), ["stop", "details"])
eq("down unwatched", M.alerts([{ kind: "down", portKey: "app:3000" }], rows, settings, [], {}, 0).length, 0)
eq("down watched", M.alerts([{ kind: "down", portKey: "app:3000" }], rows, settings, ["app:3000"], {}, 0).map(a => a.summary), ["app · 3000 stopped"])
eq("master switch", M.alerts([{ kind: "new", key: "pid:1", portKey: "app:3000" }], rows, { alerts: false }, [], {}, 0).length, 0)
eq("coerce", [M.coerce("false", true), M.coerce("true", false), M.coerce(undefined, true), M.coerce("5", 2), M.coerce("x", 2), M.coerce("", "a"), M.coerce(false, true)],
  [false, true, true, 5, 2, "a", false])
eq("portKey", M.portKey(api), "api:8000")

console.log(fails ? fails + " failed" : "all Model checks passed")
process.exit(fails ? 1 : 0)
