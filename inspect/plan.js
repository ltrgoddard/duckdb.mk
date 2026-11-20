// a plan: a query's steps in the order that they run, in words. steps(ts,
// ref) gives {d, t, i, cols}: a depth, a text, the clause that gives its
// rows, and a select's columns. ref(ts, i) gives the models that the token
// at i names, as {n, len}. a text marks a model's name, a query's and a
// file's place (MARK) for the page to set apart
import {K, MOD, SET, nx, pv, query, split, cut, level} from "./sql.js"

export const MARK = /([\x01-\x03][^\x04]*\x04)/
const MODEL = s => `\x01${s}\x04`, NAME = s => `\x02${s}\x04`
const AT = s => `\x03${s}\x04`
// a call in words
const PH = Object.entries({
  "the number of rows": "count()", "the number of {0}": "count",
  "the total of {0}": "sum", "the mean of {0}": "avg mean",
  "the median of {0}": "median", "the lowest {0}": "min",
  "the highest {0}": "max", "any {0}": "any_value", "the first {0}": "first",
  "the {0} with the highest {1}": "arg_max max_by",
  "the {0} with the lowest {1}": "arg_min min_by",
  "the list of {0}": "list array_agg", "{0} joined by {1}": "string_agg",
  "whether any {0}": "bool_or", "whether every {0}": "bool_and",
  "{1} if {0}, else {2}": "if iff", "{0}, null if {1}": "nullif",
  "{0} rounded": "round", "{0} rounded down": "floor",
  "{0} rounded up": "ceil", "the size of {0}": "abs",
  "each of {0}": "unnest", "the length of {0}": "len length array_length",
  "the year of {0}": "year", "the month of {0}": "month",
  "{0} as {1}": "strftime", "{1} to the {0}": "date_trunc",
  "the {0}s from {1} to {2}": "date_diff datediff date_sub",
  "{0} with {1} as {2}": "replace regexp_replace",
  "{0} matches {1}": "regexp_matches",
  "the part of {0} that matches {1}": "regexp_extract",
  "{0} starts with {1}": "starts_with",
  "{0} contains {1}": "contains list_contains",
  "part {2} of {0} split at {1}": "split_part",
  "{0} split at {1}": "string_split", "{0}": "lower upper trim strip",
  "the previous {0}": "lag", "the next {0}": "lead",
  "the row's place": "row_number()", "the rank": "rank() dense_rank()",
  "the distance from {0} to {1}": "st_distance",
  "{0} meets {1}": "st_intersects", "{0} is within {2} of {1}": "st_dwithin"
}).reduce((o, [t, fs]) => (fs.split(" ").forEach(f => o[f] = t), o), {})
const AGG = new RegExp(`^(${("count sum avg mean median min max any_value " +
  "first arg_max max_by arg_min min_by list array_agg string_agg bool_or " +
  "bool_and").split(" ").join("|")})$`)
const JOIN = {"": "Join {0}, where {1}", inner: "Join {0}, where {1}",
  left: "Join {0} where {1}, keeping the rows with no match",
  semi: "Keep the rows with a match in {0}, where {1}",
  anti: "Keep the rows with no match in {0}, where {1}",
  cross: "Pair each row with every row of {0}",
  asof: "Join {0} at the nearest match, where {1}",
  positional: "Join {0} row by row"}
const FILE = {csv: "CSV file", parquet: "Parquet file", text: "text file",
  json: "JSON file", ndjson: "JSON file", undefined: "map file"}
const SETS = {union: "Add the rows of", except: "Take away the rows of",
  intersect: "Keep only the rows also in"}
const KW = new RegExp(`^(${[...K, ...MOD, "on", "using", "window"]
  .join("|")})$`)
const fill = (t, a) => t.replace(/\{(\d)\}/g, (_, n) =>
  (a[n] ?? "").replace(/^'(\w+)'$/, "$1"))

export const steps = (ts, ref) => {
  // sub names a query inside another, for words; the plan in hand sets it
  let sub
  const words = (a, b) => {
    let o = ""
    for (let i = a; i < b; i++) {
      const x = ts[i], r = ref(ts, i), p = ts[nx(ts, i)]?.t === "(" && nx(ts, i)
      if (x.k === "c") continue
      if (r) o += r.n.length === 1 ? MODEL(r.n[0].id) : x.t, i += r.len - 1
      else if (x.t === ":" && ts[i + 1]?.t === ":") {
        i = nx(ts, i + 1)
        if (ts[i + 1]?.t === "(") i = ts[i + 1].c
        while (ts[i + 1]?.t === "[" || ts[i + 1]?.t === "]") i++
      } else if (x.k === "w" && p && x.w === "over") {
        const w = words(p + 1, ts[p].c).replace(/^partition by\b/, "each")
        o += w ? " over " + w : "", i = ts[p].c
      } else if (x.k === "w" && p && (PH[x.w] || PH[x.w + "()"] ||
        /^(format|printf|coalesce|ifnull)$/.test(x.w))) {
        const c = ts[p].c, as = split(ts, p + 1, c, p)
          .map(u => words(...u)).filter(a => a && a !== "*")
        const t = x.w === "format" || x.w === "printf"
          ? `${as[0]} filled with ${as.slice(1).join(", ")}`
          : x.w === "coalesce" || x.w === "ifnull" ? as.join(", else ")
          : fill(PH[as.length ? x.w : x.w + "()"] ?? PH[x.w], as)
        o += / else /.test(t) && (nx(ts, a - 1) < i || pv(ts, b) > c)
          ? ` (${t}) ` : ` ${t} `
        i = c
        const f = nx(ts, i)
        if (ts[f]?.w === "filter" && ts[nx(ts, f)]?.t === "(") {
          const g = nx(ts, f), w = ts[nx(ts, g)].w === "where" ? nx(ts, g) : g
          o += " among the rows where " + words(w + 1, ts[g].c), i = ts[g].c
        }
      } else if (x.t === "(" && query(ts, i)) o += ` ${sub(i)} `, i = x.c
      else o += x.t
    }
    return o.replace(/\s+/g, " ").replace(/([([]) /g, "$1")
      .replace(/ ([)\],])/g, "$1")
      .replace(/<>|!=/g, "≠").replace(/>=/g, "≥").replace(/<=/g, "≤")
      .replace(/\border by\b/g, "in order of").replace(/\bdesc\b/g,
        "descending").replace(/\basc\b/g, "ascending").trim()
  }
  // a cte, or any query inside another, comes first, as a step of its own
  // named by its alias (else a letter), so that a plan reads in the order
  // its rows are made; "(from t)" is t, with no step
  const cx = {pre: [], n: 0, names: new Set}
  const plan = (g, d, out) => {
    const l = level(ts, g), was = sub
    const S = (t, i, x = {}) => out.push({d, t, i, ...x})
    sub = (j, name) => {
      const f = nx(ts, j), t = nx(ts, f)
      if (ts[f].w === "from" && ts[t].k === "w" && nx(ts, t) === ts[j].c)
        return NAME(ts[t].t)
      let a = nx(ts, ts[j].c)
      if (ts[a]?.w === "as") a = nx(ts, a)
      name ??= ts[a]?.k === "w" && !KW.test(ts[a].w) ? ts[a].t : null
      const st = plan(j, 1, [])
      name ??= String.fromCharCode(65 + cx.n++)
      cx.names.add(name.toLowerCase())
      cx.pre.push({d: 0, t: `Make table ${NAME(name)}:`,
        i: level(ts, j).cl[0]}, ...st)
      return NAME(name)
    }
    const qg = (a, b) => {
      const j = nx(ts, a - 1)
      return j < b && ts[j].t === "(" && query(ts, j) ? j : -1
    }
    if (l.W >= 0) {
      const a = nx(ts, l.W), s0 = ts[a].w === "recursive" ? nx(ts, a) : a
      for (const [u, v] of split(ts, s0, l.m, g)) {
        let j = u
        while (j < v && !(ts[j].t === "(" && query(ts, j))) j++
        if (j < v) sub(j, ts[nx(ts, u - 1)].t)
      }
    }
    const cl = l.cl.filter(j => j >= l.m), sets = cl.filter(j =>
      SET.has(ts[j].w)), many = sets.length > 0
    ;[l.m - 1, ...sets].forEach((s, k) => {
      const e = sets[k] ?? l.b, sc = cl.filter(j => j > s && j < e)
      if (!sc.length) return
      if (many) {
        const w = ts[s]?.w, all = ts[nx(ts, s)]?.w === "all"
        S(k ? `${SETS[w]}${w === "union" && !all ? ", less duplicates" : ""}:`
          : "Take the rows of:", k ? s : sc[0]), d++
      }
      const at = w => sc.filter(j => ts[j].w === w)
      const body = j => {
        const n = sc.find(x => x > j) ?? e
        let a = nx(ts, j), b = n
        if (ts[a]?.w === "by") a = nx(ts, a)
        if (ts[n]?.w === "join")
          while (MOD.has(ts[pv(ts, b)]?.w)) b = pv(ts, b)
        return [a, b]
      }
      // a file read (read_csv and the like, st_read, or a path alone) is
      // its kind and where it is
      const file = (a, b) => {
        const j = nx(ts, a - 1), p = nx(ts, j), m = ts[p]?.t === "(" &&
          ts[j].w?.match(/^read_(csv|parquet|text|json|ndjson)|^st_read$/)
        if (!m && (ts[j].k !== "s" || p < b)) return
        const [u, v] = m ? split(ts, p + 1, ts[p].c, p)[0] : [j, b]
        const l = nx(ts, u - 1), at = (ts[l].t === "[" ? split(ts, l + 1,
          ts[l].c, l) : [[u, v]]).map(([x, y]) => ts.slice(x, y).filter(t =>
          t.k === "s").map(t => t.t.slice(1, -1).replaceAll("''", "'"))
          .join(""))
        return at.every(Boolean) && `the ${m ? FILE[m[1]] : "file"}${
          at.length > 1 ? "s" : ""} at ${at.map(AT).join(", ")}`
      }
      // a table written by hand is its number of rows and its columns: the
      // rows are in the result
      const src = ([a, b]) => {
        const j = nx(ts, a - 1), r = ref(ts, j)
        const v = ts[j].t === "(" && nx(ts, j)
        if (!v || ts[v].w !== "values") return r?.n.length === 1
          ? MODEL(r.n[0].id) : file(a, b) || words(a, b).replace(/^\w+/, m =>
            cx.names.has(m.toLowerCase()) ? NAME(m) : m)
        const n = split(ts, v + 1, ts[j].c, j).length
        let e = nx(ts, ts[j].c)
        e = nx(ts, ts[e]?.w === "as" ? nx(ts, e) : e)
        return `a table written by hand, of ${n} row${n > 1 ? "s" : ""}` +
          (ts[e]?.t === "(" ? ": " + words(e + 1, ts[e].c) : "")
      }
      // a table after a comma: each of its rows with each row so far, or,
      // for an unnest, a row for each item of a list
      const pair = ([u, v]) => {
        if (ts[nx(ts, u - 1)].w === "lateral") u = nx(ts, u - 1) + 1
        const j = nx(ts, u - 1), p = nx(ts, j), q = qg(u, v)
        if (ts[j].w !== "unnest" || ts[p]?.t !== "(")
          return "Pair each row with every row of " + (q < 0 ? src([u, v])
            : sub(q))
        const c = nx(ts, nx(ts, ts[p].c))
        return "Make a row for each of " + words(p + 1, ts[p].c) +
          (ts[c]?.t === "(" && c < v ? ", as " + words(c + 1, ts[c].c) : "")
      }
      for (const f of at("from")) {
        const [a, b] = body(f)
        split(ts, a, b, g).forEach(([u, v], k) => {
          if (k) return S(pair([u, v]), f)
          const j = qg(u, v), t = j < 0 ? src([u, v]) : sub(j)
          S((/^the (\S+ )?files? at /.test(t) ? "Read " : "Start from ") + t, f)
        })
      }
      for (const j of at("join")) {
        let [a, b] = body(j), m = j, kind = []
        const [, ...rest] = split(ts, a, b, g)
        if (rest.length) b = rest[0][0] - 1
        while (MOD.has(ts[pv(ts, m)]?.w)) m = pv(ts, m), kind.unshift(ts[m].w)
        let on = a
        while (on < b && !(ts[on].o === g && /^(on|using)$/.test(ts[on].w)))
          on++
        const k = kind.find(x => x in JOIN && x) ?? "", q = qg(a, on)
        const c = on >= b ? "" : ts[on].w === "using" ? "it has the same " +
          words(nx(ts, on) + 1, ts[nx(ts, on)].c ?? b) : words(on + 1, b)
        S(fill(JOIN[k], [q < 0 ? src([a, on]) : sub(q), c])
          .replace(/, where $/, ""), j)
        for (const u of rest) S(pair(u), j)
      }
      for (const j of at("where"))
        S("Keep the rows where " + words(...body(j)), j)
      for (const j of at("group")) {
        const [a, b] = body(j)
        S(ts[a].w === "all" ? "Group the rows by each column that is not " +
          "a total" : "Group the rows by " + words(a, b), j)
      }
      for (const j of at("having"))
        S("Keep the groups where " + words(...body(j)), j)
      // every column (of a table), but some, or with some made anew
      const star = (u, v) => {
        let i = nx(ts, u - 1), t = "every column"
        if (ts[i + 1]?.t === "." && ts[i + 2]?.t === "*")
          t += " of " + ts[i].t, i += 2
        if (ts[i].t !== "*") return
        for (i = nx(ts, i); i < v; i = nx(ts, ts[i].c)) {
          const w = ts[i].w, p = nx(ts, i)
          if (ts[p]?.t !== "(") return
          const as = split(ts, p + 1, ts[p].c, p).map(([a, b]) => {
            const [e, al] = cut(ts, a, b)
            return al && w === "replace" ? `${al}: ${words(a, e)}`
              : words(a, b)
          }).join(", ")
          t += w === "exclude" ? ` but ${as}` : `, with ${as}`, i = p
        }
        return t
      }
      for (const j of at("select")) {
        let [a, b] = body(j), t = "Give"
        if (ts[a].w === "distinct")
          a = nx(ts, a), t = "Without duplicates, give"
        const top = i => {
          for (let o = ts[i].o; o !== g; o = ts[o].o) if (query(ts, o)) return
          return 1
        }
        const agg = !at("group").length && ts.slice(a, b).some((x, i) =>
          AGG.test(x.w) && ts[a + i + 1]?.t === "(" && top(a + i))
        const cols = split(ts, a, b, g).map(([u, v]) => {
          const [e, al] = cut(ts, u, v), ex = words(u, e)
          return al && al !== ex ? `${al}: ${ex}` : star(u, v) ?? ex
        })
        S(`${at("from").length ? agg ? "Over all the rows, give"
          : t : "Make one row of"}:`, j, {cols})
      }
      for (const j of at("qualify"))
        S("Keep the rows where " + words(...body(j)), j)
      for (const j of at("order")) S("Sort by " + words(...body(j)), j)
      for (const j of at("limit"))
        S(`Keep the first ${words(...body(j))} rows`, j)
      if (many) d--
    })
    sub = was
    return out
  }
  const out = plan(-1, 0, [])
  return cx.pre.length ? [...cx.pre, {d: 0, t: "Then:",
    i: level(ts, -1).cl.find(j => j >= level(ts, -1).m)},
    ...out.map(x => ({...x, d: x.d + 1}))] : out
}
