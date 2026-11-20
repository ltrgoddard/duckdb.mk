// lineage: the tables that none of the others read in the last column,
// those that read none of the others in the first, and the rest between by
// their longest path from the first, so that every line runs rightward.
// each column is by group, a group's tables together with a gap between,
// and within a group by the mean place of the tables a table reads, then
// of those that read it, back and forth, to cross fewer lines. a node has
// an id, the set of nodes it reads, a group and its element's attributes
const W = 170, G = 56, R = 24, NS = "http://www.w3.org/2000/svg"
export const dag = (ns, me) => {
  const set = new Set(ns), d = new Map, y = new Map, cols = []
  const ins = n => [...n.reads].filter(x => set.has(x) && x !== n)
  const outs = n => ns.filter(x => ins(x).includes(n))
  const dep = n => d.get(n) ?? (d.set(n, 0),
    d.set(n, Math.max(-1, ...ins(n).map(dep)) + 1).get(n))
  ns.forEach(dep)
  const end = Math.max(1, ...ns.filter(n => outs(n).length).map(n =>
    d.get(n) + 1))
  ns.forEach(n => !outs(n).length && d.set(n, end))
  ns.forEach(n => (cols[d.get(n)] ??= []).push(n))
  cols.forEach(c => c.sort((a, b) => a.id.localeCompare(b.id))
    .forEach((n, j) => y.set(n, j)))
  const mean = (n, f) => f(n).length ? f(n).reduce((a, x) => a + y.get(x), 0)
    / f(n).length : y.get(n)
  const place = c => {
    let g = 0
    c.forEach((n, j) => y.set(n, j + (g += j && n.group !== c[j - 1].group
      ? .5 : 0)))
  }
  for (let k = 0; k < 8; k++) for (const c of k % 2 ? [...cols].reverse()
    : cols) c && place(c.sort((a, b) => a.group.localeCompare(b.group) ||
      mean(a, k % 2 ? outs : ins) - mean(b, k % 2 ? outs : ins)))
  const svg = document.createElementNS(NS, "svg"), box = document
    .createElement("div"), at = n => [d.get(n) * (W + G), y.get(n) * R + R / 2]
  svg.setAttribute("width", cols.length * (W + G))
  svg.setAttribute("height", (Math.max(...y.values()) + 1) * R)
  box.className = "dag", box.append(svg)
  const light = id => box.querySelectorAll("path").forEach(p =>
    p.classList.toggle("on", p.dataset.e.split(" ").includes(id)))
  for (const n of ns) {
    const [x, t] = at(n), a = Object.assign(document.createElement("a"), {
      href: "#" + n.id, title: n.id, textContent: n.id, ...n.attrs,
      onmouseenter: () => light(n.id), onmouseleave: () => light()})
    a.style.cssText += `;left:${x}px;top:${t - R / 2 + 2}px;width:${W}px`
    a.classList.toggle("on", n === me)
    box.append(a)
    for (const r of ins(n)) {
      const [x1, y1] = at(r), x0 = x1 + W, m = (x0 + x) / 2
      const p = document.createElementNS(NS, "path")
      p.setAttribute("d", `M${x0} ${y1}C${m} ${y1} ${m} ${t} ${x} ${t}`)
      p.dataset.e = r.id + " " + n.id
      svg.append(p)
    }
  }
  return box
}
