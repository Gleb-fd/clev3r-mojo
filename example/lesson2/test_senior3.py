"""Source-driven tests for «Старшая 3»: the real BP localization code runs
against a graph-level robot model.

A small translator turns the BP functions of s3params/s3map/s3code/s3drive/
s3loc into Python. Motion primitives (FollowLeg, TurnToLine, UTurnLine,
LineCheck, MoveBack, MoveForward) are replaced by a world model: the robot
sits on a line leaving node m through port h, sensors x mm from the node.
Odometry noise scales distances and body turns. Sensor timing, PD stability,
slip and the real geometry of the robot are not covered here.
"""
import itertools
import math
import random
import re
import unittest
from collections import defaultdict
from pathlib import Path

import s3field as fld

ROOT = Path(__file__).resolve().parent
SOURCES = ["s3params.bpi", "s3map.bpi", "s3code.bpi", "s3drive.bpi", "s3loc.bpi"]
MOCKED = {"FollowLeg", "TurnToLine", "UTurnLine", "LineCheck", "MoveBack", "MoveForward",
          "SpinWatch", "ShowLoc"}
SIGNATURE = re.compile(r"^Function (\w+)\((.*?)\)\s*$", re.M)


def parse_params(text):
    ins, outs = [], []
    for param in filter(None, (p.strip() for p in text.split(","))):
        kind, _type, name = param.split()
        (ins if kind == "in" else outs).append(name)
    return ins, outs


def expr(text):
    parts = re.split(r'("[^"\n]*")', text)
    for i in range(0, len(parts), 2):
        p = parts[i]
        p = re.sub(r"@(\w+)\s*\[", r'GA("\1")[', p)
        p = re.sub(r"@(\w+)", r'G["\1"]', p)
        p = p.replace("Math.Pi", "math.pi")
        p = re.sub(r"\b(Math|Text)\.(\w+)\(", r"\1_\2(", p)
        p = p.replace("<>", "!=")
        p = re.sub(r"(?<![<>=!])=(?!=)", "==", p)
        p = re.sub(r"\bAnd\b", "and", p)
        p = re.sub(r"\bOr\b", "or", p)
        parts[i] = p
    return "".join(parts)


def split_args(text):
    args, depth, cur = [], 0, ""
    for ch in text:
        if ch == "," and depth == 0:
            args.append(cur.strip())
            cur = ""
            continue
        depth += ch in "(["
        depth -= ch in ")]"
        cur += ch
    if cur.strip():
        args.append(cur.strip())
    return args


def translate(name, ins, outs, body, sigs):
    lines = [f"def {name}({', '.join(ins)}):"]
    local_arrays = set(re.findall(r"(?<![@\w.])([a-z_]\w*)\[", body)) - set(ins)
    for arr in sorted(local_arrays):
        lines.append(f"    {arr} = defaultdict(float)")
    for out in outs:
        lines.append(f"    {out} = 0")
    ret = "return " + (", ".join(outs) if outs else "None")
    indent, stack = 1, []
    for raw in body.splitlines():
        text = strip_comment(raw)
        if not text:
            continue
        pad = "    " * indent
        if text in ("EndIf", "EndWhile", "EndFor"):
            stack.pop()
            indent -= 1
            continue
        if text == "Else":
            lines.append("    " * (indent - 1) + "else:")
            continue
        m = re.fullmatch(r"ElseIf (.+) Then", text)
        if m:
            lines.append("    " * (indent - 1) + f"elif {expr(m[1])}:")
            continue
        m = re.fullmatch(r"If (.+) Then", text)
        if m:
            lines.append(pad + f"if {expr(m[1])}:")
            stack.append("if")
            indent += 1
            continue
        m = re.fullmatch(r"While (.+)", text)
        if m:
            lines.append(pad + f"while {expr(m[1])}:")
            stack.append("while")
            indent += 1
            continue
        m = re.fullmatch(r"For (\w+) = (.+) To (.+)", text)
        if m:
            lines.append(pad + f"for {m[1]} in range(int({expr(m[2])}), int({expr(m[3])}) + 1):")
            stack.append("for")
            indent += 1
            continue
        if text == "Break":
            lines.append(pad + "break")
            continue
        if text == "Return":
            lines.append(pad + ret)
            continue
        m = re.fullmatch(r"(@?\w+(?:\[.+\])?) = (.+)", text)
        if m:
            lines.append(pad + f"{expr(m[1])} = {expr(m[2])}")
            continue
        m = re.fullmatch(r"([\w.]+)\((.*)\)", text)
        if not m:
            raise ValueError(f"{name}: unsupported line {text!r}")
        callee, args = m[1], split_args(m[2])
        if callee in sigs:
            cins, couts = sigs[callee]
            if len(args) != len(cins) + len(couts):
                raise ValueError(f"{name}: bad call {text!r}")
            call = f"{callee}({', '.join(expr(a) for a in args[:len(cins)])})"
            if couts:
                targets = ", ".join(expr(a) for a in args[len(cins):])
                lines.append(pad + f"{targets}{',' if len(couts) == 1 else ''} = _tuple({call})")
            else:
                lines.append(pad + call)
        else:
            lines.append(pad + f"BUILTIN({callee!r}, {', '.join(expr(a) for a in args)})")
    if stack:
        raise ValueError(f"{name}: unclosed block")
    lines.append("    " + ret)
    return "\n".join(lines)


def strip_comment(line):
    quoted = False
    for i, ch in enumerate(line):
        if ch == '"':
            quoted = not quoted
        elif ch == "'" and not quoted:
            return line[:i].strip()
    return line.strip()


def fmt(value):
    return str(int(value)) if float(value).is_integer() else str(value)


class World:
    """Robot on a line leaving node `m` through port `h`, sensors `x` mm out."""

    def __init__(self, G, dist_scale=1.0, turn_scale=1.0, seed=0, leg_jitter=0.0):
        self.G = G
        self.leg_jitter = leg_jitter
        self.dist_scale = dist_scale
        self.turn_scale = turn_scale
        self.rng = random.Random(seed)
        self.edges = {(u, pu): (v, pv, L, t) for u, pu, v, pv, L, t, _ in fld.directed()}
        self.main = {}
        for u, pu, v, pv, *_ in fld.directed():
            if u >= fld.CROSSINGS:
                self.main[u] = pu
        self.log = []
        self.m = self.h = self.x = None

    def place_on_edge(self, u, pu, x):
        self.m, self.h, self.x = u, pu, x

    def arrival(self):
        return self.m, (self.h + 2) % 4

    def lines_at(self, m):
        if m < fld.CROSSINGS:
            return {p for p in range(4) if (m, p) in self.edges}
        mp = self.main[m]
        return {mp, (mp + 1) % 4, (mp + 3) % 4}

    def kind(self):
        """'edge', 'arm' (half of a cross bar) or 'stub' (beyond a bar)."""
        if self.m < fld.CROSSINGS or self.h == self.main[self.m]:
            return "edge" if (self.m, self.h) in self.edges else "stub"
        return "arm" if self.h != (self.main[self.m] + 2) % 4 else "stub"

    def follow(self, limit_mm, speed, grey_check):
        G = self.G
        kind = self.kind()
        assert kind != "stub", f"drove past the bar at {fld.NAMES[self.m]}"
        assert (self.m, self.h) not in fld.UNSAFE, "drove to the field edge (TOP)"
        G["leg_event"] = G["leg_grey"] = G["leg_creep"] = G["leg_turn"] = 0
        if kind == "edge":
            v, pv, L, turn = self.edges[(self.m, self.h)]
            scale = self.dist_scale * (1 + self.rng.uniform(-self.leg_jitter, self.leg_jitter))
            need = (L - self.x) * scale
            if need <= limit_mm:
                creep = 30 if grey_check else 4
                G["leg_event"] = 1
                G["leg_mm"] = need + self.rng.uniform(-8, 8)
                turn = fld.turn_after(self.m, self.h, self.x)
                G["leg_turn"] = turn * self.turn_scale + self.rng.uniform(-12, 12)
                G["leg_grey"] = int(bool(grey_check) and v == fld.F)
                G["leg_creep"] = creep
                G["motion_status"] = 1
                self.log.append((fld.NAMES[self.m], "NESW"[self.h], fld.NAMES[v]))
                self.m, self.h, self.x = v, (pv + 2) % 4, creep
                return
        G["leg_mm"] = limit_mm
        G["motion_status"] = 2
        self.x += limit_mm / self.dist_scale
        if kind == "arm":
            assert self.x < 260, "ran far off the bar arm"

    def turn_to_line(self, direction, approach_deg, speed, max_turn):
        G = self.G
        self.x += approach_deg / G["deg_per_mm"]
        assert abs(self.x - G["sensor_mm"]) < 1 or approach_deg == 0, "axle not on node"
        new = (self.h + (1 if direction == 2 else 3)) % 4
        if self.m >= fld.CROSSINGS and new != self.main[self.m]:
            assert self.m != fld.F, "probed the finish bar"
        if new not in self.lines_at(self.m):
            G["motion_status"] = 2
            return
        self.h, self.x = new, G["sensor_mm"]
        G["motion_status"] = 1

    def uturn(self):
        G = self.G
        self.h = (self.h + 2) % 4
        self.x = 2 * G["sensor_mm"] - self.x
        assert self.h in self.lines_at(self.m)
        G["motion_status"] = 1

    def line_check(self):
        kind = self.kind()
        if kind == "edge":
            return 1
        arm = 150 if self.m == fld.F else 125
        return int(self.x < arm)

    def move_back(self, mm):
        self.x -= mm / self.dist_scale
        self.G["motion_status"] = 1


def load(world_args=None):
    G = defaultdict(float)
    arrays = defaultdict(lambda: defaultdict(float))
    sigs, bodies = {}, []
    for src in SOURCES:
        text = (ROOT / src).read_text()
        for m in re.finditer(r"^Function (\w+)\((.*?)\)\n(.*?)^EndFunction\s*$", text, re.M | re.S):
            sigs[m[1]] = parse_params(m[2])
            bodies.append((m[1], m[3]))
    sigs["TurnToLine"] = (["direction", "approach", "speed", "max_turn"], [])
    sigs["MoveForward"] = (["degrees", "speed"], [])
    builtins_called = []

    def BUILTIN(name, *args):
        builtins_called.append(name)
        if name.split(".")[0] not in ("LCD", "Speaker", "Program", "Motor", "Buttons"):
            raise AssertionError(f"unexpected builtin {name}")

    ns = {
        "G": G, "GA": lambda n: arrays[n], "math": math, "defaultdict": defaultdict,
        "BUILTIN": BUILTIN, "_tuple": lambda r: r if isinstance(r, tuple) else (r,),
        "Math_Abs": abs, "Math_Max": max, "Math_Min": min, "Math_Floor": math.floor,
        "Math_Round": round, "Math_Remainder": lambda a, b: math.fmod(a, b),
        "Text_Append": lambda a, b: fmt(a) + fmt(b),
    }
    for name, body in bodies:
        if name in MOCKED:
            continue
        ins, outs = sigs[name]
        exec(compile(translate(name, ins, outs, body, sigs), f"<BP {name}>", "exec"), ns)  # noqa: S102
    world = World(G, **(world_args or {}))
    ns["FollowLeg"] = world.follow
    ns["TurnToLine"] = world.turn_to_line
    ns["UTurnLine"] = world.uturn
    ns["LineCheck"] = world.line_check
    ns["MoveBack"] = world.move_back
    ns["MoveForward"] = lambda deg, speed: G.__setitem__("motion_status", 1)
    ns["ShowLoc"] = lambda: None
    for init in ("S3Params", "InitMap", "CodeInit", "DriveInit", "LocInit"):
        ns[init]()
    G["calibrated"] = 1
    return ns, G, arrays, world


def start_cases(start_min=280):
    for u, pu, v, pv, L, turn, starts in fld.directed():
        if (u, pu) in fld.UNSAFE:
            continue
        for dmin, dmax, _t, plen in starts:
            if plen < start_min:
                continue
            for f in (0.05, 0.5, 0.95):
                d = dmin + f * (dmax - dmin)
                yield u, pu, L - d


class LocalizationTests(unittest.TestCase):
    def run_start(self, u, pu, x, **world_args):
        ns, G, arrays, world = load(world_args)
        world.place_on_edge(u, pu, x)
        ok = ns["Localize"]()
        return ok, G, world

    def test_every_start_localizes(self):
        legs = defaultdict(int)
        for scales in itertools.product((0.93, 1.0, 1.07), (0.7, 1.0, 1.3)):
            for seed, (u, pu, x) in enumerate(start_cases()):
                with self.subTest(start=(fld.NAMES[u], "NESW"[pu], round(x)), scales=scales):
                    ok, G, world = self.run_start(u, pu, x, dist_scale=scales[0],
                                                  turn_scale=scales[1], seed=seed)
                    self.assertEqual(ok, 1, f"loc_fail={G['loc_fail']}")
                    self.assertEqual((G["cur_node"], G["cur_q"]), world.arrival())
                    legs[int(G["loc_legs"])] += 1
        self.assertLessEqual(max(legs), 6, dict(legs))

    def test_pdf_example_start(self):
        # senior-3.pdf, page 1: on x=615 between the arc and X4, heading north.
        ok, G, world = self.run_start(fld.X4, fld.N, 840 - 600)
        self.assertEqual(ok, 1)
        self.assertEqual((G["cur_node"], G["cur_q"]), world.arrival())

    def test_drive_to_finish_from_every_start(self):
        for seed, (u, pu, x) in enumerate(start_cases()):
            with self.subTest(start=(fld.NAMES[u], "NESW"[pu], round(x))):
                ns, G, arrays, world = load({"dist_scale": 1.04, "seed": seed})
                world.place_on_edge(u, pu, x)
                self.assertEqual(ns["Localize"](), 1)
                ok = ns["DriveTo"](G["finish_node"])
                self.assertEqual(ok, 1, f"loc_fail={G['loc_fail']}")
                self.assertEqual(world.arrival(), (fld.F, fld.E))
                self.assertEqual((G["cur_node"], G["cur_q"]), (fld.F, fld.E))

    def test_drive_to_every_zone(self):
        for node, zone in fld.ZONES.items():
            with self.subTest(zone=zone):
                ns, G, arrays, world = load()
                world.place_on_edge(fld.X4, fld.N, 300)
                self.assertEqual(ns["Localize"](), 1)
                self.assertEqual(arrays["zone_node"][zone], node)
                ok = ns["DriveTo"](node)
                self.assertEqual(ok, 1)
                self.assertEqual(world.m, node)
                self.assertEqual(G["cur_node"], node)

    def test_relocalizes_after_wrong_belief(self):
        # Believes X3 entered from the north; really X4 entered from the north.
        ns, G, arrays, world = load()
        world.m, world.h, world.x = fld.X4, fld.S, 4
        G["cur_node"], G["cur_q"], G["cur_c"] = fld.X3, fld.N, 4
        ok = ns["DriveTo"](G["finish_node"])
        self.assertEqual(ok, 1, f"loc_fail={G['loc_fail']}")
        self.assertEqual(world.arrival(), (fld.F, fld.E))

    def test_first_leg_without_node_fails_cleanly(self):
        ns, G, arrays, world = load()
        world.place_on_edge(fld.X1, fld.N, 10)  # never a legal start
        with self.assertRaises(AssertionError):
            ns["Localize"]()


    def test_random_per_leg_noise(self):
        # Every leg gets its own odometry error up to 6%, on top of a bias.
        cases = list(start_cases())
        rng = random.Random(7)
        failures = []
        for n in range(300):
            u, pu, x = rng.choice(cases)
            args = {"dist_scale": rng.uniform(0.95, 1.05), "turn_scale": rng.uniform(0.75, 1.25),
                    "leg_jitter": 0.06, "seed": n}
            ns, G, arrays, world = load(args)
            world.place_on_edge(u, pu, x)
            ok = ns["Localize"]()
            if ok == 1:
                ok = ns["DriveTo"](G["finish_node"])
            if ok != 1 or world.arrival() != (fld.F, fld.E):
                failures.append((fld.NAMES[u], "NESW"[pu], round(x), args, G["loc_fail"]))
        self.assertEqual(failures, [])


class PlanTests(unittest.TestCase):
    def test_plan_never_uses_unsafe_or_finish_probe(self):
        ns, G, arrays, world = load()
        for m in range(fld.CROSSINGS):
            for q in range(4):
                if (m, q) not in world.edges:
                    continue
                G["cur_node"], G["cur_q"] = m, q
                ok = ns["Plan"](G["finish_node"])
                self.assertEqual(ok, 1)
                state = (m, q)
                for i in range(1, int(G["plan_n"]) + 1):
                    a = arrays["plan_a"][i]
                    pok, v, pv, *_ = ns["Predict"](*state, a)
                    self.assertEqual(pok, 1)
                    state = (v, pv)
                self.assertEqual(state[0], fld.F)


class CodeTests(unittest.TestCase):
    def decode(self, digits):
        ns, G, arrays, _ = load()
        for i, d in enumerate(digits):
            arrays["code_digit"][i] = d
        ns["DecodeCode"]()
        return G["code_ok"], G["start_mask"], G["goal_mask"]

    def test_rules_example(self):
        # Старшая_3.pdf 1.7: Y G G R | R G Y Y -> 0221 || 1120 -> 1,4,5 and 2,4,6
        self.assertEqual(self.decode([1, 2, 2, 0, 0, 2, 1, 1]), (1, 0b011001, 0b101010))

    def test_senior3_example(self):
        # senior-3.pdf: G Y Y Y | Y Y G R -> zones 1,4,6 then 2,3,5
        self.assertEqual(self.decode([2, 1, 1, 1, 1, 1, 2, 0]), (1, 0b101001, 0b010110))

    def test_invalid_codes(self):
        self.assertEqual(self.decode([0, 0, 0, 0, 1, 2, 2, 0])[0], 0)  # zero elements
        self.assertEqual(self.decode([2, 2, 2, 2, 1, 2, 2, 0])[0], 0)  # 80 > 63
        self.assertEqual(self.decode([-1, 1, 1, 1, 1, 1, 2, 0])[0], 0)


if __name__ == "__main__":
    unittest.main()
