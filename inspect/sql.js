// sql as tokens, and the part of a query that gives the rows at a clause
import {formatDialect, duckdb as dialect} from
  "https://cdn.jsdelivr.net/npm/sql-formatter@15.9.0/+esm"

// a token: k its kind (comment, string, quoted name, number, word, space,
// punctuation), w a word in lower case, o the bracket that it is in (-1 at
// the top), and for a bracket c its close; a clause keyword (cl) starts a
// part of a query
const re = new RegExp(["(--[^\\n]*|/\\*[\\s\\S]*?\\*/)",
  "([eE]'(?:[^'\\\\]|\\\\.|'')*'|'(?:[^']|'')*')", '("(?:[^"]|"")*")',
  "(\\d[\\w.]*)", "([A-Za-z_][\\w$]*)", "(\\s+)", "([\\s\\S])"].join("|"), "g")
const set = s => new Set(s.split(" "))
export const K = set("with select from where group having qualify order " +
  "limit join union except intersect")
export const SET = set("union except intersect")
export const MOD = set("left right inner outer full cross natural semi anti " +
  "asof positional")
const skip = d => (ts, i) => {
  do i += d; while (ts[i]?.k in {c: 1, _: 1})
  return i
}
export const nx = skip(1), pv = skip(-1)
export const lex = s => {
  const ts = [], st = []
  for (const m of s.matchAll(re)) {
    const t = m[0], k = "csqnw_p"[m.slice(1).findIndex(x => x != null)]
    if (")]}".includes(t) && st.length) ts[st.pop()].c = ts.length
    ts.push({t, k, w: k === "w" ? t.toLowerCase() : null, o: st.at(-1) ?? -1})
    if ("([{".includes(t)) st.push(ts.length - 1)
  }
  ts.forEach((x, i) => x.cl = K.has(x.w) && !(
    (x.w === "group" || x.w === "order") && ts[nx(ts, i)]?.w !== "by" ||
    x.w === "from" && ts[pv(ts, i)]?.w === "distinct" ||
    x.w === "with" && ts[pv(ts, i)] && ts[pv(ts, i)].t !== "("))
  return ts
}
// the text from a to b, less comments
export const tx = (ts, a, b) =>
  ts.slice(a, b).map(x => x.k === "c" ? " " : x.t).join("").trim()
// whether the bracket g holds a query
export const query = (ts, g) =>
  ["with", "select", "from"].includes(ts[nx(ts, g)]?.w)
// the stretches between the commas of the bracket g, from a to b
export const split = (ts, a, b, g) => {
  const r = []
  for (let j = a, c = a; j <= b; j++)
    if (j === b || ts[j].o === g && ts[j].t === ",") r.push([c, j]), c = j + 1
  return r
}
// the statements of a file
export const statements = s => {
  const ts = lex(s), e = ts.flatMap((x, j) => x.t === ";" && x.o < 0 ? [j] : [])
  return [...e, ts.length].map((j, k) => tx(ts, (e[k - 1] ?? -1) + 1, j))
    .filter(Boolean)
}
// a column: where its expression ends, and its name if it has one
export const cut = (ts, u, v) => {
  const e = pv(ts, v), p = pv(ts, e), x = ts[e]
  return p >= u && (x.k === "w" || x.k === "q") &&
    !/^(end|null|true|false)$/.test(x.w) && (ts[p].w === "as" ||
    ts[p].k !== "p" || /[)\]'"]/.test(ts[p].t)) && ts[p].t !== "."
    ? [ts[p].w === "as" ? p : e, x.t] : [v, null]
}

// sql laid out, as tokens: lower case, two spaces, no space before the "("
// of a call that the formatter does not know (a macro), strings that follow
// each other, which the formatter puts on one line, as one, and a row
// written by hand (values) on one line; as written if the formatter fails
const KEEP = set("in as and or not exists over filter using on values from " +
  "join select where when then else by all any some recursive union except " +
  "intersect lateral is with case like")
export const pretty = s => {
  try {
    const a = [...formatDialect(s, {dialect, keywordCase: "lower",
      dataTypeCase: "lower", functionCase: "lower", expressionWidth: 72})
      .matchAll(re)], str = m => m?.[0][0] === "'"
    s = a.map((m, i) => m[0] === " " && a[i - 1]?.[5] &&
      !KEEP.has(a[i - 1][0].toLowerCase()) && a[i + 1]?.[0] === "(" ? ""
      : m[6] && str(a[i - 1]) && str(a[i + 1]) ? ""
      : str(m) ? m[0].slice(+!!(str(a[i - 2]) && a[i - 1][6]),
        str(a[i + 2]) && a[i + 1][6] ? -1 : undefined) : m[0]).join("")
  } catch {}
  const ts = lex(s)
  ts.forEach((x, i) => x.w === "values" && ts.forEach((r, j) => {
    if (j < i || r.o !== x.o || r.t !== "(") return
    for (let k = j + 1; k < r.c; k++) if (ts[k].k === "_")
      ts[k].t = k === j + 1 || k === r.c - 1 ? "" : " "
  }))
  return ts
}

// a query's level: the tokens in the "(" g, its clauses, and its with
// clause from W to its main query at m
export const level = (ts, g) => {
  const a = g + 1, b = g < 0 ? ts.length : ts[g].c ?? ts.length, cl = []
  for (let j = a; j < b; j++) ts[j].o === g && ts[j].cl && cl.push(j)
  const W = ts[cl[0]]?.w === "with" ? cl[0] : -1
  return {a, b, cl, W, m: W < 0 ? a : cl.find(j => ts[j].w !== "with") ?? b}
}
// the ctes of a level's with clause that a query at p can read: all of
// them from its main query, those before p's own from inside one
const ctes = (ts, l, g, p) => {
  const a = nx(ts, l.W), s = ts[a].w === "recursive" ? nx(ts, a) : a
  const r = split(ts, s, l.m, g).filter(([, j]) => p >= l.m || j <= p)
  return {r: r.map(u => tx(ts, ...u)), rec: s !== a}
}
// the sql that gives the rows at clause i: its query up to the next
// clause, each table so far (select *, else its own select list, whose
// names a where may use) for a from, join or where, and the ctes it can
// read; a list of tries
export const part = (ts, i) => {
  const g = ts[i].o, l = level(ts, g), w = ts[i].w
  const whole = w === "with" || SET.has(w)
  let q
  if (whole) q = [tx(ts, l.m, l.b)]
  else {
    const cl = l.cl.filter(j => j >= l.m)
    let s = (cl.filter(j => j < i && SET.has(ts[j].w)).at(-1) ?? l.m - 1) + 1
    while (["all", "distinct", "by", "name"].includes(ts[nx(ts, s - 1)].w))
      s = nx(ts, s - 1) + 1
    const e = cl.find(j => j > i && SET.has(ts[j].w)) ?? l.b
    const sc = cl.filter(j => j >= s && j < e), fr = sc.includes(i) &&
      ["from", "join"].includes(w)
    let end = sc.find(j => j > i && (fr || ts[j].w !== "join")) ?? e
    if (ts[end]?.w === "join")
      while (MOD.has(ts[pv(ts, end)]?.w)) end = pv(ts, end)
    const sel = ts[sc[0]].w === "select"
    q = sel && w === "select" ? [tx(ts, s, e)]
      : sel && ["from", "join", "where"].includes(w)
      ? ["select * " + tx(ts, sc.find(j => ts[j].w === "from"), end),
        tx(ts, s, end)] : [tx(ts, s, end)]
  }
  const cs = []
  let rec = false
  for (let G = g, p = whole ? l.m : i; ; p = G, G = ts[G].o) {
    const lv = G === g ? l : level(ts, G)
    if (lv.W >= 0 && p > lv.W) {
      const x = ctes(ts, lv, G, p)
      cs.unshift(...x.r), rec ||= x.rec
    }
    if (G < 0) break
  }
  return q.map(q => cs.length ? `with ${rec ? "recursive " : ""}${
    cs.join(",\n")}\n${q}` : q)
}
