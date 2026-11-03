"""Application state: detector config, labelled dataset, calibration flow, model and actions."""

import json
import math
import os
import random
import re
import subprocess
import threading
import time
from collections import Counter, deque
from pathlib import Path

import numpy as np

from . import features, model, sensors
from .detector import Detector

DEFAULT_CFG = {
    "k": 6.0,             # trigger at k x idle gyro noise ...
    "min_thresh": 1.0,    # ... but never below this many deg/s
    "refractory": 0.35,   # s between taps
    "gate_s": 0.3,        # ignore taps this soon after typing / clicking / scrolling
    "gating": True,
    "reject_factor": 2.0,  # reject taps this many times farther than usual from their zone
    "model_kind": "auto",
    "actions_enabled": False,
    "actions": {},        # zone label -> shell command
}


# Allowed range for each numeric setting (keeps NaN, infinities and nonsense out of the detector).
CFG_RANGES = {"k": (1.0, 50.0), "min_thresh": (0.05, 100.0), "refractory": (0.05, 5.0),
              "gate_s": (0.0, 5.0), "reject_factor": (0.1, 50.0)}
ZONE_RE = re.compile(r"z\d{1,3}")


def _number(value, lo, hi, name):
    v = float(value)
    if not math.isfinite(v) or not lo <= v <= hi:
        raise ValueError(f"{name} must be between {lo} and {hi}")
    return v


def _load_json(path):
    """Reads a JSON file; an unreadable one is moved aside instead of crashing start-up."""
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        if path.exists():
            os.replace(path, path.with_suffix(path.suffix + f".corrupt-{int(time.time())}"))
        return None


def _atomic_write(path, text):
    """Owner-only (0600): config.json holds shell commands that run on a tap, and dataset.json your taps."""
    tmp = path.with_suffix(path.suffix + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, 0o600)  # an older tmp file may still carry wider permissions
    os.replace(tmp, path)


class App:
    def __init__(self, data_dir):
        self.dir = Path(data_dir)
        if not self.dir.exists():
            self.dir.mkdir(parents=True, mode=0o700)  # never re-permission a folder the user pointed us at
        self.lock = threading.RLock()
        self.cfg = dict(DEFAULT_CFG)
        cfg_path = self.dir / "config.json"
        if cfg_path.exists() and isinstance(saved := _load_json(cfg_path), dict):
            self.cfg.update(saved)
        self.grid = {"rows": 3, "cols": 3}
        self.samples = []
        ds_path = self.dir / "dataset.json"
        ds = _load_json(ds_path) if ds_path.exists() else None
        if isinstance(ds, dict) and "grid" in ds and "samples" in ds:
            self.grid = ds["grid"]
            self.samples = ds["samples"]
            for s in self.samples:
                s["f"] = features.extract(s["g"], s["a"])
        self.next_sample_id = max((s["id"] for s in self.samples), default=0) + 1
        self.mode = "idle"
        self.calib = None
        self.neg_until = 0.0
        self.events = deque(maxlen=300)
        self.model = None
        self.report = None
        self.sensors = sensors.Sensors()
        self.detector = Detector(self.sensors, self.cfg, self.on_event)
        if len({s["label"] for s in self.samples}) >= 2:
            self.train()

    def _train_in_background(self):
        try:
            self.train()
        except ValueError:
            pass  # e.g. a 1-zone grid with no noise examples: nothing to learn yet

    def start(self):
        if sensors.listen_access() != "granted":
            sensors.request_listen_access()  # shows the Input Monitoring prompt once; the sensors need it on some Macs
        self.sensors.start()
        self.detector.start()

    # -- persistence -------------------------------------------------------------------------

    def save_cfg(self):
        _atomic_write(self.dir / "config.json", json.dumps(self.cfg, indent=1))

    def save_dataset(self):
        keep = [{k: v for k, v in s.items() if k != "f"} for s in self.samples]
        _atomic_write(self.dir / "dataset.json", json.dumps({"grid": self.grid, "samples": keep}))

    # -- events ------------------------------------------------------------------------------

    def on_event(self, ev):
        with self.lock:
            g, a = ev.pop("g"), ev.pop("a")
            ev["g"] = np.round(g, 3).tolist()
            ev["a"] = np.round(a, 4).tolist()
            ev["ratio"] = round(ev["peak_g"] / max(ev["peak_a"], 1e-4), 1)
            if ev["gated"]:
                ev["outcome"] = "gated"
            elif self.mode == "calibrate":
                label = self.calib["seq"][self.calib["pos"]]
                self._add_sample(ev, g, a, label)
                ev["outcome"], ev["label"] = "recorded", label
                self.calib["pos"] += 1
                if self.calib["pos"] >= len(self.calib["seq"]):
                    self.mode, self.calib = "idle", None
                    threading.Thread(target=self._train_in_background, daemon=True).start()
            elif self.mode == "negatives" and time.time() < self.neg_until:
                self._add_sample(ev, g, a, model.NOISE)
                ev["outcome"], ev["label"] = "recorded", model.NOISE
            elif self.mode == "negatives":
                self.mode = "idle"  # time is up even if no GUI polled status()
                ev["outcome"] = "detected"
            elif self.model:
                pred = self.model.predict(features.extract(g, a), self.cfg["reject_factor"])
                ev["pred"] = pred
                ev["outcome"] = "rejected" if pred["rejected"] else "predicted"
                if not pred["rejected"] and self.cfg["actions_enabled"]:
                    ev["action"] = self._run_action(pred["label"])
            else:
                ev["outcome"] = "detected"
            self.events.append(ev)

    def _add_sample(self, ev, g, a, label):
        s = {"id": self.next_sample_id, "label": label, "wall": ev["wall"], "lid": ev["lid"],
             "peak_g": ev["peak_g"], "peak_a": ev["peak_a"], "g": ev["g"], "a": ev["a"]}
        self.next_sample_id += 1
        s["f"] = features.extract(g, a)
        self.samples.append(s)
        ev["sample_id"] = s["id"]
        self.save_dataset()

    def _run_action(self, label):
        cmd = self.cfg["actions"].get(label, "").strip()
        i = model.zone_index(label)
        if not cmd or i is None:
            return None
        cmd = cmd.replace("{zone}", str(i + 1))
        subprocess.Popen(cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return cmd

    def events_since(self, eid):
        with self.lock:
            return [e for e in self.events if e["id"] > eid]

    # -- commands from the GUI ---------------------------------------------------------------

    def set_config(self, body):
        with self.lock:
            for key, (lo, hi) in CFG_RANGES.items():
                if key in body:
                    self.cfg[key] = _number(body[key], lo, hi, key)
            for key in ("gating", "actions_enabled"):
                if key in body:
                    self.cfg[key] = bool(body[key])
            if "actions" in body:
                if not isinstance(body["actions"], dict):
                    raise ValueError("actions must be an object")
                self.cfg["actions"] = {str(k): str(v) for k, v in body["actions"].items() if ZONE_RE.fullmatch(str(k))}
            if "model_kind" in body and (body["model_kind"] in model.KINDS or body["model_kind"] == "auto"):
                self.cfg["model_kind"] = body["model_kind"]
                self._fit_model()
            self.save_cfg()

    def calibrate_start(self, body):
        rows, cols = int(body["rows"]), int(body["cols"])
        per_zone, block = int(body["per_zone"]), max(1, int(body.get("block", 5)))
        if not (1 <= rows <= 6 and 1 <= cols <= 6 and 1 <= per_zone <= 200):
            raise ValueError("grid must be 1-6 x 1-6 and taps per zone 1-200")
        with self.lock:
            if self.grid != {"rows": rows, "cols": cols}:
                self.samples = [s for s in self.samples if s["label"] == model.NOISE]
                self.grid = {"rows": rows, "cols": cols}
                self.model, self.report = None, None
            have = Counter(s["label"] for s in self.samples)
            need = {model.zone_label(i): max(0, per_zone - have[model.zone_label(i)]) for i in range(rows * cols)}
            seq = []
            while any(need.values()):
                zones = [z for z, n in need.items() if n]
                random.shuffle(zones)
                for z in zones:
                    take = min(block, need[z])
                    seq += [z] * take
                    need[z] -= take
            if not seq:
                raise ValueError(f"every zone already has {per_zone} taps; raise taps per zone")
            self.calib = {"seq": seq, "pos": 0, "per_zone": per_zone}
            self.mode = "calibrate"
            self.save_dataset()

    def stop(self):
        with self.lock:
            self.mode, self.calib = "idle", None

    def negatives_start(self, body):
        with self.lock:
            self.mode = "negatives"
            self.neg_until = time.time() + _number(body.get("seconds", 30), 1, 600, "seconds")

    def undo(self):
        with self.lock:
            if not self.samples:
                return
            self.samples.pop()
            if self.mode == "calibrate" and self.calib["pos"] > 0:
                self.calib["pos"] -= 1
            self.save_dataset()

    def delete_label(self, label):
        with self.lock:
            self.samples = [s for s in self.samples if s["label"] != label]
            self.save_dataset()
            if len({s["label"] for s in self.samples}) < 2:
                self.model, self.report = None, None
        if self.model:
            self.train()  # don't keep acting on a model that still knows the deleted taps

    def clear(self):
        with self.lock:
            self.samples = []
            self.model, self.report = None, None
            self.mode, self.calib = "idle", None
            self.save_dataset()

    def train(self):
        with self.lock:
            samples = list(self.samples)
            rows, cols = self.grid["rows"], self.grid["cols"]
        if len({s["label"] for s in samples}) < 2:
            raise ValueError("record taps in at least two zones first")
        report = model.evaluate(samples, rows, cols)
        report["trained_at"] = time.time()
        with self.lock:
            self.report = report
            self._fit_model()
        return report

    def _fit_model(self):
        if not self.report:
            return
        kind = self.cfg["model_kind"]
        if kind == "auto" or kind not in model.KINDS:
            kind = self.report["best"]
        self.model = model.ZoneModel(kind, self.samples)
        self.report["active"] = kind

    # -- status ------------------------------------------------------------------------------

    def status(self):
        with self.lock:
            if self.mode == "negatives" and time.time() >= self.neg_until:
                self.mode = "idle"
            d = self.detector
            counts = Counter(s["label"] for s in self.samples)
            st = {
                "mode": self.mode,
                "access": sensors.listen_access(),
                "found": self.sensors.found,
                "error": self.sensors.error,
                "rates": {k: round(v) for k, v in d.rates.items()},
                "lid": self.sensors.lid_angle,
                "noise": round(float(np.sqrt(d.noise_ms or 0.0)), 3),
                "threshold": round(d.threshold, 3),
                "grid": self.grid,
                "counts": dict(counts),
                "cfg": self.cfg,
                "model": None,
            }
            if self.model and self.report:
                acc = next((r["acc"]["Full grid"] for r in self.report["models"] if r["kind"] == self.model.kind), None)
                st["model"] = {"kind": self.model.kind, "name": model.KINDS[self.model.kind][0], "acc": acc,
                               "trained_at": self.report["trained_at"]}
            if self.calib:
                c = self.calib
                st["calib"] = {"target": c["seq"][c["pos"]], "pos": c["pos"], "total": len(c["seq"]),
                               "per_zone": c["per_zone"],
                               "left_in_block": next((i for i, z in enumerate(c["seq"][c["pos"]:])
                                                      if z != c["seq"][c["pos"]]), len(c["seq"]) - c["pos"])}
            if self.mode == "negatives":
                st["neg_left"] = round(self.neg_until - time.time(), 1)
            return st
