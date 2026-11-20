// duckdb in the browser: duckdb-wasm and its worker from jsdelivr, at one
// version. file() names a url as the path that the sql reads it by
const V = "https://cdn.jsdelivr.net/npm/@duckdb/duckdb-wasm@1.33.1-dev114.0/"
const duckdb = await import(V + "+esm")
const db = new duckdb.AsyncDuckDB(new duckdb.VoidLogger, new Worker(
  URL.createObjectURL(new Blob([`importScripts("${V
  }dist/duckdb-browser-base.worker.js")`], {type: "text/javascript"}))))
await db.instantiate(V + "dist/duckdb-base.wasm")
const c = await db.connect()
export const query = s => c.query(s)
export const sql = async s => (await c.query(s)).toArray()
export const file = (path, url) => db.registerFileURL(path,
  new URL(url, location).href, duckdb.DuckDBDataProtocol.HTTP, false)
