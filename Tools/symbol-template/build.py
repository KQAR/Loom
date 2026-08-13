#!/usr/bin/env python3
"""Generate Loom's custom SF Symbols (loom.mark / loom.mark.intercept).

The symbol artwork is *generated*, not hand-drawn, so the weights stay in sync
and the mark can be retuned by editing `mark.py` instead of three baked path
strings. Run after any change there:

    python3 Tools/symbol-template/build.py            # writes into the app's asset catalog
    xcrun actool App/Resources/Assets.xcassets --compile /tmp/ac \
        --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon   # validate

Requires SF Symbols.app: the template's Notes/Guides scaffolding (artboard,
caplines, margin guides) is taken from a stock template inside its bundle, so
the file we hand Xcode is structurally identical to an app-exported one. Only
the artwork, the right-margin guides and the name are ours.
"""
import math, pathlib, re, sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import svgpath
from glyphs import STATIC
from mark import WEIGHTS, mark, X0, X1, Y0, Y1

DONOR = pathlib.Path("/Applications/SF Symbols.app/Contents/Resources/badge.record.svg")
ASSETS = pathlib.Path(__file__).resolve().parents[2] / "App/Resources/Assets.xcassets"
CAP = 70.459                                    # capline -> baseline, from the donor guides
SCALE = CAP / (Y1 - Y0)
WIDTH = (X1 - X0) * SCALE

_TOKEN = re.compile(r"([MLAZ])|(-?\d*\.?\d+)")
ARC_SEGMENTS = 12   # fixed, and that is the whole point — see flatten()

def transform(d):
    """Map a path from the 100-unit design box into variant-local units
    (origin = left margin on the baseline, y up is negative). Uniform scale, so
    arc radii scale too; only M/L/A/Z appear, which keeps this honest."""
    out, cmd, nums = [], None, []
    def flush():
        if cmd == "A":                          # rx ry rot large sweep x y
            rx, ry, rot, la, sw, x, y = nums
            out.append(f"A{rx*SCALE:g},{ry*SCALE:g} {rot:g} {int(la)} {int(sw)} "
                       f"{(x-X0)*SCALE:g},{(y-Y1)*SCALE:g}")
        elif cmd in ("M", "L"):
            for i in range(0, len(nums), 2):
                out.append(f"{cmd if i == 0 else 'L'}{(nums[i]-X0)*SCALE:g},"
                           f"{(nums[i+1]-Y1)*SCALE:g}")
        elif cmd == "Z":
            out.append("Z")
    for m in _TOKEN.finditer(d):
        if m.group(1):
            flush(); cmd, nums = m.group(1), []
        else:
            nums.append(float(m.group(2)))
    flush()
    return " ".join(out)

def flatten(d, seg=ARC_SEGMENTS):
    """Replace every arc with a fixed number of chords.

    Not an optimisation — a correctness requirement. CoreUI subdivides an arc
    into Béziers by radius, so variants drawn at different stroke weights get
    different segment counts; the Ultralight/Regular/Black interpolation then
    has no point correspondence and the symbol silently fails to decode at
    runtime while every build step still reports success. A fixed chord count
    makes the three variants structurally identical. `check.py` is what proves
    it, and 12 segments is indistinguishable from a true arc at menu-bar size.
    """
    out, cur = [], None
    for cmd, rest in re.findall(r"([MLAZ])([^MLAZ]*)", d):
        n = [float(x) for x in re.findall(r"-?\d*\.?\d+", rest)]
        if cmd in "ML":
            for i in range(0, len(n), 2):
                cur = (n[i], n[i + 1])
                out.append(f"{cmd if i == 0 else 'L'}{n[i]:g},{n[i+1]:g}")
        elif cmd == "A":
            rx, _, _, large, sweep, x, y = n
            x0, y0 = cur
            dx, dy = (x0 - x) / 2, (y0 - y) / 2
            scale = math.sqrt(max(0.0, rx * rx / (dx * dx + dy * dy) - 1))
            scale = scale if large != sweep else -scale   # SVG F.6.5.2 sign rule
            cx, cy = (x0 + x) / 2 + scale * dy, (y0 + y) / 2 - scale * dx
            a0, a1 = math.atan2(y0 - cy, x0 - cx), math.atan2(y - cy, x - cx)
            if sweep and a1 < a0:
                a1 += 2 * math.pi
            if not sweep and a1 > a0:
                a1 -= 2 * math.pi
            for i in range(1, seg + 1):
                t = a0 + (a1 - a0) * i / seg
                out.append(f"L{cx + rx * math.cos(t):g},{cy + rx * math.sin(t):g}")
            cur = (x, y)
        else:
            out.append("Z")
    return " ".join(out)


def build_static(symbol, path_data, cap_fraction):
    """A fixed outline, identical in all three weights.

    The same donor scaffolding and the same margins as `build` — only the
    artwork differs, and it does not vary by weight because a solid glyph has no
    stroke to vary (see `glyphs.py`). Emitting the same `d` three times is also
    the strongest possible answer to the point-correspondence failure `flatten`
    exists for.
    """
    placed = svgpath.fit(svgpath.subpaths(path_data), (X0, X1, Y0, Y1), cap_fraction)
    body = f'<path d="{transform(svgpath.to_path_data(placed))}"/>'
    svg = DONOR.read_text()
    for name in WEIGHTS:
        svg = re.sub(rf'(<g id="{name}-S"[^>]*>).*?(</g>)',
                     lambda m: f"{m.group(1)}\n   {body}\n  {m.group(2)}",
                     svg, count=1, flags=re.S)
        left = float(re.search(rf'<g id="{name}-S" transform="matrix\(1 0 0 1 ([\d.]+)', svg).group(1))
        svg = re.sub(rf'(<line id="right-margin-{name}-S"[^>]*?)x1="[\d.]+"([^>]*?)x2="[\d.]+"',
                     rf'\g<1>x1="{left + WIDTH:.4f}"\g<2>x2="{left + WIDTH:.4f}"', svg)
    svg = re.sub(r'(<text id="descriptive-name"[^>]*>)[^<]*(</text>)', rf'\g<1>{symbol}\g<2>', svg)
    return svg.replace('<!--glyph: ""', f'<!--glyph: "{symbol}"')


def write(symbol, svg):
    d = ASSETS / f"{symbol}.symbolset"
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{symbol}.svg").write_text(svg)
    (d / "Contents.json").write_text(
        '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  },\n'
        f'  "symbols" : [\n    {{\n      "filename" : "{symbol}.svg",\n'
        '      "idiom" : "universal"\n    }\n  ]\n}\n')
    print("wrote", d.relative_to(ASSETS.parents[2]))


def build(symbol, weft):
    svg = DONOR.read_text()
    for name, (sw, corner, node) in WEIGHTS.items():
        body = f'<path d="{flatten(transform(mark(sw, corner, node, filled_node=weft)))}"/>'
        svg = re.sub(rf'(<g id="{name}-S"[^>]*>).*?(</g>)',
                     lambda m: f"{m.group(1)}\n   {body}\n  {m.group(2)}",
                     svg, count=1, flags=re.S)
        left = float(re.search(rf'<g id="{name}-S" transform="matrix\(1 0 0 1 ([\d.]+)', svg).group(1))
        svg = re.sub(rf'(<line id="right-margin-{name}-S"[^>]*?)x1="[\d.]+"([^>]*?)x2="[\d.]+"',
                     rf'\g<1>x1="{left + WIDTH:.4f}"\g<2>x2="{left + WIDTH:.4f}"', svg)
    svg = re.sub(r'(<text id="descriptive-name"[^>]*>)[^<]*(</text>)', rf'\g<1>{symbol}\g<2>', svg)
    return svg.replace('<!--glyph: ""', f'<!--glyph: "{symbol}"')

if __name__ == "__main__":
    if not DONOR.exists():
        sys.exit(f"SF Symbols.app is required for the template scaffolding: {DONOR}")
    for symbol, weft in (("loom.mark", False), ("loom.mark.intercept", True)):
        write(symbol, build(symbol, weft))
    for symbol, (path_data, cap_fraction) in STATIC.items():
        write(symbol, build_static(symbol, path_data, cap_fraction))
    print(f"scale={SCALE:.5f} advance={WIDTH:.3f} cap={CAP} weights={list(WEIGHTS)}")
