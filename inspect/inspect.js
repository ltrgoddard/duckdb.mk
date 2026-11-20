// the inspector: a duckdb.mk project's models and tests, their lineage as
// the plan has it, and each one's sql, run in the browser a clause at a
// time over the tables as make last built them. inspect.json (make inspect)
// holds the nodes, the macros and the files; a file is at files/<its path>
import {query, sql, file} from "./db.js"
import {K, lex, pretty, part, statements, query as holds} from "./sql.js"
import {steps, MARK} from "./plan.js"
import {dag} from "./dag.js"
import {grid} from "./rows.js"

const $ = q => document.querySelector(q)
const h = (tag, {dataset, ...a} = {}, ...k) => {
  const e = Object.assign(document.createElement(tag), a)
  Object.assign(e.dataset, dataset)
  return e.append(...k.flat().filter(x => x != null && x !== false)), e
}
const narrow = matchMedia("(max-width: 860px)")
const nav = $("nav"), head = $("header"), out = $("#rows")
const run = grid($("#status"), out)
const cfg = await (await fetch("inspect.json")).json()
const {nodes, files} = cfg, by = Object.fromEntries(nodes.map(m => [m.id, m]))

// the files by the paths that the sql names, the variables that the
// makefile sets and the macros, as in make, less the shell's dot
// commands; each built model a view on its table
const lit = v => `'${String(v).replaceAll("'", "''")}'`
const qn = s => `"${s.replaceAll('"', '""')}"`
const glob = s => new RegExp("^" + s.replace(/[.+^$()|[\]\\{}]/g, "\\$&")
  .replace(/\*\*\/|\*|\?/g, m => ({"*": "[^/]*", "?": "[^/]"})[m] ?? "(.*/)?")
  + "$")
await Promise.all(files.map(f => file(f, "files/" + f)))
await query(`create macro getenv(k) as coalesce(map {'': ''${Object.entries(
  cfg.env).map(([k, v]) => `, ${lit(k)}: ${lit(v)}`).join("")}}[k], '')`)
for (const m of nodes) {
  const d = m.sql.match(/^(--( .*)?\n)*/)[0], [s, t] = m.id.includes(".")
    ? m.id.split(".") : ["main", m.id]
  ;[m.desc, m.note] = d.split("\n--\n").map(t =>
    t.replace(/^-- ?/gm, "").replace(/\s+/g, " ").trim())
  m.body = m.sql.slice(d.length), m.group = m.test ? "test" : s
  m.reads = new Set(m.reads.map(id => by[id]))
  m.view = `${qn(s)}.${qn(t)}`
  m.built = !m.test && files.some(f => glob(m.out).test(f)) && await query(
    `create schema if not exists ${qn(s)};
    create view ${m.view} as from ${lit(m.out)}`).then(() => true,
    e => console.warn(m.id, e.message))
}
for (const {file, sql: s} of cfg.macros)
  for (const q of statements(s.replace(/^\..*$/gm, "")))
    await query(q).catch(e => console.warn(file, e.message))
// what duckdb says of each function, and a macro's definition, for hover
const FN = Object.fromEntries((await sql(`select function_name f,
  coalesce(any_value(description), any_value(macro_definition)) d
  from duckdb_functions() group by all having d is not null`)
  .catch(() => [])).map(r => [r.f, r.d]))

// the models that the token at i of m's sql names: schema.table, a table
// of the main schema after from or join, or a string that is a model's
// name, its path or a glob of it; only those that the plan says m reads
const ref = m => (ts, i) => {
  const x = ts[i], dot = ts[i + 1]?.t === "." && ts[i + 2]?.k === "w"
  const n = x.k === "s" ? [...m.reads].filter(n => !n.test && [n.target,
    n.out, n.id, "main." + n.id].includes(x.t.slice(1, -1)) ||
    glob(x.t.slice(1, -1)).test(n.out))
    : x.k !== "w" || ts[i - 1]?.t === "." ? []
    : dot ? [by[`${x.w}.${ts[i + 2].w}`.replace(/^main\./, "")]]
    : /^(from|join)$/.test(ts.findLast((y, j) => j < i && !(y.k in
      {c: 1, _: 1}))?.w) && ts[i + 1]?.t !== "(" ? [by[x.w]] : []
  return m.reads.has(n[0]) ? {n, len: x.k === "w" && dot ? 3 : 1} : null
}
// every table before a model, and every table after it
const up = (m, s = new Set) =>
  (m.reads.forEach(x => s.has(x) || (s.add(x), up(x, s))), s)
const down = (m, s = new Set) => (nodes.forEach(x => x.reads.has(m) &&
  !s.has(x) && (s.add(x), down(x, s))), s)

// a project's own module (its inspect.js), if it has one, may give: label(group),
// first(group) to lead the list, badge(m) as [text, title], find(hash) for
// a model's id, head(m) for more of its header, tries(m) for the queries to
// show in place of its sql
const ext = cfg.ext ? await (await import("./project.js"))
  .default({cfg, by, sql, h}) : {}
// the list: the nodes that INSPECT_HIDE does not name, by schema. the
// schemas are in the graph's order, left to right: by the mean number of
// tables before theirs, the schema with more tables first when that is the
// same, and the tests last. a schema's colour is its place in that order
const HIDE = new RegExp(cfg.hide || "^$"), label = g => ext.label?.(g) ??
  (g === "test" ? "Tests" : g)
const shown = nodes.filter(m => !HIDE.test(m.id))
const inG = g => shown.filter(m => m.group === g), far = g => g === "test"
  ? Infinity : inG(g).reduce((a, m) => a + up(m).size, 0) / inG(g).length
const groups = [...new Set(shown.map(m => m.group))].sort((a, b) =>
  far(a) - far(b) || inG(b).length - inG(a).length)
const HUES = ["#e6c07b", "#61afef", "#98c379", "#c678dd", "#56b6c2",
  "#d19a66", "#e06c75", "#abb2bf"]
for (const m of nodes) m.attrs = {className: m.built || m.test ? "" : "off",
  style: `--s:${m.test ? "#808080"
    : HUES[groups.indexOf(m.group) % HUES.length]}`}
const link = (id, a, [b, title = ""] = []) => h("a", {href: "#" +
  encodeURIComponent(id), title, dataset: {id}, className: by[id]
  ?.attrs.className ?? ""}, a, b != null && h("span", {}, String(b)))
nav.append(link("", "All tables"), ...[...groups].sort((a, b) =>
  !!ext.first?.(b) - !!ext.first?.(a)).flatMap(g => [h("h2", {}, label(g)),
  ...inG(g).map(m => link(m.id, m.id.replace(/^.*[./]/, ""),
    ext.badge?.(m)))]))
$("nav input").oninput = e => nav.querySelectorAll("a").forEach(a =>
  a.hidden = !(a.textContent + " " + a.title).toLowerCase()
    .includes(e.target.value.toLowerCase()))
// j or down opens the next item in the list, k or up the one before; enter
// on a step or a clause is a click
addEventListener("keydown", e => {
  if (e.key === "Enter" && e.target.matches?.("[tabindex]"))
    return e.target.click()
  const k = {j: 1, ArrowDown: 1, k: -1, ArrowUp: -1}[e.key]
  if (!k || e.target.matches?.("input") || e.metaKey || e.ctrlKey || e.altKey)
    return
  const as = [...nav.querySelectorAll("a:not([hidden])")]
  const a = as[as.indexOf(nav.querySelector(".on")) + k]
  if (!a) return
  e.preventDefault(), document.activeElement?.blur()
  a.click()
})
// the lines between the panes move, and stay where they were put: the
// list's (a share of the window's width), the header's (of its height) and
// the one between the sql and the rows (of main's width)
for (const [id, el, y, lo, hi, u] of [["nav", document.body, 0, 8, 50, "vw"],
  ["head", $("main"), 1, 8, 85, "vh"], ["split", $("main"), 0, 15, 85, "%"]]) {
  const drag = $("#drag-" + id), key = "inspect." + id
  const at = v => el.style.setProperty("--" + id,
    Math.min(hi, Math.max(lo, v)) + u)
  try { localStorage[key] && at(+localStorage[key]) } catch {}
  const stop = () => {
    drag.onpointermove = null, drag.classList.remove("on")
    try { localStorage[key] = parseFloat(el.style.getPropertyValue("--" +
      id)) } catch {}
  }
  drag.onpointerdown = e => {
    e.preventDefault(), drag.setPointerCapture(e.pointerId)
    drag.classList.add("on")
    drag.onpointermove = e => {
      if (!e.buttons) return stop()
      const r = el.getBoundingClientRect()
      at(y ? (e.clientY - r.top) / r.height * 100
        : (e.clientX - r.left) / r.width * 100)
    }
  }
  drag.onpointerup = drag.onpointercancel = drag.onlostpointercapture = stop
}

// a model's plan and sql (or s in its place): a step or a clause runs the
// query to it, a table's name opens it
const mark = (e, q) => {
  $("#sql .on")?.classList.remove("on"), e.classList.add("on")
  narrow.matches && out.scrollIntoView()
  run(q)
}
const show = (m, s) => {
  const ts = s ? pretty(s) : m.fmt ??= pretty(m.body), pre = h("pre")
  const r = ref(m), to = n => h("a", {href: "#" + n.id, title: n.desc})
  for (let i = 0; i < ts.length; i++) {
    const x = ts[i], f = r(ts, i)
    const t = ts.slice(i, i + (f?.len ?? 1)).map(x => x.t).join("")
    if (f) i += f.len - 1
    pre.append(f?.n.length === 1 ? Object.assign(to(f.n[0]), {textContent: t})
      : f || x.cl && holds(ts, x.o) ? h("span", {className: "cl", tabIndex: 0,
        title: "Run the query to here", onclick: e => mark(e.target,
          f ? `from ${t}` : part(ts, i))}, t)
      : x.k === "_" || x.k === "p" ? t
      : h("span", {className: x.k === "w" && K.has(x.w) ? "k" : x.k,
        title: ts[i + 1]?.t === "(" && FN[x.w] || ""}, t))
  }
  let plan = []
  try { plan = steps(ts, r) } catch (e) { console.warn(m.id, e) }
  // a step's text: a model's name, a query's, a file's place, a call
  const txt = t => t.split(MARK).flatMap((t, j) => {
    const s = t.slice(1, -1)
    return !(j % 2) ? t.split(/\b([a-z_]\w*)(?=\()/).map((t, j) =>
      j % 2 && FN[t] ? h("span", {className: "fn", title: FN[t]}, t) : t)
      : t[0] === "\x01" ? Object.assign(to(by[s]), {textContent: s})
      : t[0] === "\x02" ? h("span", {className: "name"}, s)
      : h(/^https?:/.test(s) ? "a" : "span", {className: "at", href: s}, s)
  })
  $("#sql").replaceChildren(h("ol", {className: "plan"}, plan.map(x =>
    h("li", {style: `margin-left:${x.d * 1.5}em`, tabIndex: 0, onclick: e =>
      x.i != null && e.target.tagName !== "A" && mark(e.currentTarget,
        part(ts, x.i))}, txt(x.t), x.cols && h("ul", {},
        x.cols.map(c => h("li", {}, txt(c))))))), pre)
}

// a node, by the hash: its description, its file and what it reads from
// outside the project, its lineage, then its sql and its table's rows (a
// test's failing rows); no hash, every table's lineage. its place in the
// list comes into view, or on a phone the top of the page
const go = () => {
  const key = decodeURIComponent(location.hash.slice(1))
  const id = ext.find?.(key) ?? key, m = by[id]
  if (id !== key) history.replaceState(null, "", "#" + id)
  const on = nav.querySelector(`[data-id="${CSS.escape(id)}"]`)
  nav.querySelector(".on")?.classList.remove("on"), on?.classList.add("on")
  narrow.matches ? scrollTo(0, 0) : on?.scrollIntoView({block: "nearest"})
  document.title = [cfg.title, id].filter(Boolean).join(" / ")
  document.body.classList.toggle("all", !id)
  if (!id) return head.replaceChildren(h("h1", {}, cfg.title),
    h("p", {className: "legend"}, groups.filter(g => g !== "test").map(g =>
      h("span", {style: inG(g)[0].attrs.style}, label(g)))),
    dag(shown.filter(m => !m.test)))
  head.replaceChildren(h("h1", {}, id))
  if (!m) return $("#sql").replaceChildren(), run.say("Not in this project")
  head.append(...h("div", {}, m.desc && h("p", {}, m.desc), m.note &&
    h("p", {className: "chips"}, m.note), h("p", {className: "chips"},
    [m.file, m.by && `a file for each ${m.by}`, ...m.sources,
      ...m.env.map(k => "$" + k)].filter(Boolean).join(" · ")),
    ext.head?.(m), dag([...up(m), m, ...down(m)].filter(x => x === m ||
      !HIDE.test(x.id)), m)).childNodes)
  head.querySelector(`[data-key="${CSS.escape(key)}"]`)?.scrollIntoView()
  const q = ext.tries?.(m)
  show(m, q?.[0])
  q ? run(q).then(i => i && show(m, q[i]))
    : m.built ? run(`from ${m.view}`)
    : !m.test ? run.say(`Not built: make ${m.target}`)
    : [...m.reads].every(x => x.built) ? run(m.body)
    : run.say("Not run: a table that it reads is not built")
}
addEventListener("hashchange", go)
go()
