// rows: a query's first N, as text, and N more each time the table is
// scrolled to its foot; the count only when asked for. a float is to six
// figures, or to a whole number if that is longer, with all of them on
// hover. an error of a kind in WHY has its likely cause before it.
// grid(st, out) gives run(tries), which gives the index of the try that ran
import {query, sql} from "./db.js"

const N = 200, WHY = [[/Referenced (table|column)/, "This part cannot run " +
  "alone if it uses columns of the query around it."],
  [/Table with name|Failed to open|No files found/, "A table or file that " +
  "this reads is not here: not built, or named by a macro or a variable."],
  [/NetworkError|GDAL|HTTP|Extension/, "The browser could not read a source " +
  "on another site, or lacks an extension."],
  [/Out of Memory|out of bounds|null function|unreachable/, "This needs " +
  "more memory than the browser gives DuckDB. Reload the page."]]
const NUM = /^(U?(TINY|SMALL|BIG|HUGE)?INT|INTEGER|FLOAT|DOUBLE|DECIMAL)/
const FLT = /^(FLOAT|DOUBLE|DECIMAL)/
const h = (tag, a, ...k) => {
  const e = Object.assign(document.createElement(tag), a)
  return e.append(...k), e
}
const cell = v => v == null || typeof v !== "object" ? v
  : v.byteLength != null ? `${v.byteLength} bytes`
  : JSON.stringify(v.toJSON?.() ?? v, (_, x) =>
    typeof x === "bigint" ? String(x) : x)
const sub = q => `(\n${q.replace(/;\s*$/, "")}\n)`
const page = (q, o) => query(
  `select columns(*)::varchar from ${sub(q)} limit ${N + 1} offset ${o}`)
  .catch(() => query(`from ${sub(q)} limit ${N + 1} offset ${o}`))

export const grid = (st, out) => {
  let runs = 0, more
  const say = (t, err) => (st.className = err ? "err" : "", st.textContent = t)
  out.onscroll = () => more &&
    out.scrollTop + out.clientHeight > out.scrollHeight - 400 && more()
  const run = async qs => {
    const k = ++runs, t0 = performance.now()
    qs = [qs].flat(), more = null, say("Running")
    try {
      let q, t, used
      for (const [i, x] of qs.entries()) try {
        t = await page(x, 0), q = x, used = i
        break
      } catch (e) { if (i === qs.length - 1) throw e }
      const ty = await sql(`describe select * from ${sub(q)}`)
      if (k !== runs) return
      const body = h("tbody"), tell = (n = body.rows.length) => st
        .replaceChildren(`${n.toLocaleString()} row${n === 1 ? "" : "s"}${
        more ? ", more below" : ""} · ${Math.round(performance.now() - t0)
        } ms `, ...more || n > N ? [h("button", {onclick: async e => {
          e.target.textContent = "Counting"
          const [{n}] = await sql(`select count(*)::int n from ${sub(q)}`)
          k === runs && e.target.replaceWith(`of ${n.toLocaleString()}`)
        }}, "Count")] : [])
      const add = t => {
        const cols = t.schema.fields.map((_, j) => t.getChildAt(j))
        body.append(...Array.from({length: Math.min(t.numRows, N)}, (_, i) =>
          h("tr", {}, ...cols.map((col, j) => {
            const raw = cell(col.get(i)), f = FLT.test(ty[j].column_type)
            const v = f && isFinite(raw) ? String(Math.abs(raw) < 1e5
              ? +(+raw).toPrecision(6) : Math.round(raw)) : raw
            return h("td", {className: v == null ? "null"
              : NUM.test(ty[j].column_type) ? "r" : "",
              title: v === raw ? "" : raw}, v ?? "null")
          }))))
        more = t.numRows > N && (async () => {
          more = null, st.firstChild.textContent = "Loading more "
          const u = await page(q, body.rows.length)
          k === runs && (add(u), tell())
        })
      }
      add(t)
      out.replaceChildren(h("table", {}, h("thead", {}, h("tr", {},
        ...ty.map(r => h("th", {}, r.column_name,
          h("small", {}, r.column_type))))), body))
      out.scrollTop = 0, tell()
      return used
    } catch (e) {
      if (k === runs) out.replaceChildren(), say([WHY.find(([r]) =>
        r.test(e.message))?.[1], e.message].filter(Boolean).join("\n\n"), 1)
    }
  }
  // no rows, and why
  run.say = (t, err) => (runs++, more = null, out.replaceChildren(),
    say(t, err))
  return run
}
