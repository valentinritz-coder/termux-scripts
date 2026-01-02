#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

RUN_DIR="${1:-}"
[ -n "$RUN_DIR" ] || { echo "Usage: $0 /path/to/run_dir"; exit 2; }
[ -d "$RUN_DIR" ] || { echo "[!] RUN_DIR introuvable: $RUN_DIR"; exit 2; }

OUT="$RUN_DIR/viewers"
mkdir -p "$OUT"

python - "$RUN_DIR" "$OUT" <<'PY'
import html, re, sys
from pathlib import Path
import xml.etree.ElementTree as ET

run_dir = Path(sys.argv[1])
out_dir = Path(sys.argv[2])

def esc(s): 
    return html.escape(str(s), quote=True)

_bounds_re = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")

def parse_bounds(b):
    m = _bounds_re.match(b or "")
    if not m:
        return None
    x1, y1, x2, y2 = map(int, m.groups())
    if x2 <= x1 or y2 <= y1:
        return None
    return x1, y1, x2, y2

def overlay_from_xml(xml_path):
    try:
        root = ET.parse(xml_path).getroot()
    except Exception:
        return ""

    rects = []
    # fallback viewBox
    w, h = 1080, 2400

    # best guess from root bounds if present
    for n in root.iter("node"):
        bb = parse_bounds(n.get("bounds"))
        if bb:
            w, h = bb[2], bb[3]
            break

    for n in root.iter("node"):
        if n.get("clickable") != "true":
            continue
        if n.get("enabled") == "false":
            continue
        bb = parse_bounds(n.get("bounds"))
        if not bb:
            continue
        x1, y1, x2, y2 = bb
        area = (x2 - x1) * (y2 - y1)
        if area < 20000:
            continue

        rid = (n.get("resource-id") or "").strip()
        txt = (n.get("text") or "").strip()
        des = (n.get("content-desc") or "").strip()
        label = (rid or txt or des or "clickable")[:120]

        rects.append(
            f'<rect x="{x1}" y="{y1}" width="{x2-x1}" height="{y2-y1}" '
            f'style="fill:rgba(255,0,0,0.06);stroke:red;stroke-width:2">'
            f"<title>{esc(label)}</title></rect>"
        )

    return (
        f'<svg class="overlay" viewBox="0 0 {w} {h}" preserveAspectRatio="none">'
        + "".join(rects)
        + "</svg>"
    )

# Collect png/xml by base name
snap = {}
for f in run_dir.glob("*"):
    if f.suffix.lower() not in {".png", ".xml"}:
        continue
    snap.setdefault(f.stem, {})[f.suffix.lower()] = f.name

bases = sorted(snap.keys())
pages = []

for i, base in enumerate(bases):
    info = snap[base]
    png = info.get(".png")
    xml = info.get(".xml")

    prev_page = f"{bases[i-1]}.html" if i > 0 else ""
    next_page = f"{bases[i+1]}.html" if i + 1 < len(bases) else ""
    page = f"{base}.html"

    overlay = ""
    if png and xml:
        overlay = overlay_from_xml(run_dir / xml)

    body = []
    body.append(f"<h2>{esc(base)}</h2>")
    body.append('<div class="nav">')
    if prev_page:
        body.append(f'<a href="{esc(prev_page)}">⟵ Prev</a>')
    body.append('<a href="index.html">Index</a>')
    if next_page:
        body.append(f'<a href="{esc(next_page)}">Next ⟶</a>')
    body.append("</div>")

    if png:
        body.append('<div class="shot">')
        body.append(f'<img src="../{esc(png)}" alt="{esc(base)}">')
        if overlay:
            body.append(overlay)
        body.append("</div>")
    else:
        body.append("<p><b>PNG:</b> —</p>")

    if xml:
        xml_text = (run_dir / xml).read_text(errors="replace")
        if len(xml_text) > 600_000:
            xml_text = xml_text[:600_000] + "\n<!-- TRUNCATED -->\n"
        body.append("<details><summary>UI XML</summary>")
        body.append(f"<pre>{esc(xml_text)}</pre>")
        body.append("</details>")
    else:
        body.append("<p><b>XML:</b> —</p>")

    page_html = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>{esc(base)}</title>
<style>
body {{ font-family: system-ui, sans-serif; margin: 18px; }}
.nav a {{ margin-right: 12px; }}
.shot {{ position: relative; display: inline-block; max-width: 100%; }}
.shot img {{ max-width: 100%; height: auto; display: block; }}
.overlay {{ position: absolute; inset: 0; width: 100%; height: 100%; pointer-events: none; }}
pre {{ background:#111; color:#eee; padding:12px; overflow:auto; max-height: 50vh; }}
details summary {{ cursor: pointer; margin: 10px 0; }}
</style></head>
<body>{''.join(body)}</body></html>"""
    (out_dir / page).write_text(page_html, encoding="utf-8")
    pages.append((base, page, bool(png), bool(xml)))

rows = ["<tr><th>Snapshot</th><th>PNG</th><th>XML</th></tr>"]
for base, page, has_png, has_xml in pages:
    rows.append(
        "<tr>"
        f'<td><a href="{esc(page)}">{esc(base)}</a></td>'
        f"<td>{'✅' if has_png else '—'}</td>"
        f"<td>{'✅' if has_xml else '—'}</td>"
        "</tr>"
    )

index_html = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Run viewer</title>
<style>
body {{ font-family: system-ui, sans-serif; margin: 18px; }}
table {{ border-collapse: collapse; }}
th, td {{ border: 1px solid #ccc; padding: 6px 10px; }}
th {{ background: #f3f3f3; }}
</style></head>
<body>
<h1>Run viewer</h1>
<p>Run: <code>{esc(str(run_dir))}</code></p>
<p>Pages: {len(pages)}</p>
<table>{''.join(rows)}</table>
</body></html>"""
(out_dir / "index.html").write_text(index_html, encoding="utf-8")

print(f"[+] Viewers OK: {out_dir / 'index.html'}")
print(f"[+] Pages: {len(pages)}")
PY

echo "[*] Pour ouvrir:"
echo "    cd '$OUT' && python -m http.server 8000"
