// sql in plain words: a query's plan, its steps in the order that they run,
// from the tree that duckdb's json_serialize_sql gives. explain(node, ref)
// takes a statement's node and ref(name), which gives a model's label for a
// table's name or path (else null), and returns the steps: each has a depth,
// a phrase, its lines (for a select, a filter or a table written by hand),
// the location in the sql of its clause, and its query: json that
// json_deserialize_sql gives back as the sql of its rows. a phrase is a list
// of strings and marks, {kind, text}: a model, a name (a table that the plan
// makes), a place (a file), s a string, n a number. text(phrase) joins it

export const text = p => [].concat(p).map(x => x.text ?? x).join("")

// a phrase from a template: its values flattened, empty strings dropped
const w = (s, ...v) => s.flatMap((t, i) => [t, ...[].concat(v[i] ?? [])])
  .filter(x => x !== "")
const join = (ps, sep = ", ", last = sep) => ps.flatMap((p, i) =>
  [i ? i === ps.length - 1 ? last : sep : "", ...[].concat(p)])
  .filter(x => x !== "")
const mark = (kind, text) => ({kind, text: String(text)})
const fill = (t, args) => t.split(/\{(\d)\}/).flatMap((s, i) =>
  i % 2 ? args[s] ?? [] : s ? [s] : [])

// a call in words, by its function's name: a template whose {n} is its nth
// argument; a|b for one argument, then two or more; name() with none
const PHRASES = Object.entries({
  "the number of rows": "count_star count()", "the number of {0}": "count",
  "the total of {0}": "sum", "the mean of {0}": "avg mean",
  "the median of {0}": "median", "the lowest {0}": "min",
  "the highest {0}": "max", "any {0}": "any_value",
  "the first {0}": "first", "the last {0}": "last",
  "the first value of {0}": "first_value",
  "the last value of {0}": "last_value",
  "the {0} with the highest {1}": "arg_max max_by",
  "the {0} with the lowest {1}": "arg_min min_by",
  "the list of {0}": "list array_agg", "{0} joined by {1}": "string_agg",
  "whether any {0}": "bool_or", "whether every {0}": "bool_and",
  "{1} if {0}, else {2}": "if iff", "{0}, null if {1}": "nullif",
  "{0}, else {1}": "ifnull",
  "{0} rounded|{0} rounded to {1} places": "round",
  "{0} rounded down": "floor", "{0} rounded up": "ceil",
  "the size of {0}": "abs", "each of {0}": "unnest",
  "the length of {0}": "len length array_length",
  "the year of {0}": "year", "the month of {0}": "month",
  "{0} as {1}": "strftime", "{1} to the {0}": "date_trunc",
  "the {0}s from {1} to {2}": "date_diff datediff date_sub",
  "{0} with {1} as {2}": "replace regexp_replace",
  "{0} matches {1}": "regexp_matches",
  "the part of {0} that matches {1}": "regexp_extract",
  "{0} starts with {1}": "starts_with prefix",
  "{0} ends with {1}": "ends_with suffix",
  "every part of {0} that matches {1}": "regexp_extract_all",
  "the place of {1} in {0}": "strpos instr list_position list_indexof",
  "{0} read as a date in the form {1}": "strptime try_strptime",
  "the file name in {0}": "parse_filename",
  "the type of {0}": "json_type typeof",
  "each item of {0}|each item of {1} in {0}": "json_each",
  "{0}|the {1} in {0}": "json_extract json_extract_string",
  "the length of {0}|the length of {1} in {0}": "json_array_length",
  "the {0} of {1}": "date_part datepart", "today": "today() current_date()",
  "now": "now() current_timestamp()",
  "the standard deviation of {0}": "stddev stddev_samp",
  "{0} contains {1}": "contains list_contains st_contains",
  "part {2} of {0} split at {1}": "split_part",
  "{0} split at {1}": "string_split str_split", "{0}": "lower upper trim",
  "the previous {0}": "lag", "the next {0}": "lead",
  "the row's place": "row_number()", "the rank": "rank() dense_rank()",
  "the distance from {0} to {1}": "st_distance",
  "{0} meets {1}": "st_intersects", "the point at {0}, {1}": "st_point",
  "{0} is within {2} of {1}": "st_dwithin",
  "{0} filled with {1}|{0} filled with {1}": "format printf"
}).reduce((o, [t, names]) => (names.split(" ").forEach(n => o[n] = t), o), {})
const NEGATED = {regexp_matches: "{0} does not match {1}",
  contains: "{0} does not contain {1}",
  list_contains: "{0} does not contain {1}",
  starts_with: "{0} does not start with {1}",
  ends_with: "{0} does not end with {1}",
  st_intersects: "{0} does not meet {1}"}
const AGGREGATE = new Set(("count_star count sum avg mean median min max " +
  "any_value first last arg_max max_by arg_min min_by list array_agg " +
  "string_agg bool_or bool_and stddev stddev_samp").split(" "))
const SIGNS = {COMPARE_EQUAL: "=", COMPARE_NOTEQUAL: "≠",
  COMPARE_LESSTHAN: "<", COMPARE_GREATERTHAN: ">",
  COMPARE_LESSTHANOREQUALTO: "≤", COMPARE_GREATERTHANOREQUALTO: "≥",
  COMPARE_DISTINCT_FROM: "is not", COMPARE_NOT_DISTINCT_FROM: "is"}
// a like's pattern, by where its %s are: none, at its end, at its start, or
// both; and with a not
const LIKES = {"~~": 0, "!~~": 1, "~~*": 0, "!~~*": 1}
const LIKE_PHRASES = [["is", "is not"], ["starts with", "does not start with"],
  ["ends with", "does not end with"], ["contains", "does not contain"]]
const FILE_READ = new RegExp("^(read_(csv|csv_auto|parquet|json|json_auto|" +
  "ndjson|text|blob|xlsx)|parquet_scan|st_read)$")
const FILE_KINDS = {csv: "CSV file", tsv: "CSV file", parquet: "Parquet file",
  json: "JSON file", ndjson: "JSON file", text: "text file", txt: "text file",
  xlsx: "spreadsheet", shp: "map file", gpkg: "map file", geojson: "map file"}

const args = e => e.arguments?.map(a => a.expression) ?? e.children ?? []
const str = e => e?.type === "VALUE_CONSTANT" && e.literal.kind === "STRING"
  ? e.literal.text : null

// an expression in words
const ex = (c, e) => {
  const t = e.type, x = y => ex(c, y), a = args(e)
  if (t === "COLUMN_REF") return e.column_names.length === 1 &&
    {current_date: "today", current_timestamp: "now"}[e.column_names[0]] ||
    e.column_names.join(".")
  if (t === "VALUE_CONSTANT") {
    const {kind, text} = e.literal
    return kind === "NULL_LITERAL" ? "no value" : kind === "STRING"
      ? [mark("s", `'${text}'`)] : kind === "BOOLEAN" ? text : [mark("n", text)]
  }
  if (t in SIGNS) return w`${op(c, e.left)} ${SIGNS[t]} ${op(c, e.right)}`
  if (t === "COMPARE_BETWEEN" || t === "COMPARE_IN") return negatable(c, e)
  if (t === "CONJUNCTION_AND" || t === "CONJUNCTION_OR") return join(
    a.map(y => y.class === "CONJUNCTION" && y.type !== t ? w`(${x(y)})` : x(y)),
    t === "CONJUNCTION_AND" ? " and " : " or ")
  if (t === "OPERATOR_NOT")
    return negatable(c, a[0], true) ?? w`not ${op(c, a[0])}`
  if (t === "OPERATOR_IS_NULL") return w`${op(c, a[0])} has no value`
  if (t === "OPERATOR_IS_NOT_NULL") return w`${op(c, a[0])} has a value`
  if (t === "OPERATOR_CAST") return x(e.child)
  if (t === "OPERATOR_COALESCE") return join(a.map(y => op(c, y)), ", else ")
  if (t === "CASE_EXPR") return join([...e.case_checks.map(k =>
    w`${op(c, k.then_expr)} if ${x(k.when_expr)}`),
    ...e.else_expr ? [w`else ${op(c, e.else_expr)}`] : []])
  if (t === "SUBQUERY") return negatable(c, e)
  if (t === "ARRAY_EXTRACT") return str(a[1]) != null
    ? w`the ${str(a[1])} in ${op(c, a[0])}`
    : w`item ${x(a[1])} of ${op(c, a[0])}`
  if (t === "ARRAY_SLICE")
    return w`items ${x(a[1])} to ${x(a[2])} of ${op(c, a[0])}`
  if (t === "LAMBDA") return w`${x(e.lhs)} → ${x(e.expr)}`
  if (t === "STAR") return "every column"
  if (e.class === "WINDOW") return w`${call(c, e)}${frame(c, e)}`
  if (t === "FUNCTION") return e.is_operator ? operator(c, e) : call(c, e)
  return t.toLowerCase()
}
// an operand: in brackets if it has an else or a window of its own
const op = (c, e) => {
  const p = ex(c, e)
  return text(p).includes(", else ") || e.partitions?.length ||
    e.orders?.length ? w`(${p})` : p
}

// between, in, a query and their nots
const negatable = (c, e, not = false) => {
  const t = e.type, a = args(e), n = +not
  if (t === "COMPARE_BETWEEN") return w`${op(c, e.input)} is ${
    not ? "not " : ""}from ${op(c, e.lower)} to ${op(c, e.upper)}`
  if (t === "COMPARE_IN") {
    const l = a.slice(1).map(y => op(c, y))
    return w`${op(c, a[0])} is ${l.length > 2
      ? w`${["one of ", "none of "][n]}${join(l, ", ", " and ")}`
      : l.length > 1 ? not ? w`neither ${l[0]} nor ${l[1]}`
        : w`either ${l[0]} or ${l[1]}` : w`${not ? "not " : ""}${l[0]}`}`
  }
  if (t === "SUBQUERY") {
    const name = made(c, e.subquery.node)
    return e.subquery_type === "EXISTS"
      ? w`there are ${not ? "no " : ""}rows in ${name}`
      : e.subquery_type === "ANY"
      ? w`${op(c, e.child)} is ${not ? "not " : ""}in ${name}`
      : not ? w`not ${name}` : name
  }
  if (t === "FUNCTION" && e.function_name in LIKES) return like(c, e, not)
  if (t === "FUNCTION" && not && NEGATED[e.function_name])
    return fill(NEGATED[e.function_name], a.map(y => op(c, y)))
  if (t === "OPERATOR_IS_NULL" && not) return w`${op(c, a[0])} has a value`
}
// like: a % at its start or its end, and none inside, said in words
const like = (c, e, not) => {
  const [v, p] = args(e), s = str(p), name = e.function_name
  not = not !== (LIKES[name] === 1)
  if (s == null || /%/.test(s.slice(1, -1)))
    return w`${op(c, v)} ${not ? "not " : ""}${
      name.includes("*") ? "ilike" : "like"} ${ex(c, p)}`
  const k = +s.endsWith("%") + 2 * s.startsWith("%")
  return w`${op(c, v)} ${LIKE_PHRASES[k][+not]} ${
    mark("s", `'${s.slice(k > 1, k % 2 ? -1 : undefined)}'`)}${
    name.includes("*") ? " (in any case)" : ""}`
}
const operator = (c, e) => {
  const a = args(e), name = e.function_name, [l, r] = a.map(y => op(c, y))
  if (name in LIKES) return like(c, e, false)
  if (a.length === 1) return w`${name}${l}`
  if (name === "||") return join(a.map(y => op(c, y)), " followed by ")
  if (name === "->" || name === "->>") {
    const k = str(a[1])
    return k == null ? w`item ${r} of ${l}` : k.replace(/^\$\.?/, "")
      ? w`the ${k.replace(/^\$\.?/, "")} in ${l}` : l
  }
  return w`${l} ${name} ${r}`
}
// a call, by its phrase or as written, with its filter and its order
const call = (c, e) => {
  const name = e.function_name, a = args(e)
  const ps = a.map(y => PHRASES[name] && /^(\$\.)?\w+(\.\w+)*$/
    .test(str(y) ?? "-") ? str(y).replace(/^\$\./, "") : op(c, y))
  if (e.distinct && ps.length) ps[0] = w`distinct ${ps[0]}`
  const t = PHRASES[a.length ? name : name + "()"] ?? PHRASES[name]
  const forms = t?.split("|")
  const p = name === "getenv" ? w`$${str(a[0]) ?? ps[0]}`
    : name === "concat" ? join(ps, " followed by ")
    : name === "greatest" || name === "least"
    ? w`the ${name} of ${join(ps, ", ", " and ")}`
    : name === "list_value" ? w`[${join(ps)}]`
    : name === "struct_pack"
    ? w`{${join(ps.map((p, i) => w`${e.arguments[i].name}: ${p}`))}}`
    : forms ? fill(forms[Math.max(0, Math.min(a.length, forms.length) - 1)],
      name === "format" || name === "printf" ? [ps[0], join(ps.slice(1))] : ps)
    : w`${name}(${join(ps)})`
  const order = e.order_bys?.orders?.length
    ? w` in order of ${orders(c, e.order_bys.orders)}` : []
  return w`${p}${order}${e.filter || e.filter_expr ? w` among the rows where ${
    ex(c, e.filter ?? e.filter_expr)}` : ""}${
    e.ignore_nulls ? ", skipping missing values" : ""}`
}
// a window: within each partition. a total or a last value with an order
// and no frame of its own is of the rows so far; without either, of all
// the rows
const BOUNDS = {UNBOUNDED_PRECEDING: "the first row",
  UNBOUNDED_FOLLOWING: "the last row"}
const bound = (c, b, e) => BOUNDS[b] ?? (/^CURRENT/.test(b) ? "this row"
  : str(e) === "1" || e?.literal?.text === "1"
  ? `the row ${/PRECEDING/.test(b) ? "before" : "after"}`
  : w`${ex(c, e)} rows ${/PRECEDING/.test(b) ? "before" : "after"}`)
const frame = (c, e) => {
  const sum = AGGREGATE.has(e.function_name) || e.function_name === "last_value"
  const framed = !(e.start === "UNBOUNDED_PRECEDING" &&
    /^CURRENT_ROW_RANGE|^UNBOUNDED_FOLLOWING/.test(e.end))
  const parts = e.partitions?.length
    ? w` within each ${join(e.partitions.map(p => ex(c, p)))}` : []
  const order = e.orders?.length ? w`${sum && !framed ? ", so far" : ""
    } in order of ${orders(c, e.orders)}` : []
  return parts.length || order.length || framed && sum ? w`${parts}${order}${
    sum && framed ? w`, from ${bound(c, e.start, e.start_expr)} to ${
      bound(c, e.end, e.end_expr)}` : ""}` : sum ? " across all the rows" : []
}
const orders = (c, os) => join(os.map(o =>
  w`${ex(c, o.expression)}${o.type === "DESCENDING" ? " descending" : ""}`))

// tables

// a table: a model, a file, a query's name or its words, with its alias. a
// table written by hand is its size, its rows kept for its step
const table = (c, t) => {
  const as = t.alias && !/^valueslist$/i.test(t.alias)
    ? ` as ${t.alias}` : ""
  if (t.type === "BASE_TABLE") {
    const name = [t.schema_name, t.table_name].filter(Boolean).join(".")
    const model = c.ref(name)
    if (model) return w`${mark("model", model)}${
      t.alias && t.alias !== t.table_name ? as : ""}`
    if (c.names.has(name.toLowerCase()))
      return w`${mark("name", name)}${as}`
    return /[./]/.test(t.table_name) && !t.schema_name
      ? w`${files(c, [t.table_name])}${as}` : w`${name}${as}`
  }
  if (t.type === "TABLE_FUNCTION") {
    const f = t.function, [first] = args(f)
    const places = first && (first.function_name === "list_value"
      ? args(first) : [first]).map(str)
    return FILE_READ.test(f.function_name) && places?.every(p => p != null)
      ? w`${files(c, places, f.function_name)}${as}` : w`${ex(c, f)}${as}`
  }
  if (t.type === "EXPRESSION_LIST") return written(c, t, [])
  if (t.type === "SUBQUERY") {
    const n = t.subquery.node, from = n.from_table
    if (from?.type === "EXPRESSION_LIST")
      return written(c, from, t.column_name_alias ?? [])
    if (plain(n)) return w`${table(c, from)}${as}`
    return made(c, n, t.alias)
  }
  if (t.type === "PIVOT") return pivot(c, t)
  return t.type.toLowerCase()
}
// a query that is all of one table: from t
const plain = n => n.type === "SELECT_NODE" && n.from_table?.type ===
  "BASE_TABLE" && !n.where_clause && !n.modifiers?.length &&
  !n.cte_map?.map?.length && bare(n)
// a select of every column as it is
const bare = n => !n.group_expressions?.length && !n.having &&
  n.aggregate_handling !== "FORCE_AGGREGATES" && n.select_list.length === 1 &&
  n.select_list[0].type === "STAR" && !n.select_list[0].relation_name &&
  !n.select_list[0].exclude_list?.length &&
  !n.select_list[0].replace_list?.length && !n.select_list[0].columns &&
  !n.modifiers?.some(m => m.type === "DISTINCT_MODIFIER")
// files, by their kind and where they are; a model if one file is a model's
const files = (c, places, reader = "") => {
  const model = places.length === 1 && c.ref(places[0])
  if (model) return [mark("model", model)]
  const kind = FILE_KINDS[reader.match(/_(\w+?)(_auto)?$/)?.[1]] ??
    FILE_KINDS[places[0].match(/\.(\w+)$/)?.[1]?.toLowerCase()] ?? "file"
  return w`the ${kind}${places.length > 1 ? "s" : ""} at ${
    join(places.map(p => mark("place", p)))}`
}
// a table written by hand: its rows, each by its columns' names
const written = (c, t, names) => {
  c.rows = t.values.map(r => join(r.map((v, i) =>
    names[i] ? w`${names[i]}: ${ex(c, v)}` : ex(c, v))))
  const n = t.values.length
  return `a${/^(8|1[18](\d{3})*$)/.test(n) ? "n" : ""} ${n}-row table ` +
    "written by hand"
}
// a pivot: a column for each of its on's values, holding its using. an
// unpivot: a row for each of its on's columns, with the column's name and
// its value as its into's
const pivot = (c, t) => {
  const [p] = t.pivots, src = table(c, t.source)
  const entries = p.entries.map(e => e.star_expr ? ex(c, e.star_expr)
    : join(e.values?.map(v => ex(c, v)) ?? []))
  if (t.unpivot_names?.length) return w`Make a row for each of ${
    join(entries)} in ${src}, with the column's name as ${
    p.unpivot_names[0]} and its value as ${t.unpivot_names[0]}`
  return w`Make a column for each ${join(p.pivot_expressions.map(e =>
    ex(c, e)))}${entries.length ? w` (${join(entries)})` : ""} in ${src}${
    t.aggregates?.length ? w`, holding ${join(t.aggregates.map(a =>
      ex(c, a)))}` : ""}`
}

// steps

const STAGES = ["from", "where", "group", "having", "select", "qualify",
  "order", "limit"]
const STAR = {class: "STAR", type: "STAR", columns: false}
// a query cut after a stage: its rows at that step
const cut = (n, stage, from = n.from_table) => {
  const k = STAGES.indexOf(stage), m = n.modifiers ?? []
  const keep = (...ts) => m.filter(x => ts.includes(x.type))
  const q = {...n, from_table: from, where_clause: k > 0 ? n.where_clause
    : undefined, having: k > 2 ? n.having : undefined,
    qualify: k > 4 ? n.qualify : undefined, modifiers: k > 6 ? m
      : k > 5 ? keep("DISTINCT_MODIFIER", "ORDER_MODIFIER")
      : k > 3 ? keep("DISTINCT_MODIFIER") : []}
  if (k < 2) Object.assign(q, {select_list: [STAR], group_expressions: [],
    group_sets: [], aggregate_handling: "STANDARD_HANDLING"})
  if (k === 2 && n.group_expressions?.length)
    q.select_list = n.group_expressions
  return q
}
// a query with the ctes that it can read, as json_deserialize_sql takes it,
// less the locations of what has none (2^64 - 1, which json cannot hold)
const scoped = (n, ctes) => {
  const own = n.cte_map?.map ?? []
  return JSON.stringify({statements: [{node: {...n, cte_map: {map: [
    ...ctes.filter(e => !own.some(o => o.key === e.key)), ...own]}}}]},
  (k, v) => k === "query_location" && v > 1e15 ? undefined : v)
}
const named = name => ({type: "SELECT_NODE", select_list: [STAR],
  from_table: {type: "BASE_TABLE", table_name: name},
  aggregate_handling: "STANDARD_HANDLING"})
// the first place in the sql of anything in a tree
const loc = x => typeof x !== "object" || !x ? Infinity : Math.min(
  x.query_location < 1e15 ? x.query_location : Infinity,
  ...Object.values(x).map(loc))

export const explain = (node, ref = () => null) => {
  const c = {ref, made: [], names: new Set, letters: 0, rows: null,
    ctes: []}
  const main = plan(c, node, 0)
  return c.made.length ? [...c.made, {depth: 0, text: ["Then:"],
    query: scoped(node, []), at: loc(node)}, ...main.map(s =>
    ({...s, depth: s.depth + 1}))] : main
}
// a query inside another: a step of its own, made first and named by its
// cte or its alias (else a letter), so that a plan reads in the order that
// its rows are made
const made = (c, n, name, cte = false) => {
  const ctes = c.ctes, inner = plan(c, n, 1)
  name ??= String.fromCharCode(65 + c.letters++)
  c.names.add(name.toLowerCase())
  c.made.push({depth: 0, text: w`Make table ${mark("name", name)}:`,
    query: scoped(cte ? named(name) : n, ctes), at: loc(n)}, ...inner)
  return [mark("name", name)]
}
// the steps of a query, at a depth: its ctes made first, then its own
const plan = (c, n, depth) => {
  const outer = c.ctes, own = n.cte_map?.map ?? []
  c.ctes = [...outer.filter(e => !own.some(o => o.key === e.key)), ...own]
  for (const e of own)
    made(c, e.value.query_node ?? e.value.query?.node, e.key, true)
  const out = [], step = (text, query, at, extra = {}) => {
    const lines = extra.lines ?? c.rows
    out.push({depth, text: [].concat(text), query: scoped(query, c.ctes), at,
      ...lines && {lines: lines.map(l => [].concat(l))}})
    c.rows = null
  }
  if (n.type === "SELECT_NODE") part(c, n, step)
  else if (n.type === "SET_OPERATION_NODE" || n.type === "RECURSIVE_CTE_NODE") {
    const parts = n.type === "RECURSIVE_CTE_NODE"
      ? [[n.left, "Take the rows of"], [n.right, "Then, until none are new, " +
        "add the rows that this makes from them"]] : sets(n)
    for (const [p, lead] of parts) {
      if (plain(p)) step(w`${lead} ${table(c, p.from_table)}`, p, loc(p))
      else {
        step(lead + ":", p, loc(p))
        out.push(...plan(c, p, depth + 1))
      }
    }
    tail(c, n, step)
  }
  c.ctes = outer
  return out
}
// the parts of a union, an except or an intersect, with a lead for each
const SET_STEPS = {UNION: "Add the rows of", UNION_BY_NAME: "Add the rows of",
  EXCEPT: "Take away the rows of", INTERSECT: "Keep only the rows also in"}
const sets = n => {
  const [l, r] = n.children, same = l.type === n.type &&
    l.setop_type === n.setop_type && !l.modifiers?.length
  const lead = SET_STEPS[n.setop_type] + (n.setop_type === "UNION_BY_NAME"
    ? ", by their columns' names" : "") +
    (/^UNION/.test(n.setop_type) && !n.setop_all ? ", less duplicates" : "")
  return [...same ? sets(l) : [[l, "Take the rows of"]], [r, lead]]
}
// the sort and the limit of a query
const tail = (c, n, step) => {
  for (const m of n.modifiers ?? []) {
    if (m.type === "ORDER_MODIFIER")
      step(w`Sort by ${orders(c, m.orders)}`, cut(n, "order"), loc(m))
    if (m.type === "LIMIT_MODIFIER" || m.type === "LIMIT_PERCENT_MODIFIER") {
      const l = m.limit && ex(c, m.limit), o = m.offset && ex(c, m.offset)
      step(m.limit_type === "PERCENTAGE" || m.type === "LIMIT_PERCENT_MODIFIER"
        ? w`Keep the first ${l}% of the rows` : !l
        ? w`Leave out the first ${o} rows` : w`Keep the first ${l} rows${
          o ? w` after the first ${o}` : ""}`, n, loc(m))
    }
  }
}
// a select's clauses, in the order that they run
const part = (c, n, step) => {
  const joins = []
  let t = n.from_table
  for (; t?.type === "JOIN"; t = t.left) joins.unshift(t)
  if (t && t.type !== "EMPTY") step(first(c, t), cut(n, "from", t), loc(t))
  for (const j of joins) {
    const [t, x] = join1(c, j)
    step(t, cut(n, "from", j), j.query_location < 1e15 ? j.query_location
      : loc(j.right), x)
  }
  if (n.where_clause) filter(c, n, "rows", n.where_clause, "where", step)
  if (n.group_expressions?.length || n.aggregate_handling ===
    "FORCE_AGGREGATES") step(group(c, n), cut(n, "group"),
    loc(n.group_expressions))
  if (n.having) filter(c, n, "groups", n.having, "having", step)
  const [verb, lines] = select(c, n)
  if (!bare(n)) step(verb, cut(n, "select"), loc(n.select_list), lines)
  if (n.qualify) filter(c, n, "rows", n.qualify, "qualify", step)
  tail(c, n, step)
}
// a from's first table
const first = (c, t) => {
  if (t.type === "TABLE_FUNCTION" && t.function.function_name === "unnest")
    return unnest(c, t)
  const p = table(c, t), s = text(p)
  return /^Make /.test(s) ? p : /^the .*files? at/.test(s) ? w`Read ${p}`
    : w`Start from ${p}`
}
const unnest = (c, t) => w`Make a row for each of ${join(args(t.function)
  .map(a => ex(c, a)))}${t.column_name_alias?.length
  ? w`, as ${join(t.column_name_alias)}` : ""}`
// a join: its kind, its table and its condition
const JOINS = {INNER: ["Join {0}"], LEFT: ["Join {0}",
  ", keeping the rows with no match"],
  RIGHT: ["Join {0}", ", keeping its rows with no match"],
  OUTER: ["Join {0}", ", keeping the rows of both with no match"],
  SEMI: ["Keep the rows with a match in {0}"],
  ANTI: ["Keep the rows with no match in {0}"]}
const join1 = (c, j) => {
  const r = j.right, kind = j.ref_type
  if (kind === "CROSS") return [r.type === "TABLE_FUNCTION" &&
    r.function.function_name === "unnest" ? unnest(c, r)
    : w`Pair each row with every row of ${table(c, r)}`]
  const t = table(c, r)
  if (kind === "POSITIONAL") return [w`Join ${t} row by row`]
  if (kind === "NATURAL")
    return [w`Join ${t}, where the columns that they share are the same`]
  const [pre, suf = ""] = JOINS[j.join_type] ?? JOINS.INNER
  const head = fill(kind === "ASOF" ? pre.replace("{0}",
    "{0} at the nearest match") : pre, [t])
  const lines = j.using_columns?.length
    ? [w`it has the same ${join(j.using_columns, ", ", " and ")}`]
    : j.condition ? conditions(c, j.condition) : []
  if (!lines.length) return [w`${head}${suf}`]
  return lines.length > 1 ? [w`${head}${suf}, where:`, {lines}]
    : [w`${head}${suf ? " where " : ", where "}${lines[0]}${suf}`]
}
// a condition, a line for each part between its ands (or its ors)
const conditions = (c, e) => e.class === "CONJUNCTION"
  ? e.children.map((y, i) => w`${i ? e.type === "CONJUNCTION_AND" ? "and "
    : "or " : ""}${y.class === "CONJUNCTION" ? w`(${ex(c, y)})` : ex(c, y)}`)
  : [ex(c, e)]
// a filter; a row's place at most n is the first n rows (of each group)
const filter = (c, n, what, e, stage, step) => {
  let l = e.left
  if (l?.type === "COLUMN_REF" && l.column_names.length === 1)
    l = n.select_list.find(s => s.alias === l.column_names[0]) ?? l
  const k = +e.right?.literal?.text
  if (l?.type === "WINDOW_ROW_NUMBER" && e.right?.literal?.kind === "INTEGER" &&
    (e.type === "COMPARE_LESSTHANOREQUALTO" ||
      e.type === "COMPARE_EQUAL" && k === 1)) return step(w`Keep the first ${
    k > 1 ? w`${mark("n", k)} rows` : "row"}${l.partitions?.length
    ? w` of each ${join(l.partitions.map(p => ex(c, p)))}` : ""}${
    l.orders?.length ? w`, in order of ${orders(c, l.orders)}` : ""}`,
    cut(n, stage), loc(e))
  const lines = conditions(c, e)
  step(lines.length > 1 ? `Keep the ${what} where:`
    : w`Keep the ${what} where ${lines[0]}`, cut(n, stage), loc(e),
    lines.length > 1 ? {lines} : {})
}
// a group by: all, a rollup, a cube, grouping sets, or its columns
const group = (c, n) => {
  if (n.aggregate_handling === "FORCE_AGGREGATES")
    return "Group the rows by each column that is not a total"
  const g = n.group_expressions.map(e => ex(c, e)), s = n.group_sets ?? []
  if (s.length < 2) return w`Group the rows by ${join(g)}`
  if (s.length === g.length + 1 && s.every(x => x.every((i, k) => i === k)))
    return w`Group the rows by ${join(g)}, with ${g.length > 1
      ? "subtotals and " : ""}a total of all the rows`
  if (s.length === 2 ** g.length)
    return w`Group the rows by each combination of ${join(g)}, with totals`
  return w`Group the rows in turn ${join(s.map(x => x.length
    ? w`by ${join(x.map(i => g[i]), ", ", " and ")}` : "all together"),
    ", ", " and ")}`
}
// a select: its columns, by name; over all the rows if it totals them
const select = (c, n) => {
  const lines = n.select_list.map(e => {
    if (e.type === "STAR") return star(c, e)
    const p = ex(c, e)
    return e.alias && e.alias !== text(p) ? w`${e.alias}: ${p}` : p
  })
  const d = n.modifiers?.find(m => m.type === "DISTINCT_MODIFIER")
  const verb = !n.from_table || n.from_table.type === "EMPTY"
    ? "Make one row of" : totals(n) ? "Over all the rows, return"
    : d?.distinct_on_targets?.length ? w`For the first row of each ${
      join(d.distinct_on_targets.map(e => ex(c, e)))}, return`
    : d ? "Without duplicates, return" : "Return"
  return [w`${verb}:`, {lines}]
}
// whether a select with no group by totals all of its rows: a call to an
// aggregate at its own level, not in a window or a query inside it
const totals = n => !n.group_expressions?.length &&
  n.aggregate_handling !== "FORCE_AGGREGATES" && n.select_list.some(has)
const has = e => typeof e === "object" && e !== null && e.type !== "SUBQUERY" &&
  e.class !== "WINDOW" && (e.type === "FUNCTION" &&
    AGGREGATE.has(e.function_name) || Object.values(e).some(has))
// every column (of a table), but some, or with some made anew
const star = (c, e) => w`every column${e.relation_name
  ? ` of ${e.relation_name}` : ""}${e.exclude_list?.length ? w` but ${join(
  e.exclude_list.map(x => x.name ?? x.column_names?.join(".") ?? x))}` : ""}${
  e.replace_list?.length ? w`, with ${join(e.replace_list.map(r =>
    w`${r.key}: ${ex(c, r.value)}`))}` : ""}`
