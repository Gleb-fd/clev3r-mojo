"""Field model for «Старшая 3. Локализация» and generator of s3map.bpi.

Coordinates were measured on the 1092 px page of senior-3.pdf (2400 mm side),
so one pixel is 2400/1092 mm. Ports: 0 N, 1 E, 2 S, 3 W (top view, y down).
A turn is positive clockwise (right). Every edge is described from node `a`
as a list of segments: ("S", length_px) or ("A", radius_px, +1 right / -1 left).

python3 s3field.py      -> rewrites s3map.bpi
"""
import math
from pathlib import Path

MM = 2400 / 1092

NAMES = ["X1", "X2", "X3", "X4", "X5", "X6", "X7",
         "F", "Z1", "Z2", "Z3", "Z4", "Z5", "Z6", "TOP"]
X1, X2, X3, X4, X5, X6, X7, F, Z1, Z2, Z3, Z4, Z5, Z6, TOP = range(15)
CROSSINGS = 7  # 0..6 are 4-way crossings, the rest are line ends
N, E, S, W = range(4)

# (a, port at a, b, port at b, segments from a to b)
EDGES = [
    (X1, W, F, E, [("S", 285)]),
    (X1, N, TOP, S, [("S", 87)]),
    (X1, E, X2, W, [("S", 113), ("A", 116, +1), ("A", 112, -1), ("S", 79)]),
    (X1, S, X3, N, [("S", 227)]),
    (X2, N, Z1, S, [("S", 246)]),
    (X2, E, Z2, W, [("S", 159)]),
    (X2, S, X4, E, [("S", 146), ("A", 114, +1), ("S", 135)]),
    (X3, E, X4, N, [("S", 57), ("A", 116, +1), ("S", 143)]),
    (X3, S, X4, W, [("S", 141), ("A", 115, -1), ("S", 59)]),
    (X3, W, X5, N, [("S", 117), ("A", 116, -1), ("S", 204)]),
    (X4, S, X6, N, [("S", 228)]),
    (X5, W, Z6, E, [("S", 142)]),
    (X5, E, X7, N, [("S", 108), ("A", 115, +1), ("S", 51)]),
    (X5, S, X7, W, [("S", 51), ("A", 116, -1), ("S", 106)]),
    (X6, E, Z3, N, [("S", 205), ("A", 116, +1), ("S", 108)]),
    (X6, S, Z4, N, [("S", 222)]),
    (X6, W, X7, E, [("S", 183)]),
    (X7, S, Z5, E, [("S", 49), ("A", 115, +1), ("S", 250)]),
]
# The line from X1 to the north runs off the field without a cross bar:
# the robot has no event there, so it must never take that exit.
UNSAFE = {(X1, N)}
# Zone number for the cross bars Z1..Z6 (task numbering).
ZONES = {Z1: 1, Z2: 2, Z3: 3, Z4: 4, Z5: 5, Z6: 6}


def reverse(segments):
    return [(s[0], s[1], -s[2]) if s[0] == "A" else s for s in reversed(segments)]


def measure(segments):
    """Length in mm, net turn in degrees, straight pieces (start, end) in mm."""
    length, turn, pieces = 0.0, 0, []
    for seg in segments:
        if seg[0] == "S":
            pieces.append((length, length + seg[1] * MM))
            length += seg[1] * MM
        else:
            length += math.pi / 2 * seg[1] * MM
            turn += 90 * seg[2]
    return length, turn, pieces


def directed():
    """Directed edges: (a, pa, b, pb, length, turn, starts).

    starts: (dmin, dmax, turn_after, piece_len) for robot starting on a straight
    piece heading to b; d is the distance from the robot to b along the line.
    """
    out = []
    for a, pa, b, pb, segs in EDGES:
        for (u, pu, v, pv, s) in ((a, pa, b, pb, segs), (b, pb, a, pa, reverse(segs))):
            length, turn, pieces = measure(s)
            starts = []
            turned = 0
            for i, seg in enumerate(s):
                if seg[0] == "A":
                    turned += 90 * seg[2]
                    continue
                p0, p1 = pieces[sum(1 for x in s[:i] if x[0] == "S")]
                starts.append((length - p1, length - p0, turn - turned, p1 - p0))
            out.append((u, pu, v, pv, length, turn, starts))
    return out


def turn_after(u, pu, x):
    """Net turn of the arcs not yet finished x mm from u on edge (u, pu)."""
    for a, pa, b, pb, segs in EDGES:
        for (n, pn, s) in ((a, pa, segs), (b, pb, reverse(segs))):
            if (n, pn) != (u, pu):
                continue
            pos, turn = 0.0, 0
            for seg in s:
                if seg[0] == "S":
                    pos += seg[1] * MM
                else:
                    pos += math.pi / 2 * seg[1] * MM
                    if pos > x:
                        turn += 90 * seg[2]
            return turn
    raise KeyError((u, pu))


def write_bpi(path):
    edges = directed()
    lines = [
        "' Карта поля «Старшая 3». Файл сгенерирован s3field.py, руками не править.",
        "' Узлы: 0..6 перекрёстки X1..X7, 7 финиш F, 8..13 зоны 1..6, 14 обрыв TOP.",
        "' Порты: 0 N, 1 E, 2 S, 3 W. Ключ ребра k = узел * 4 + порт.",
        "' @nb[k] сосед или -1, @nq[k] порт входа в соседа, @nlen[k] мм,",
        "' @nturn[k] поворот на ребре (+ вправо), @nsafe[k] 1 можно ехать.",
        "' Старты @st_*: прямые участки, d = расстояние от робота до узла st_to.",
        "Function InitMap()",
        f"  @node_count = {len(NAMES)}",
        f"  @cross_count = {CROSSINGS}",
        "  For k = 0 To @node_count * 4 - 1",
        "    @nb[k] = 0 - 1",
        "    @nq[k] = 0",
        "    @nlen[k] = 0",
        "    @nturn[k] = 0",
        "    @nsafe[k] = 0",
        "  EndFor",
    ]
    lines += [
        f"  @finish_node = {F}",
        f"  @x1_node = {X1}",
        f"  @max_edge_mm = {round(max(e[4] for e in edges))}",
        "  For k = 0 To @node_count * 4 - 1",
        "    @barm[k] = 0",
        "  EndFor",
    ]
    for node, zone in ZONES.items():
        lines.append(f"  @zone_node[{zone}] = {node}")
    # Probe arms: both halves of a zone cross bar (125 mm each, parallel to the
    # field edge). The finish bar is not probed: its north half ends 45 mm
    # from the edge and its south half runs next to the code cells.
    for a, pa, b, pb, _ in EDGES:
        for node, port in ((a, pa), (b, pb)):
            if node in ZONES:
                for arm in ((port + 1) % 4, (port + 3) % 4):
                    lines.append(f"  @barm[{node * 4 + arm}] = 1")
    n_start = 0
    for u, pu, v, pv, length, turn, starts in edges:
        k = u * 4 + pu
        safe = 0 if (u, pu) in UNSAFE else 1
        lines.append(f"  ' {NAMES[u]}.{'NESW'[pu]} -> {NAMES[v]}.{'NESW'[pv]}")
        lines.append(f"  @nb[{k}] = {v}")
        lines.append(f"  @nq[{k}] = {pv}")
        lines.append(f"  @nlen[{k}] = {round(length)}")
        lines.append(f"  @nturn[{k}] = {turn}")
        lines.append(f"  @nsafe[{k}] = {safe}")
        if not safe:
            continue
        for dmin, dmax, t, plen in starts:
            lines.append(f"  @st_to[{n_start}] = {v}")
            lines.append(f"  @st_q[{n_start}] = {pv}")
            lines.append(f"  @st_dmin[{n_start}] = {round(dmin)}")
            lines.append(f"  @st_dmax[{n_start}] = {round(dmax)}")
            lines.append(f"  @st_turn[{n_start}] = {t}")
            lines.append(f"  @st_len[{n_start}] = {round(plen)}")
            n_start += 1
    lines.append(f"  @start_count = {n_start}")
    lines.append("EndFunction")
    Path(path).write_text("\n".join(lines) + "\n")
    return n_start


if __name__ == "__main__":
    for u, pu, v, pv, length, turn, starts in directed():
        print(f"{NAMES[u]:>3}.{'NESW'[pu]} -> {NAMES[v]:>3}.{'NESW'[pv]}"
              f" {length:6.0f} mm {turn:+4d}  starts:",
              ", ".join(f"[{a:.0f}..{b:.0f}]{t:+d} ({p:.0f})" for a, b, t, p in starts))
    count = write_bpi(Path(__file__).with_name("s3map.bpi"))
    print("starts:", count)
