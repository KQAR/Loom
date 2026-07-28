"""loom.mark — geometry for Loom's menu-bar symbol, as a function of weight.

The glyph: an outlined window sitting on a bus, with a node where it meets the
line — a client whose traffic passes through one point. Outlined, never filled:
the menu bar renders alpha only, so a solid body collapses into a block.

Everything is emitted as **closed fill contours** (SF Symbols templates take no
strokes). Holes — the window interior, the hollow node — are subpaths wound the
opposite way, so the nonzero fill rule punches them out.

Visual extents are pinned to one box across weights (x 6..94, y 8..92) so every
variant shares a bounding box.

    weight -> (stroke, corner radius, node radius)

Weights may differ freely **only because `build.py` flattens every arc to a fixed
number of chords**. Left as arcs, CoreUI subdivides them by radius, so the three
variants end up with different segment counts, interpolation has nothing to match
up, and the compiled symbol silently fails to decode — `actool` succeeds, the app
builds, and the icon is nil at runtime. Re-run `check.py` after touching these.
"""
WEIGHTS = {"Ultralight": (6, 11, 11), "Regular": (10, 11, 11), "Black": (14, 11, 11)}

X0, X1, Y0, Y1 = 6.0, 94.0, 8.0, 92.0
WIN_X0, WIN_X1, WIN_BOTTOM = 20.0, 80.0, 46.0     # window centreline
CX = 50.0                                          # stem / node centre


def rrect(x0, y0, x1, y1, r, hole=False):
    """Rounded rectangle. `hole=True` winds it the other way so the nonzero fill
    rule punches it out of whatever encloses it."""
    if not hole:
        return (f"M{x0+r:g},{y0:g} L{x1-r:g},{y0:g} A{r:g},{r:g} 0 0 1 {x1:g},{y0+r:g} "
                f"L{x1:g},{y1-r:g} A{r:g},{r:g} 0 0 1 {x1-r:g},{y1:g} "
                f"L{x0+r:g},{y1:g} A{r:g},{r:g} 0 0 1 {x0:g},{y1-r:g} "
                f"L{x0:g},{y0+r:g} A{r:g},{r:g} 0 0 1 {x0+r:g},{y0:g} Z")
    return (f"M{x0+r:g},{y0:g} A{r:g},{r:g} 0 0 0 {x0:g},{y0+r:g} "
            f"L{x0:g},{y1-r:g} A{r:g},{r:g} 0 0 0 {x0+r:g},{y1:g} "
            f"L{x1-r:g},{y1:g} A{r:g},{r:g} 0 0 0 {x1:g},{y1-r:g} "
            f"L{x1:g},{y0+r:g} A{r:g},{r:g} 0 0 0 {x1-r:g},{y0:g} Z")


def circle(cx, cy, r, hole=False):
    s = 0 if hole else 1
    return (f"M{cx-r:g},{cy:g} A{r:g},{r:g} 0 1 {s} {cx+r:g},{cy:g} "
            f"A{r:g},{r:g} 0 1 {s} {cx-r:g},{cy:g} Z")


def vstadium(cx, ya, yb, h):
    return (f"M{cx-h:g},{ya:g} A{h:g},{h:g} 0 0 1 {cx+h:g},{ya:g} L{cx+h:g},{yb:g} "
            f"A{h:g},{h:g} 0 0 1 {cx-h:g},{yb:g} Z")


def hstadium(cy, xa, xb, h):
    return (f"M{xa:g},{cy-h:g} L{xb:g},{cy-h:g} A{h:g},{h:g} 0 0 1 {xb:g},{cy+h:g} "
            f"L{xa:g},{cy+h:g} A{h:g},{h:g} 0 0 1 {xa:g},{cy-h:g} Z")


def mark(sw, corner, node, filled_node=False):
    """One weight of the mark. `filled_node=True` is the .intercept variant: the
    node solidifies when rules are acting on traffic."""
    h = sw / 2
    outer = node + h                        # the node's outer edge pins the bottom
    cy = Y1 - outer                         # node centre, and the bus line
    d = [
        # window: outlined, so an outer contour with the interior punched out
        rrect(WIN_X0 - h, Y0, WIN_X1 + h, WIN_BOTTOM + h, corner + h),
        rrect(WIN_X0 + h, Y0 + sw, WIN_X1 - h, WIN_BOTTOM - h, max(corner - h, 1.0), hole=True),
        # stem from the window down to the node
        vstadium(CX, WIN_BOTTOM, cy - outer, h),
        # the bus, broken either side of the node
        hstadium(cy, X0 + h, CX - outer - h, h),
        hstadium(cy, CX + outer + h, X1 - h, h),
        circle(CX, cy, outer),
    ]
    if not filled_node:
        d.append(circle(CX, cy, node - h, hole=True))
    return " ".join(d)


def stroked(sw, corner, node, filled_node=False):
    """Reference render of the same centrelines — only used to verify that the
    filled outlines above coincide with the shape they are meant to describe."""
    h = sw / 2
    outer = node + h
    cy = Y1 - outer
    return (f'<g fill="none" stroke="currentColor" stroke-width="{sw}" stroke-linecap="round">'
            f'<rect x="{WIN_X0}" y="{Y0+h}" width="{WIN_X1-WIN_X0}" '
            f'height="{WIN_BOTTOM-Y0-h}" rx="{corner}"/>'
            f'<path d="M{CX},{WIN_BOTTOM} V{cy-outer}"/>'
            f'<path d="M{X0+h},{cy} H{CX-outer-h}"/><path d="M{CX+outer+h},{cy} H{X1-h}"/>'
            f'<circle cx="{CX}" cy="{cy}" r="{node}" '
            f'fill="{"currentColor" if filled_node else "none"}"/></g>')
