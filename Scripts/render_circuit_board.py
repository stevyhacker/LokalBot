#!/usr/bin/env python3
"""Renders web/assets/circuit-board.svg, the website's background tile.

The same circuit board as the autocomplete launch video
(Video/lokalbot-autocomplete-demo/comp.js): chips with buses leaving their
sides, traces on a grid with 45° bends, vias, pads and small two-pad parts.
The tile repeats seamlessly. It is drawn in white and used as a CSS mask, so
the page picks its colour for each theme.

Usage: Scripts/render_circuit_board.py [--seed N]
"""
import argparse
import pathlib
import random

OUT = pathlib.Path(__file__).resolve().parent.parent / "web" / "assets" / "circuit-board.svg"
TILE, PITCH = 1200, 16  # px per tile, px per grid step
N = TILE // PITCH
DIRS = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]


def board(seed):
    rnd = random.Random(seed)
    used = bytearray(N * N)
    at = lambda x, y: (y % N) * N + (x % N)
    free = lambda x, y: not used[at(x, y)]
    traces, ends, chips, parts = [], [], [], []

    def route(x, y, plan, steps, wander=0.08):
        """Follows `plan` ([direction, steps] runs), then wanders until `steps` run out."""
        if not free(x, y):
            return
        pts = [[x, y]]
        used[at(x, y)] = 1
        d, run = plan[0][0], 0
        queue = [k for k, n in plan for _ in range(n)]
        for s in range(steps):
            want = queue.pop(0) if queue else d
            if not queue and s > 2:
                if want % 2 and run >= 2 and rnd.random() < 0.4:
                    want = (want + rnd.choice((1, 7))) % 8
                elif not want % 2 and run >= 3 and rnd.random() < wander:
                    want = (want + rnd.choice((1, 7))) % 8
            tries = [want] if queue else [want, (want + 1) % 8, (want + 7) % 8]
            for k in tries:
                dx, dy = DIRS[k]
                if not free(x + dx, y + dy) or (k % 2 and (not free(x + dx, y) or not free(x, y + dy))):
                    continue
                if k != d:
                    run = 0
                d, x, y, run = k, x + dx, y + dy, run + 1
                used[at(x, y)] = 1
                if len(pts) > 1 and DIRS[k] == (_sign(pts[-1][0] - pts[-2][0]), _sign(pts[-1][1] - pts[-2][1])):
                    pts[-1] = [x, y]
                else:
                    pts.append([x, y])
                break
            else:
                break
        if len(pts) > 1:
            traces.append(pts)
            ends.append((pts[-1], rnd.random() < 0.7))

    for _ in range(200):
        if len(chips) >= 4:
            break
        w, h, x0, y0 = rnd.randint(5, 14), rnd.randint(5, 10), rnd.randrange(N), rnd.randrange(N)
        if all(free(x, y) for y in range(y0 - 4, y0 + h + 5) for x in range(x0 - 4, x0 + w + 5)):
            for y in range(y0, y0 + h + 1):
                for x in range(x0, x0 + w + 1):
                    used[at(x, y)] = 1
            chips.append((x0, y0, w, h))
    for x0, y0, w, h in chips:
        sides = [
            (6, [(x0 + 1 + i, y0 - 1) for i in range(w - 1)], (1, 0)),
            (2, [(x0 + 1 + i, y0 + h + 1) for i in range(w - 1)], (1, 0)),
            (4, [(x0 - 1, y0 + 1 + i) for i in range(h - 1)], (0, 1)),
            (0, [(x0 + w + 1, y0 + 1 + i) for i in range(h - 1)], (0, 1)),
        ]
        for o, pins, t in sides:
            if rnd.random() < 0.25:
                continue
            diag = (o + rnd.choice((1, 7))) % 8
            lean = DIRS[diag][0] * t[0] + DIRS[diag][1] * t[1]
            # The pin furthest along the lean turns first, so the bus stays parallel.
            order = sorted((p for p in pins if rnd.random() < 0.85), key=lambda p: -lean * (p[0] * t[0] + p[1] * t[1]))
            bend, out = rnd.randint(1, 6), rnd.randint(3, 20)
            for i, (px, py) in enumerate(order):
                route(px, py, [(o, 1 + i), (diag, bend), (o, out)], rnd.randint(out + i + bend, out + i + bend + 30))
    for _ in range(110):
        route(rnd.randrange(N), rnd.randrange(N), [(rnd.randrange(4) * 2, 1)], rnd.randint(6, 40), 0.1)
    for _ in range(26):
        x, y, across = rnd.randrange(N), rnd.randrange(N), rnd.random() < 0.5
        cells = [(x, y), (x + 1, y)] if across else [(x, y), (x, y + 1)]
        if all(free(*c) for c in cells):
            for c in cells:
                used[at(*c)] = 1
            parts.append((x, y, across))
    return traces, ends, chips, parts


def _sign(v):
    return (v > 0) - (v < 0)


P = lambda v: (v + 0.5) * PITCH


def copies(x0, y0, x1, y1):
    """Offsets that bring an element (bounding box in px) into the tile, so it wraps."""
    return [(ox, oy) for ox in (-TILE, 0, TILE) for oy in (-TILE, 0, TILE)
            if x1 + ox > -8 and x0 + ox < TILE + 8 and y1 + oy > -8 and y0 + oy < TILE + 8]


def fmt(v):
    return f"{v:g}"


def svg(seed):
    traces, ends, chips, parts = board(seed)
    lines, rings, dots, rects, outlines = [], [], [], [], []
    for pts in traces:
        xs, ys = [P(x) for x, _ in pts], [P(y) for _, y in pts]
        for ox, oy in copies(min(xs), min(ys), max(xs), max(ys)):
            lines.append("M" + "L".join(f"{fmt(x + ox)} {fmt(y + oy)}" for x, y in zip(xs, ys)))
    for (x, y), via in ends:
        cx, cy, r = P(x), P(y), 4.6 if via else 3.4
        for ox, oy in copies(cx - r, cy - r, cx + r, cy + r):
            arc = f"M{fmt(cx + ox - r)} {fmt(cy + oy)}a{r} {r} 0 1 0 {fmt(2 * r)} 0a{r} {r} 0 1 0 {fmt(-2 * r)} 0"
            (rings if via else dots).append(arc)
    for x, y, across in parts:
        w, h = (7, 9) if across else (9, 7)
        for cx, cy in ((P(x), P(y)), (P(x + 1), P(y)) if across else (P(x), P(y + 1))):
            for ox, oy in copies(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2):
                rects.append(f"M{fmt(cx + ox - w / 2)} {fmt(cy + oy - h / 2)}h{w}v{h}h{-w}z")
    for x0, y0, w, h in chips:
        x, y = P(x0) - PITCH * 0.2, P(y0) - PITCH * 0.2
        cw, ch = w * PITCH + PITCH * 0.4, h * PITCH + PITCH * 0.4
        for ox, oy in copies(x - 8, y - 8, x + cw + 8, y + ch + 8):
            outlines.append(f'<rect x="{fmt(x + ox)}" y="{fmt(y + oy)}" width="{fmt(cw)}" height="{fmt(ch)}" rx="6"/>')
            dots.append(f"M{fmt(x + ox + 8.5)} {fmt(y + oy + 12)}a3.5 3.5 0 1 0 7 0a3.5 3.5 0 1 0 -7 0")
            for i in range(1, w):
                px = P(x0 + i) + ox
                rects.append(f"M{fmt(px - 3)} {fmt(y + oy - 7)}h6v7h-6zM{fmt(px - 3)} {fmt(y + oy + ch)}h6v7h-6z")
            for i in range(1, h):
                py = P(y0 + i) + oy
                rects.append(f"M{fmt(x + ox - 7)} {fmt(py - 3)}h7v6h-7zM{fmt(x + ox + cw)} {fmt(py - 3)}h7v6h-7z")
    return "\n".join([
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{TILE}" height="{TILE}" viewBox="0 0 {TILE} {TILE}">',
        f"<!-- Generated by Scripts/render_circuit_board.py (seed {seed}); edit the script, not this file. -->",
        '<g fill="none" stroke="#fff" stroke-linecap="round" stroke-linejoin="round">',
        f'<path stroke-opacity=".62" stroke-width="2.6" d="{"".join(lines)}"/>',
        f'<path stroke-opacity=".8" stroke-width="2.2" d="{"".join(rings)}"/>',
        f'<g fill="#fff" fill-opacity=".07" stroke-opacity=".85" stroke-width="2.4">{"".join(outlines)}</g>',
        "</g>",
        f'<path fill="#fff" fill-opacity=".75" d="{"".join(dots)}"/>',
        f'<path fill="#fff" fill-opacity=".6" d="{"".join(rects)}"/>',
        "</svg>",
        "",
    ])


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--seed", type=int, default=11)
    args = parser.parse_args()
    OUT.write_text(svg(args.seed))
    print(f"{OUT.relative_to(OUT.parents[2])}: {OUT.stat().st_size / 1024:.1f} KB")


if __name__ == "__main__":
    main()
