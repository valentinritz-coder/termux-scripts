import json, os, re, shutil, sys
import xml.etree.ElementTree as ET
from pathlib import Path

def parse_bounds(b: str):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", b or "")
    if not m:
        return None
    x1, y1, x2, y2 = map(int, m.groups())
    if x2 <= x1 or y2 <= y1:
        return None
    return x1, y1, x2, y2

HTML = r"""<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>UI Viewer</title>
  <style>
    body { font-family: sans-serif; margin: 0; }
    header { padding: 10px 12px; border-bottom: 1px solid #ddd; }
    main { display: grid; grid-template-columns: 1fr; gap: 10px; padding: 10px; }
    .wrap { position: relative; width: 100%; }
    img { width: 100%; height: auto; display: block; }
    canvas { position: absolute; left: 0; top: 0; }
    .row { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
    input[type="text"] { flex: 1; min-width: 200px; padding: 8px; }
    button { padding: 8px 10px; }
    .list { max-height: 45vh; overflow: auto; border: 1px solid #ddd; border-radius: 8px; }
    .item { padding: 8px 10px; border-bottom: 1px solid #eee; cursor: pointer; }
    .item:hover { background: #f7f7f7; }
    .meta { font-size: 12px; color: #444; margin-top: 4px; }
    .tag { font-family: monospace; font-size: 12px; color: #222; }
  </style>
</head>
<body>
<header>
  <div class="row">
    <strong>UI Viewer</strong>
    <span class="tag" id="count"></span>
  </div>
  <div class="row" style="margin-top:8px">
    <input id="q" type="text" placeholder="filtrer: text, resource-id, content-desc…">
    <button id="onlyClickable">clickable</button>
    <button id="clear">reset</button>
  </div>
</header>

<main>
  <div class="wrap">
    <img id="shot" src="screen.png" alt="screenshot">
    <canvas id="cv"></canvas>
  </div>

  <div class="list" id="list"></div>
</main>

<script>
let nodes = [];
let filtered = [];
let clickableOnly = false;

const img = document.getElementById('shot');
const cv = document.getElementById('cv');
const ctx = cv.getContext('2d');
const list = document.getElementById('list');
const q = document.getElementById('q');
const count = document.getElementById('count');

function norm(s){ return (s||"").toLowerCase(); }

function resizeCanvas() {
  const r = img.getBoundingClientRect();
  cv.width = Math.round(r.width);
  cv.height = Math.round(r.height);
  drawAll();
}

function drawRect(n, highlight=false){
  const r = img.getBoundingClientRect();
  const sx = cv.width / img.naturalWidth;
  const sy = cv.height / img.naturalHeight;

  const x = Math.round(n.x1 * sx);
  const y = Math.round(n.y1 * sy);
  const w = Math.round((n.x2 - n.x1) * sx);
  const h = Math.round((n.y2 - n.y1) * sy);

  ctx.lineWidth = highlight ? 4 : 2;
  ctx.strokeStyle = highlight ? 'rgba(255,0,0,0.9)' : 'rgba(0,128,255,0.55)';
  ctx.strokeRect(x, y, w, h);
}

function drawAll(highlightId=null){
  ctx.clearRect(0,0,cv.width,cv.height);
  for(const n of filtered){
    drawRect(n, highlightId && n.id===highlightId);
  }
}

function renderList(){
  list.innerHTML = "";
  count.textContent = `${filtered.length}/${nodes.length}`;
  for(const n of filtered){
    const div = document.createElement('div');
    div.className = "item";
    const title = [n.text, n.desc, n.rid].filter(Boolean)[0] || n.cls || "(no label)";
    div.innerHTML = `<div><strong>${escapeHtml(title)}</strong></div>
      <div class="meta">
        <span class="tag">${escapeHtml(n.rid||"")}</span>
        <span class="tag">${escapeHtml(n.cls||"")}</span>
        ${n.clickable ? '<span class="tag">clickable</span>' : ''}
      </div>`;
    div.onclick = () => {
      drawAll(n.id);
      // petit scroll vers l’élément dans l’image (approx)
      window.scrollTo({ top: 0, behavior: 'smooth' });
    };
    list.appendChild(div);
  }
}

function escapeHtml(s){
  return (s||"").replace(/[&<>"']/g, m => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[m]));
}

function applyFilter(){
  const needle = norm(q.value);
  filtered = nodes.filter(n => {
    if(clickableOnly && !n.clickable) return false;
    if(!needle) return true;
    const hay = norm([n.text,n.desc,n.rid,n.cls].join(" "));
    return hay.includes(needle);
  }).slice(0, 400); // évite de dessiner 5000 rectangles
  renderList();
  drawAll();
}

document.getElementById('onlyClickable').onclick = () => {
  clickableOnly = !clickableOnly;
  applyFilter();
};

document.getElementById('clear').onclick = () => {
  q.value = "";
  clickableOnly = false;
  applyFilter();
};

q.addEventListener('input', applyFilter);

fetch('nodes.json').then(r => r.json()).then(data => {
  nodes = data;
  applyFilter();
});

img.onload = () => resizeCanvas();
window.addEventListener('resize', resizeCanvas);
</script>
</body>
</html>
"""

def main():
    if len(sys.argv) < 3:
        print("Usage: python make_ui_viewer.py <ui.xml> <screen.png> [out_dir]")
        sys.exit(2)

    xml_path = Path(sys.argv[1])
    png_path = Path(sys.argv[2])
    out_dir = Path(sys.argv[3]) if len(sys.argv) >= 4 else xml_path.parent / "viewer"

    out_dir.mkdir(parents=True, exist_ok=True)

    # Copy screenshot as fixed name
    shutil.copy2(png_path, out_dir / "screen.png")

    # Parse xml
    nodes = []
    try:
        root = ET.parse(xml_path).getroot()
    except Exception as e:
        print(f"Failed to parse XML: {e}")
        sys.exit(1)

    i = 0
    for n in root.iter():
        b = n.attrib.get("bounds", "")
        bb = parse_bounds(b)
        if not bb:
            continue
        x1,y1,x2,y2 = bb
        rid = n.attrib.get("resource-id", "")
        text = n.attrib.get("text", "")
        desc = n.attrib.get("content-desc", "")
        cls = n.attrib.get("class", "")
        clickable = (n.attrib.get("clickable","") == "true")
        enabled = (n.attrib.get("enabled","") != "false")
        if not enabled:
            continue
        # garde surtout les nodes utiles
        if not (rid or text or desc or clickable):
            continue
        area = (x2-x1)*(y2-y1)
        nodes.append({
            "id": i,
            "rid": rid,
            "text": text,
            "desc": desc,
            "cls": cls,
            "clickable": clickable,
            "x1": x1, "y1": y1, "x2": x2, "y2": y2,
            "area": area
        })
        i += 1

    # Tri: clickable + gros éléments en premier
    nodes.sort(key=lambda n: (1 if n["clickable"] else 0, n["area"]), reverse=True)

    (out_dir / "nodes.json").write_text(json.dumps(nodes, ensure_ascii=False, indent=2), encoding="utf-8")
    (out_dir / "index.html").write_text(HTML, encoding="utf-8")

    print(f"OK: {out_dir}")
    print("Run: cd <out_dir> && python -m http.server 8000")
    print("Open: http://127.0.0.1:8000")

if __name__ == "__main__":
    main()
