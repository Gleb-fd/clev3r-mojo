"""Source-driven tests, not a Basic Plus compiler or a full BP interpreter.

The adapter accepts only the statements used by the three sections under test:
numeric assignments/expressions, indexed arrays, If/Else, While/Break, inclusive
For loops, Return, and a whitelist of calls with trailing out arguments. Hardware
and GuardMove are explicit test doubles. BP compilation and physical sensor,
encoder, braking, and timing validation remain separate jobs for the main agent.
"""
import math
import re
import unittest
from collections import defaultdict
from pathlib import Path
from types import SimpleNamespace
from typing import Any


ROOT = Path(__file__).resolve().parent
BARCODE = (ROOT / "s1bar.bpi").read_text()
WEIGHTS = (ROOT / "s1weights.bpi").read_text()
MISSION = (ROOT / "senior1.bp").read_text()

# Independent transcription of the user's Cyrillic edge fixture, not BP arrays.
EDGES = [
    ("А1", "Б1", 43), ("А1", "А2", 17), ("Б1", "В1", 26),
    ("Б1", "Б2", 27), ("В1", "Г1", 37), ("В1", "В2", 22),
    ("Г1", "Д1", 22), ("Г1", "Г2", 40), ("Д1", "Е1", 24),
    ("Д1", "Д2", 37), ("Е1", "Ж1", 37), ("Е1", "Е2", 24),
    ("Ж1", "Ж2", 14), ("А2", "Б2", 11), ("А2", "А3", 14),
    ("Б2", "В2", 19), ("Б2", "Б3", 37), ("В2", "Г2", 40),
    ("В2", "В3", 29), ("Г2", "Д2", 27), ("Г2", "Г3", 43),
    ("Д2", "Е2", 29), ("Д2", "Д3", 15), ("Е2", "Ж2", 42),
    ("Е2", "Е3", 36), ("Ж2", "Ж3", 44), ("А3", "Б3", 36),
    ("А3", "А4", 29), ("Б3", "В3", 33), ("Б3", "Б4", 40),
    ("В3", "Г3", 19), ("В3", "В4", 20), ("Г3", "Д3", 34),
    ("Г3", "Г4", 16), ("Д3", "Е3", 41), ("Д3", "Д4", 42),
    ("Е3", "Ж3", 40), ("Е3", "Е4", 48), ("Ж3", "Ж4", 26),
    ("А4", "Б4", 42), ("А4", "А5", 43), ("Б4", "В4", 49),
    ("Б4", "Б5", 45), ("В4", "Г4", 30), ("В4", "В5", 36),
    ("Г4", "Д4", 10), ("Г4", "Г5", 34), ("Д4", "Е4", 27),
    ("Д4", "Д5", 37), ("Е4", "Ж4", 27), ("Е4", "Е5", 40),
    ("Ж4", "Ж5", 25), ("А5", "Б5", 19), ("Б5", "В5", 24),
    ("В5", "Г5", 14), ("Г5", "Д5", 22), ("Д5", "Е5", 42),
    ("Е5", "Ж5", 39),
]


def coordinate(label):
    return "АБВГДЕЖ".index(label[0]) + 1, int(label[1])


def expr(text):
    """Translate this fixture's numeric expressions; never translate strings."""
    parts = re.split(r'("[^"\n]*")', text)
    for i in range(0, len(parts), 2):
        part = re.sub(r"@(\w+)", r"g.\1", parts[i])
        part = part.replace("<>", "!=")
        part = re.sub(r"(?<![<>=!])=(?!=)", "==", part)
        part = re.sub(r"\bAnd\b", "and", part)
        part = re.sub(r"\bOr\b", "or", part)
        parts[i] = part
    return "".join(parts)


# Call arity and out count are deliberately explicit, not inferred BP semantics.
OUT_CALLS = {"GuardMove": (4, 2), "map_data": (2, 1),
             "DecodeBarcode": (2, 1), "RoadWeight": (5, 1), "Clamp": (4, 1)}
VOID_CALLS = {"Motor.ResetCount", "MotorB.SetSpeed", "MotorC.SetSpeed",
              "MotorBC.Start", "Motor.Stop", "Program.Delay", "FailStop", "LCD.Text"}


def compile_body(name, body, inputs, outputs, namespace, arrays=(), snapshot=False):
    """Generate Python directly from actual BP lines, failing on unknown syntax."""
    lines = [f"def {name}({', '.join(inputs)}):"]
    indent = 1
    stack = []
    result = "locals()" if snapshot else (", ".join(outputs) or "None")
    for array in arrays:
        lines.append(f"    {array} = defaultdict(int)")
    for raw in body.splitlines():
        text = raw.split("'", 1)[0].strip()
        if not text:
            continue
        if text in ("EndIf", "EndWhile", "EndFor"):
            expected = {"EndIf": "if", "EndWhile": "while", "EndFor": "for"}[text]
            if not stack or stack.pop() != expected:
                raise ValueError(f"Unbalanced BP block: {text}")
            indent -= 1
            continue
        if text == "Else":
            if not stack or stack[-1] != "if":
                raise ValueError("Else outside If")
            lines.append("    " * (indent - 1) + "else:")
            continue
        if text.startswith("If ") and text.endswith(" Then"):
            statement = "if " + expr(text[3:-5]) + ":"
            block = "if"
        elif text.startswith("While "):
            statement = "while " + expr(text[6:]) + ":"
            block = "while"
        elif text.startswith("For "):
            match = re.fullmatch(r"For (\w+) = (.+) To (.+)", text)
            if not match:
                raise ValueError(text)
            var, first, last = match.groups()
            statement = f"for {var} in range({expr(first)}, {expr(last)} + 1):"
            block = "for"
        else:
            block = None
            if text == "Return":
                statement = "return " + result
            elif text == "Break":
                statement = "break"
            elif re.match(r"(?:@?\w+)(?:\[.*\])? = ", text):
                lhs, rhs = text.split(" = ", 1)
                statement = expr(lhs) + " = " + expr(rhs)
            else:
                call = re.fullmatch(r"([\w.]+)\((.*)\)", text)
                if not call:
                    raise ValueError(f"Unsupported BP statement: {text}")
                callee, argtext = call.groups()
                args = [a.strip() for a in argtext.split(",")] if argtext else []
                if callee in OUT_CALLS:
                    arity, count = OUT_CALLS[callee]
                    if len(args) != arity:
                        raise ValueError(text)
                    statement = (", ".join(map(expr, args[-count:])) + " = "
                                 + callee + "(" + ", ".join(map(expr, args[:-count])) + ")")
                elif callee in VOID_CALLS:
                    statement = expr(text)
                else:
                    raise ValueError(f"Unsupported BP call: {callee}")
        lines.append("    " * indent + statement)
        if block:
            stack.append(block)
            indent += 1
    if stack:
        raise ValueError("Unclosed BP block")
    lines.append("    return " + result)
    generated = "\n".join(lines)
    # Only trusted local BP source is executed; this is a test translator, not a sandbox.
    exec(compile(generated, f"<BP subset: {name}>", "exec"), namespace)  # noqa: S102
    return namespace[name]


def load_functions(source, namespace):
    for match in re.finditer(r"^Function (\w+)\((.*?)\)\n(.*?)^EndFunction\s*$",
                             source, re.M | re.S):
        name, params, body = match.groups()
        inputs, outputs = [], []
        for param in params.split(",") if params else []:
            spec = re.fullmatch(r"\s*(in|out) number (\w+)\s*", param)
            if not spec:
                raise ValueError(param)
            (inputs if spec[1] == "in" else outputs).append(spec[2])
        compile_body(name, body, inputs, outputs, namespace)


class Hardware:
    """Continuous encoder position; reflectance depends on position, not time."""
    def __init__(self, cells=None, width=60, steps=(1,), light_jitter=(0,),
                 widths=None, delay_scale=1, start_dark=0, origin=20):
        self.cells = cells
        self.widths = widths or [width] * len(cells or [])
        self.steps = steps
        self.light_jitter = light_jitter
        self.delay_scale = delay_scale
        self.position = 0
        self.Time = 0
        self.ticks = 0
        self.running = False
        self.starts = 0
        self.stops = 0
        self.speeds = []
        self.origin = origin
        self.start_dark = start_dark

    def ResetCount(self, ports):
        assert ports == "BC"
        self.position = 0

    def SetSpeed(self, speed):
        self.speeds.append(speed)

    def Start(self):
        self.running = True
        self.starts += 1

    def Stop(self, ports, brake):
        assert (ports, brake) == ("BC", "true")
        self.running = False
        self.stops += 1

    def GetCount(self, port):
        assert port in "BC"
        return self.position if port == "B" else -self.position

    def Delay(self, ms):
        self.Time += ms * self.delay_scale
        if self.running:
            self.position += self.steps[self.ticks % len(self.steps)]
        self.ticks += 1
        if self.ticks > 100000:
            raise AssertionError("Simulated iteration budget exhausted")

    def map_data(self, port):
        assert port == 2
        position = self.position - self.origin
        black = int(self.position < self.start_dark)
        if position >= 0:
            for cell, width in zip(self.cells or [], self.widths, strict=True):
                if position < width:
                    black = cell
                    break
                position -= width
        return (15 if black else 45) + self.light_jitter[self.ticks % len(self.light_jitter)]


def environment(hw=None, **overrides):
    hw = hw or Hardware()
    g = SimpleNamespace(gx=7, gy=5, sx=1, sy=3, read_max_deg=1400,
                        read_speed=13, stripe_min=35, calibrated=1,
                        motion_status=0, barcode_travel=0,
                        east=defaultdict(int), south=defaultdict(int))
    vars(g).update(overrides)

    def guard(distance, speed):
        # Stub contract only: the real motion library is deliberately not loaded.
        if distance <= 0 or speed <= 0:
            g.motion_status = 4
            return 0, 0
        return 1, min(speed, 100)

    ns: dict[str, Any] = {
        "g": g, "defaultdict": defaultdict,
        "Math": SimpleNamespace(Abs=abs, Floor=math.floor, Min=min),
        "Motor": hw, "MotorB": hw, "MotorC": hw, "MotorBC": hw, "EV3": hw,
        "Program": hw, "GuardMove": guard, "map_data": hw.map_data,
        "FailStop": lambda stage: hw.Stop("BC", "true"),
    }
    load_functions(BARCODE, ns)
    load_functions(WEIGHTS, ns)
    return ns, g, hw


def barcode_cells(code):
    return [1, 0, 1] + [(code >> bit) & 1 for bit in range(7)]


class BarcodeTests(unittest.TestCase):
    def read_barcode(self, cells, expected, status, hw_options=None, **settings):
        hw = Hardware(cells, **(hw_options or {}))
        ns, g, hw = environment(hw, **settings)
        self.assertEqual(ns["ReadBarcode"](), expected)
        self.assertEqual(g.motion_status, status)
        if expected >= 0:
            self.assertEqual(g.barcode_reason, 0)
        self.assertFalse(hw.running)
        self.assertEqual(hw.stops, hw.starts + 1)  # entry safety stop, then final stop
        if hw.starts:
            self.assertEqual(hw.stops, 2)
            self.assertEqual(g.barcode_travel, hw.position)
        return g, hw

    def test_all_35_coordinates_widths_jitter_and_nonuniform_speed(self):
        for x in range(1, 8):
            for y in range(1, 6):
                for width in (40, 60, 100):
                    with self.subTest(code=10*x+y, width=width):
                        g, hw = self.read_barcode(
                            barcode_cells(10*x+y), 10*x+y, 1,
                            {"width": width, "steps": (0.5, 2, 1, 1.5, 0.75),
                                 "light_jitter": (-8, 0, 8)})
                        self.assertLessEqual(abs(g.barcode_travel - (20 + 10*width)), 8)
                        self.assertEqual(hw.speeds, [13, 13])

    def test_dark_start_zone_before_white_gap_and_barcode(self):
        # Green may be classified as black. It is not the first header stripe.
        for x in range(1, 8):
            for y in range(1, 6):
                code = 10*x+y
                with self.subTest(code=code):
                    self.read_barcode(barcode_cells(code), code, 1,
                                      {"start_dark": 90, "origin": 260})

    def test_pdf_61_merged_runs_lsb_first(self):
        # 61 = 0b0111101; data left-to-right is 1011110, not MSB-first.
        cells = [1, 0, 1, 1, 0, 1, 1, 1, 1, 0]
        self.assertEqual(cells, barcode_cells(61))
        g, _ = self.read_barcode(cells, 61, 1)
        self.assertGreaterEqual(g.barcode_travel, 620)  # includes final white cell

    def test_invalid_coordinates_and_decode_domain(self):
        for code in (0, 10, 16, 26, 70, 76, 81, 99, 127):
            with self.subTest(code=code):
                self.read_barcode(barcode_cells(code), -1, 2)
        ns, _, _ = environment()
        for code in (-1, 128, 11.5):
            self.assertEqual(ns["DecodeBarcode"](code), -1)

    def test_invalid_header(self):
        self.read_barcode([1, 0, 0, 1, 0, 1, 0, 1, 0, 1], -1, 2)

    def test_no_marker_and_travel_limit(self):
        self.read_barcode(None, -1, 2, read_max_deg=300)
        self.read_barcode(barcode_cells(61), -1, 2, read_max_deg=400)

    def test_timeout_with_stalled_encoders(self):
        g, hw = self.read_barcode(barcode_cells(61), -1, 3,
                                 {"steps": (0,), "delay_scale": 100})
        self.assertEqual(g.barcode_travel, 0)
        self.assertGreaterEqual(hw.Time, 1400*300/13 + 5000)

    def test_calibration_rejection(self):
        for widths in ([20]*10, [60, 90]+[60]*8, [60, 20]+[60]*8):
            with self.subTest(widths=widths):
                self.read_barcode(barcode_cells(61), -1, 2, {"widths": widths})
        self.read_barcode(barcode_cells(61), -1, 5, calibrated=0)
        self.read_barcode(barcode_cells(61), -1, 4, stripe_min=0)

    def test_early_rejections_stop_initially_moving_motors(self):
        for settings, status in (({"calibrated": 0}, 5), ({"stripe_min": 0}, 4),
                                 ({"read_speed": 0}, 4), ({"read_max_deg": 0}, 4)):
            with self.subTest(settings=settings):
                hw = Hardware(barcode_cells(61))
                hw.running = True  # entered while motors were already moving
                ns, g, _ = environment(hw, **settings)
                self.assertEqual(ns["ReadBarcode"](), -1)
                self.assertEqual(g.motion_status, status)
                self.assertFalse(hw.running)
                self.assertEqual(hw.starts, 0)
                self.assertEqual(hw.stops, 1)
                self.assertEqual(hw.position, 0)
                self.assertEqual(hw.Time, 0)

    def test_zero_speed_and_invalid_guard_distance_never_start(self):
        for settings in ({"read_speed": 0}, {"read_max_deg": 0}):
            with self.subTest(settings=settings):
                _, hw = self.read_barcode(barcode_cells(61), -1, 4, **settings)
                self.assertEqual(hw.starts, 0)
                self.assertEqual(hw.speeds, [])

    def test_oversized_encoder_step_rejected(self):
        self.read_barcode(barcode_cells(61), -1, 2,
                          {"width": 60, "steps": (45,)})

    def test_diagnostic_reasons(self):
        cases = [
            (1, barcode_cells(61), {"width": 20}, {}, 2),
            (2, barcode_cells(61), {"widths": [60, 90] + [60]*8}, {}, 2),
            (3, [1, 0, 1, 0, 1, 0, 0, 1, 1, 0],
             {"widths": [60, 60, 10, 110] + [60]*6}, {}, 2),
            (4, barcode_cells(61), {"steps": (1,)*220 + (100,)}, {}, 2),
            (5, barcode_cells(16), {}, {}, 2),
            (6, None, {}, {"read_max_deg": 300}, 2),
            (7, None, {"steps": (0,), "delay_scale": 100}, {}, 3),
            (8, None, {}, {"read_speed": 0}, 4),
            (9, None, {}, {"calibrated": 0}, 5),
        ]
        for reason, cells, hardware, settings, status in cases:
            with self.subTest(reason=reason):
                g, _ = self.read_barcode(cells, -1, status, hardware, **settings)
                self.assertEqual(g.barcode_reason, reason)

    def test_diagnostic_display_values(self):
        ns, g, _ = environment()
        g.barcode_reason = 2
        g.barcode_black_width = 90
        g.barcode_white_width = 170
        calls = []
        ns["LCD"] = SimpleNamespace(Text=lambda *args: calls.append(args))
        ns["ShowBarcodeDetails"]()
        self.assertEqual([args[-1] for args in calls],
                         ["bar err:", 2, "B deg:", 90, "W deg:", 170])


class UTurnTraceTests(unittest.TestCase):
    def test_records_line_detection_without_forward_motion(self):
        nav = (ROOT / "s1nav.bpi").read_text()
        lib = (ROOT / "lib.bpi").read_text()
        hw = Hardware()
        ns, g, _ = environment(hw)
        ns["Math"].Max = max
        # Only the turning sensor's reflectance is simulated in this test.
        ns["map_data"] = lambda port: 15 if hw.position >= 450 else 90
        clamp = re.search(r"^Function Clamp\(.*?\)\n(.*?)^EndFunction", lib, re.M | re.S)
        turn = re.search(r"^Function UTurn\(.*?\)\n(.*?)^EndFunction", nav, re.M | re.S)
        assert clamp is not None, "Clamp function missing from lib.bpi"
        assert turn is not None, "UTurn function missing from s1nav.bpi"
        compile_body("Clamp", clamp[1], ("value", "low", "high"), ("result",), ns)
        run = compile_body("UTurn", turn[1], ("speed", "max_turn"), (), ns)
        run(30, 600)
        self.assertEqual(g.motion_status, 1)
        self.assertEqual(g.uturn_degrees, 452)
        self.assertEqual(g.uturn_light, 15)
        self.assertFalse(hw.running)
        self.assertEqual(hw.speeds, [30, -30])
        self.assertEqual(hw.starts, 1)
        # The trace measures detection, not physical correctness of the heading.
        run(0, 600)
        self.assertEqual(g.motion_status, 4)
        self.assertEqual(g.uturn_degrees, 0)
        self.assertEqual(g.uturn_light, -1)


class RoadTests(unittest.TestCase):
    def test_all_58_edges_both_directions(self):
        ns, _, _ = environment()
        ns["InitRoadWeights"]()
        self.assertEqual(len(EDGES), 58)
        seen = set()
        for a, b, weight in EDGES:
            p, q = coordinate(a), coordinate(b)
            self.assertNotIn(frozenset((p, q)), seen)
            seen.add(frozenset((p, q)))
            for start, end in ((p, q), (q, p)):
                with self.subTest(start=start, end=end):
                    self.assertEqual(ns["RoadWeight"](*start, *end), weight)

    def test_actual_dijkstra_and_route_reversal_all_destinations(self):
        # This contiguous source slice includes both route-building loops and
        # the start-coordinate check, stopping before any physical DrivePath.
        run = MISSION.split("Function RunMission(out number failed)", 1)[1]
        section = run[run.index("  For i = 0 To 34"):run.index("  DrivePath(fpx")]
        ns, _, _ = environment()
        ns["InitRoadWeights"]()
        plan = compile_body("plan", section, ("tx", "ty"), (), ns,
                            arrays=("dist", "done", "prev", "rpx", "rpy", "fpx", "fpy"),
                            snapshot=True)
        nodes = [coordinate(letter + str(y)) for letter in "АБВГДЕЖ" for y in range(1, 6)]
        distances = {(a, b): (0 if a == b else math.inf) for a in nodes for b in nodes}
        weights = {}
        for a, b, w in EDGES:
            p, q = coordinate(a), coordinate(b)
            distances[p, q] = distances[q, p] = w
            weights[p, q] = weights[q, p] = w
        # Independent all-pairs Floyd-Warshall, not another Dijkstra.
        for k in nodes:
            for a in nodes:
                for b in nodes:
                    distances[a, b] = min(distances[a, b], distances[a, k] + distances[k, b])
        for target in nodes:
            with self.subTest(target=target):
                result = plan(*target)
                self.assertNotIn("failed", result)
                for index, node in enumerate(nodes):
                    self.assertEqual(result["dist"][index], distances[(1, 3), node])
                n = result["pln"]
                self.assertTrue(1 <= n <= 35)
                forward = [(result["fpx"][i], result["fpy"][i]) for i in range(1, n+1)]
                reverse = [(result["rpx"][i], result["rpy"][i]) for i in range(1, n+1)]
                self.assertEqual(forward[0], (1, 3))
                self.assertEqual(forward[-1], target)
                self.assertEqual(reverse, forward[::-1])
                self.assertEqual(len(set(forward)), n)
                for route in (forward, reverse):
                    cost = 0
                    for a, b in zip(route, route[1:], strict=False):
                        self.assertIn((a, b), weights)
                        cost += weights[a, b]
                    self.assertEqual(cost, distances[(1, 3), target])


if __name__ == "__main__":
    unittest.main()
