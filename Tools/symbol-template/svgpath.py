#!/usr/bin/env python3
"""Flatten an arbitrary SVG path into the `M`/`L`/`Z` subset the symbol builder
speaks, then fit it into Loom's 100-unit design box.

`build.py`'s own `transform`/`flatten` only ever had to handle what `mark.py`
emits — straight lines and circular arcs, absolute, always. Published artwork
does not oblige: it arrives with relative commands, cubic and quadratic Béziers,
shorthand continuations and elliptical arcs. Rather than teach the whole
pipeline that vocabulary, this reduces a path to points *once*, up front, and
hands the rest of the pipeline the same M/L/Z it already handles.

Flattening here is the same correctness requirement `build.py.flatten` is about
and not merely convenient: a curve subdivided by the renderer gets a
weight-dependent segment count, and the three weight variants then have no point
correspondence. Points fixed in Python are identical in all three by
construction.
"""
import math
import re

# One command letter, or one number (with exponent, and allowing the "1.5.5"
# run-on spelling SVG permits by treating a second '.' as a new number).
_TOKENS = re.compile(r"([MmZzLlHhVvCcSsQqTtAa])|(-?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?)")

CURVE_SEGMENTS = 16
ARC_SEGMENTS = 24


def _numbers(chunk):
    return [float(m.group(2)) for m in _TOKENS.finditer(chunk) if m.group(2) is not None]


def _cubic(p0, p1, p2, p3, segments):
    for i in range(1, segments + 1):
        t = i / segments
        u = 1 - t
        yield (
            u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
            u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
        )


def _arc(p0, rx, ry, rotation, large, sweep, end, segments):
    """SVG F.6.5 endpoint→centre conversion, then sampled. Degenerate radii fall
    back to a straight line, which is what the spec requires (F.6.2)."""
    x0, y0 = p0
    x1, y1 = end
    if rx == 0 or ry == 0 or (x0 == x1 and y0 == y1):
        yield end
        return
    rx, ry = abs(rx), abs(ry)
    phi = math.radians(rotation)
    cos_phi, sin_phi = math.cos(phi), math.sin(phi)
    dx2, dy2 = (x0 - x1) / 2, (y0 - y1) / 2
    x1p = cos_phi * dx2 + sin_phi * dy2
    y1p = -sin_phi * dx2 + cos_phi * dy2
    # F.6.6: scale the radii up if they cannot span the chord.
    lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1:
        scale = math.sqrt(lam)
        rx, ry = rx * scale, ry * scale
    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    factor = math.sqrt(max(0.0, num / den)) if den else 0.0
    if large == sweep:
        factor = -factor
    cxp, cyp = factor * rx * y1p / ry, -factor * ry * x1p / rx
    cx = cos_phi * cxp - sin_phi * cyp + (x0 + x1) / 2
    cy = sin_phi * cxp + cos_phi * cyp + (y0 + y1) / 2

    def angle(ux, uy):
        return math.atan2(uy, ux)

    theta0 = angle((x1p - cxp) / rx, (y1p - cyp) / ry)
    theta1 = angle((-x1p - cxp) / rx, (-y1p - cyp) / ry)
    delta = theta1 - theta0
    if sweep and delta < 0:
        delta += 2 * math.pi
    if not sweep and delta > 0:
        delta -= 2 * math.pi
    for i in range(1, segments + 1):
        t = theta0 + delta * i / segments
        px, py = rx * math.cos(t), ry * math.sin(t)
        yield (cos_phi * px - sin_phi * py + cx, sin_phi * px + cos_phi * py + cy)


def subpaths(d):
    """Every subpath of `d` as a list of points, curves already sampled.

    Closed subpaths keep their explicit closing point out of the list — the
    builder emits `Z`, which closes them, and a duplicated final point is a
    zero-length segment that some rasterizers render as a dot.
    """
    result = []
    current = []
    cursor = (0.0, 0.0)
    start = (0.0, 0.0)
    previous_control = None
    last_command = None

    def flush():
        nonlocal current
        if len(current) > 1:
            result.append(current)
        current = []

    for match in re.finditer(r"([MmZzLlHhVvCcSsQqTtAa])([^MmZzLlHhVvCcSsQqTtAa]*)", d):
        command, args = match.group(1), _numbers(match.group(2))
        relative = command.islower()
        upper = command.upper()
        # A repeated coordinate run after M is an implicit L (SVG 9.3.3).
        index = 0
        first = True
        while True:
            if upper == "Z":
                if current:
                    flush()
                cursor = start
                break
            if upper == "M":
                need = 2
            elif upper in ("L", "T"):
                need = 2
            elif upper in ("H", "V"):
                need = 1
            elif upper in ("C",):
                need = 6
            elif upper in ("S", "Q"):
                need = 4
            elif upper == "A":
                need = 7
            else:
                need = 0
            if need == 0 or index + need > len(args):
                break
            chunk = args[index:index + need]
            index += need

            if upper == "M":
                x, y = chunk
                if relative:
                    x, y = cursor[0] + x, cursor[1] + y
                if first:
                    flush()
                    cursor = start = (x, y)
                    current = [cursor]
                else:  # implicit lineto
                    cursor = (x, y)
                    current.append(cursor)
                previous_control = None
            elif upper == "L":
                x, y = chunk
                if relative:
                    x, y = cursor[0] + x, cursor[1] + y
                cursor = (x, y)
                current.append(cursor)
                previous_control = None
            elif upper == "H":
                x = chunk[0] + (cursor[0] if relative else 0)
                cursor = (x, cursor[1])
                current.append(cursor)
                previous_control = None
            elif upper == "V":
                y = chunk[0] + (cursor[1] if relative else 0)
                cursor = (cursor[0], y)
                current.append(cursor)
                previous_control = None
            elif upper in ("C", "S"):
                if upper == "C":
                    x1, y1, x2, y2, x, y = chunk
                    if relative:
                        x1, y1 = cursor[0] + x1, cursor[1] + y1
                        x2, y2 = cursor[0] + x2, cursor[1] + y2
                        x, y = cursor[0] + x, cursor[1] + y
                else:
                    x2, y2, x, y = chunk
                    if relative:
                        x2, y2 = cursor[0] + x2, cursor[1] + y2
                        x, y = cursor[0] + x, cursor[1] + y
                    # Shorthand: reflect the previous control point (SVG 9.3.6).
                    if previous_control and last_command in ("C", "S"):
                        x1 = 2 * cursor[0] - previous_control[0]
                        y1 = 2 * cursor[1] - previous_control[1]
                    else:
                        x1, y1 = cursor
                current.extend(_cubic(cursor, (x1, y1), (x2, y2), (x, y), CURVE_SEGMENTS))
                previous_control = (x2, y2)
                cursor = (x, y)
            elif upper in ("Q", "T"):
                if upper == "Q":
                    x1, y1, x, y = chunk
                    if relative:
                        x1, y1 = cursor[0] + x1, cursor[1] + y1
                        x, y = cursor[0] + x, cursor[1] + y
                else:
                    x, y = chunk
                    if relative:
                        x, y = cursor[0] + x, cursor[1] + y
                    if previous_control and last_command in ("Q", "T"):
                        x1 = 2 * cursor[0] - previous_control[0]
                        y1 = 2 * cursor[1] - previous_control[1]
                    else:
                        x1, y1 = cursor
                # Degree-elevate to a cubic so there is one sampler, not two.
                c1 = (cursor[0] + 2 / 3 * (x1 - cursor[0]), cursor[1] + 2 / 3 * (y1 - cursor[1]))
                c2 = (x + 2 / 3 * (x1 - x), y + 2 / 3 * (y1 - y))
                current.extend(_cubic(cursor, c1, c2, (x, y), CURVE_SEGMENTS))
                previous_control = (x1, y1)
                cursor = (x, y)
            elif upper == "A":
                rx, ry, rotation, large, sweep, x, y = chunk
                if relative:
                    x, y = cursor[0] + x, cursor[1] + y
                current.extend(_arc(cursor, rx, ry, rotation, int(large), int(sweep), (x, y), ARC_SEGMENTS))
                previous_control = None
                cursor = (x, y)
            last_command = upper
            first = False
        last_command = upper
    flush()
    return result


def fit(paths, box, cap_fraction=1.0):
    """Scale + centre `paths` (SVG coordinates, y down) into a design box.

    `box` is `(x0, x1, y0, y1)` in the same 100-unit space `mark.py` draws in.
    That space is y-**down**, like SVG's — `build.py.transform` maps `y - Y1`, so
    `Y0` lands on the capline and `Y1` on the baseline — which means the artwork's
    own orientation carries straight through and there is **no flip here**.
    Flipping (the obvious thing to write, on the assumption that a design box is
    y-up) renders the glyph upside down, which is a thing `check.py` cannot catch:
    an inverted symbol resolves perfectly well.
    """
    x0, x1, y0, y1 = box
    points = [p for path in paths for p in path]
    min_x = min(p[0] for p in points)
    max_x = max(p[0] for p in points)
    min_y = min(p[1] for p in points)
    max_y = max(p[1] for p in points)
    width, height = max_x - min_x, max_y - min_y
    target_height = (y1 - y0) * cap_fraction
    scale = min((x1 - x0) / width, target_height / height) if width and height else 1.0
    # Centre the leftover on both axes: a glyph narrower than the box sits in
    # the middle of the advance rather than against its left margin.
    offset_x = x0 + ((x1 - x0) - width * scale) / 2
    offset_y = y0 + ((y1 - y0) - height * scale) / 2
    out = []
    for path in paths:
        placed = [
            (offset_x + (px - min_x) * scale, offset_y + (py - min_y) * scale)
            for px, py in path
        ]
        out.append(placed)
    return out


def to_path_data(paths):
    """Back to a `d` string in the M/L/Z subset `build.py.transform` handles."""
    chunks = []
    for path in paths:
        head = path[0]
        chunks.append(f"M{head[0]:g},{head[1]:g}")
        for point in path[1:]:
            chunks.append(f"L{point[0]:g},{point[1]:g}")
        chunks.append("Z")
    return " ".join(chunks)
