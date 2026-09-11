"""Low-cost Linux counters; unavailable sensors are explicit, never invented."""

from __future__ import annotations

import os
import shutil
import time
from pathlib import Path
from typing import Any


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="ascii").strip()
    except (OSError, UnicodeError):
        return ""


def _pairs(path: Path) -> dict[str, int]:
    result = {}
    for line in _read(path).splitlines():
        parts = line.split()
        if len(parts) == 2:
            try:
                result[parts[0].rstrip(":")] = int(parts[1])
            except ValueError:
                pass
    return result


def _integer(path: Path) -> int | None:
    try:
        return int(_read(path))
    except ValueError:
        return None


class MetricsSampler:
    def __init__(self, *, cgroup_root: str = "/sys/fs/cgroup", proc_root: str = "/proc",
                 thermal_root: str = "/sys/class/thermal", disks: list[str] | None = None) -> None:
        self.cgroup = Path(cgroup_root)
        self.proc = Path(proc_root)
        self.thermal = Path(thermal_root)
        self.disks = disks or ["/"]
        self.previous: tuple[float, dict[str, int]] | None = None

    def sample(self) -> dict[str, Any]:
        now = time.monotonic()
        cpu = _pairs(self.cgroup / "cpu.stat")
        quota = _read(self.cgroup / "cpu.max").split()
        cpu_capacity = float(os.cpu_count() or 1)
        if len(quota) == 2 and quota[0] != "max":
            try:
                cpu_capacity = min(cpu_capacity, int(quota[0]) / int(quota[1]))
            except (ValueError, ZeroDivisionError):
                pass
        cpu_fraction = None
        cpu_units = None
        throttled_fraction = None
        if self.previous is not None and now > self.previous[0] and cpu:
            elapsed = now - self.previous[0]
            old = self.previous[1]
            cpu_units = max(0, cpu.get("usage_usec", 0) - old.get("usage_usec", 0)) / (elapsed * 1_000_000)
            cpu_fraction = cpu_units / max(0.001, cpu_capacity)
            periods = cpu.get("nr_periods", 0) - old.get("nr_periods", 0)
            throttled = cpu.get("nr_throttled", 0) - old.get("nr_throttled", 0)
            throttled_fraction = max(0, throttled / periods) if periods > 0 else 0
        self.previous = now, cpu
        memory = _integer(self.cgroup / "memory.current")
        memory_limit = _integer(self.cgroup / "memory.max")
        host_memory = {}
        for line in _read(self.proc / "meminfo").splitlines():
            parts = line.split()
            if len(parts) >= 2:
                try:
                    host_memory[parts[0].rstrip(":")] = int(parts[1]) * 1024
                except ValueError:
                    pass
        if memory_limit is None:
            memory_limit = host_memory.get("MemTotal")
        pressure = {}
        for resource in ("cpu", "memory", "io"):
            groups = {}
            for line in _read(self.cgroup / f"{resource}.pressure").splitlines():
                parts = line.split()
                try:
                    groups[parts[0]] = {key: float(value) for key, value in (part.split("=", 1) for part in parts[1:])}
                except (ValueError, IndexError):
                    continue
            pressure[resource] = groups or None
        temperatures = []
        for path in sorted(self.thermal.glob("thermal_zone*/temp")):
            value = _integer(path)
            if value is not None and -40_000 <= value <= 200_000:
                temperatures.append({"sensor": _read(path.parent / "type") or path.parent.name,
                                     "celsius": value / 1000})
        disks = []
        seen = set()
        for name in self.disks:
            try:
                device = os.stat(name).st_dev
                if device in seen:
                    continue
                seen.add(device)
                usage = shutil.disk_usage(name)
                disks.append({"path": name, "total_bytes": usage.total, "used_bytes": usage.used,
                              "free_bytes": usage.free, "used_fraction": usage.used / usage.total if usage.total else None})
            except OSError:
                pass
        return {
            "scope": "cgroup", "cgroup_root": str(self.cgroup),
            "cpu": {"capacity": cpu_capacity, "used_units": cpu_units,
                    "used_fraction": cpu_fraction, "throttled_fraction": throttled_fraction,
                    "counters": cpu, "available": bool(cpu)},
            "memory": {"current_bytes": memory, "limit_bytes": memory_limit,
                       "used_fraction": memory / memory_limit if memory is not None and memory_limit else None,
                       "swap_bytes": _integer(self.cgroup / "memory.swap.current"),
                       "events": _pairs(self.cgroup / "memory.events"),
                       "stat": _pairs(self.cgroup / "memory.stat")},
            "pressure": pressure, "disks": disks, "temperatures": temperatures or None,
            "temperature_available": bool(temperatures),
            "pids": {"current": _integer(self.cgroup / "pids.current"),
                     "limit": _integer(self.cgroup / "pids.max")},
        }
