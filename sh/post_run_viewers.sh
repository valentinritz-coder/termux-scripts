#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

RUN_DIR="${1:-}"
[ -n "$RUN_DIR" ] || { echo "Usage: $0 /path/to/SNAP_DIR"; exit 2; }
[ -d "$RUN_DIR" ] || { echo "[!] RUN_DIR introuvable: $RUN_DIR"; exit 2; }

OUT="$RUN_DIR/viewers"
mkdir -p "$OUT"

python - "$RUN_DIR" "$OUT" <<'PY'
import os, sys, html, re
from pathlib import Path
import xml.etree.ElementTree as ET

run_dir = Path(sys.argv[1])
out_dir = Path(sys.argv[2])

def esc(s): return html.escape(s, quote=True)

# Collect snapshots by basename (without extension)
files = list(run_dir.glob("*.*"))
snap = {}
for f in files:
    if f.suffix.lower() not in (".png", ".xml"): 
        continue
    base = f.name[:-len(f.suffix)]
    d = snap.setdefault(base, {})
    d[f.suffix.lower()] = f.name  # store filename (relative)

# sort by basename (timestamp prefix helps)
bases = sorted(snap.keys())

def parse_bounds(b):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", b or "")
    if not m: return None
    x1,y1,x2,y2 = map(int, m.groups())
    if x2<=x1 or y2<=y1: return None
    return x1,y1,x2,y2

def overlay_from_xml(xml_path):
    # returns (w,h, rects_html)
    try:
        root = ET.parse(xml_path).getroot()
    except Exception:
        return None

    # try find first node bounds as screen size
    first_node = None
    for n in root.iter("node"):
        first_node = n
        break
    w,h = 1080, 2400
    if first_node is not None:
        bb = parse_bounds(first_node.get("bounds"))
        if bb:
            w = bb[2]
            h = bb[3]

    rects = []
    for n in root.iter("node"):
        if n.get("clickable") != "true": 
            continue
        if n.get("enabled") == "false":
            continue
        bb = parse_bounds(n.get("bounds"))
        if not bb:
            continue
        x1,y1,x2,y2 = bb
        area = (x2-x1)*(y2-y1)
        if area < 20000:
            continue

        rid = (n.get("resource-id") or "").strip()
        txt = (n.get("text") or "").strip()
        des = (n.get("content-desc") or "").strip()
        label = rid or txt or des or "clickable"
        label = label[:120]

        rects.append(
            f'<rect x="{x1}" y="{y1}" width="{x2-x1}" height="{y2-y1}" '
            f'style="fill:rgba(255,0,0,0.05);stroke:red;stroke-width:2">'
            f'<title>{esc(label)}</title></rect>'
        )

    svg = (
        f'<svg class="overlay" viewBox="0 0 {w} {h}" preserveAspectRatio="none">'
        + "".join(rects) +
        "</svg>"
    )
    return svg

# Generate per-snapshot pages
pages = []
for i, base in enumerate(bases):
    info = snap[base]
    png = info.get(".png")
    xml = info.get(".xml")
    page = f"{base}.html"
    prev_page = f"{bases[i-1]}.html" if i > 0 else ""
    next_page = f"{bases[i+1]}.html" if i+1 < len(bases) else ""

    overlay = ""
    if png and xml:
        overlay = overlay_from_xml(run_dir / xml) or ""

    body_parts = []
    body_parts.append(f"<h2>{esc(base)}</h2>")
    body_parts.append('<div class="nav">')
    if prev_page: body_parts.append(f'<a href="{esc(prev_page)}">⟵ Prev</a>')
    body_parts.append(f'<a href="index.html">Index</a>')
    if next_page: body_parts.append(f'<a href="{esc(next_page)}">Next ⟶</a>')
    body_parts.append("</div>")

    if png:
        body_parts.append('<div class="shot">')
        body_parts.append(f'<img src="../{esc(png)}" alt="{esc(base)}">')
        if overlay:
            body_parts.append(overlay)
        body_parts.append("</div>")
    else:
        body_parts.append("<p><b>PNG:</b> (absent)</p>")

    if xml:
        xml_text = (run_dir / xml).read_text(errors="replace")
        # avoid ridiculous files in the browser
        if len(xml_text) > 600_000:
            xml_text = xml_text[:600_000] + "\n<!-- TRUNCATED -->\n"
        body_parts.append("<details open><summary>UI XML</summary>")
        body_parts.append(f"<pre>{esc(xml_text)}</pre>")
        body_parts.append("</details>")
    else:
        body_parts.append("<p><b>XML:</b> (absent)</p>")

    page_html = f"""<!doctype html>
<html><head><meta charset="utf-8">
<title>{esc(base)}</title>
<style>
body {{ font-family: system-ui, sans-serif; margin: 18px; }}
.nav a {{ margin-right: 12px; }}
.shot {{ position: relative; display: inline-block; max-width: 100%; }}
.shot img {{ max-width: 100%; height: auto; display: block; }}
.overlay {{ position: absolute; inset: 0; width: 100%; height: 100%; pointer-events: none; }}
pre {{ background:#111; color:#eee; padding:12px; overflow:auto; max-height: 50vh; }}
details summary {{ cursor: pointer; margin: 10px 0; }}
</style></head>
<body>
{''.join(body_parts)}
</body></html>
"""
    (out_dir / page).write_text(page_html, encoding="utf-8")
    pages.append((base, page, bool(png), bool(xml)))

# Generate index
rows = []
rows.append("<tr><th>Snapshot</th><th>PNG</th><th>XML</th></tr>")
for base, page, has_png, has_xml in pages:
    rows.append(
        "<tr>"
        f'<td><a href="{esc(page)}">{esc(base)}</a></td>'
        f"<td>{'✅' if has_png else '—'}</td>"
        f"<td>{'✅' if has_xml else '—'}</td>"
        "</tr>"
    )

index_html = f"""<!doctype html>
<html><head><meta charset="utf-8">
<title>Run viewer</title>
<style>
body {{ font-family: system-ui, sans-serif; margin: 18px; }}
table {{ border-collapse: collapse; }}
th, td {{ border: 1px solid #ccc; padding: 6px 10px; }}
th {{ background: #f3f3f3; }}
</style></head>
<body>
<h1>Run viewer</h1>
<p>Run: <code>{esc(str(run_dir))}</code></p>
<table>
{''.join(rows)}
</table>
</body></html>
"""
(out_dir / "index.html").write_text(index_html, encoding="utf-8")

print(f"[+] Viewers OK: {out_dir / 'index.html'}")
print(f"[+] Pages: {len(pages)}")
PY

echo "[*] Pour ouvrir:"
echo "    cd '$OUT' && python -m http.server 8000"
