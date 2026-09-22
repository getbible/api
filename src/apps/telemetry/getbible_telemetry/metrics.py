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


def _host_cpu(path: Path) -> dict[str, int]:
    for line in _read(path).splitlines():
        parts = line.split()
        if not parts or parts[0] != "cpu":
            continue
        try:
            # Guest and guest_nice are already included in user and nice.
            ticks = [int(value) for value in parts[1:9]]
        except ValueError:
            return {}
        if len(ticks) < 4 or any(value < 0 for value in ticks):
            return {}
        total = sum(ticks)
        idle = ticks[3] + (ticks[4] if len(ticks) > 4 else 0)
        return {"total_ticks": total, "busy_ticks": total - idle}
    return {}


class MetricsSampler:
    def __init__(self, *, cgroup_root: str = "/sys/fs/cgroup", proc_root: str = "/proc",
                 thermal_root: str = "/sys/class/thermal", disks: list[str] | None = None) -> None:
        self.cgroup = Path(cgroup_root)
        self.proc = Path(proc_root)
        self.thermal = Path(thermal_root)
        self.disks = disks or ["/"]
        self.previous: tuple[str, float, dict[str, int]] | None = None

    def sample(self) -> dict[str, Any]:
        now = time.monotonic()
        cpu = _pairs(self.cgroup / "cpu.stat")
        memory = _integer(self.cgroup / "memory.current")
        # A native cgroup-v2 root can expose pressure files without aggregate
        # accounting. Never combine its partial counters with host utilization.
        scoped = cpu.get("usage_usec", -1) >= 0 and memory is not None and memory >= 0
        scope = "cgroup" if scoped else "host"
        if not scoped:
            cpu = _host_cpu(self.proc / "stat")
        quota = _read(self.cgroup / "cpu.max").split() if scoped else []
        cpu_capacity = float(os.cpu_count() or 1)
        if len(quota) == 2 and quota[0] != "max":
            try:
                allowance = int(quota[0]) / int(quota[1])
                if allowance > 0:
                    cpu_capacity = min(cpu_capacity, allowance)
            except (ValueError, ZeroDivisionError):
                pass
        cpu_fraction = None
        cpu_units = None
        throttled_fraction = None
        if self.previous is not None and scope == self.previous[0] and now > self.previous[1] and cpu:
            elapsed = now - self.previous[1]
            old = self.previous[2]
            if scoped and "usage_usec" in old:
                usage = cpu["usage_usec"] - old["usage_usec"]
                if usage >= 0:
                    cpu_units = usage / (elapsed * 1_000_000)
                    cpu_fraction = cpu_units / cpu_capacity
                    if all(key in cpu and key in old for key in ("nr_periods", "nr_throttled")):
                        periods = cpu["nr_periods"] - old["nr_periods"]
                        throttled = cpu["nr_throttled"] - old["nr_throttled"]
                        if periods >= 0 and throttled >= 0:
                            throttled_fraction = throttled / periods if periods else 0
            elif not scoped and "total_ticks" in old:
                total = cpu["total_ticks"] - old["total_ticks"]
                busy = cpu["busy_ticks"] - old["busy_ticks"]
                if total > 0 and 0 <= busy <= total:
                    cpu_fraction = busy / total
                    cpu_units = cpu_fraction * cpu_capacity
        self.previous = scope, now, cpu
        memory_limit = _integer(self.cgroup / "memory.max") if scoped else None
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
        if not scoped:
            total = host_memory.get("MemTotal")
            available = host_memory.get("MemAvailable")
            memory = total - available if total is not None and available is not None and 0 <= available <= total else None
        swap = _integer(self.cgroup / "memory.swap.current") if scoped else None
        if not scoped and "SwapTotal" in host_memory and "SwapFree" in host_memory:
            swap = max(0, host_memory["SwapTotal"] - host_memory["SwapFree"])
        pressure = {}
        for resource in ("cpu", "memory", "io"):
            groups = {}
            pressure_path = self.cgroup / f"{resource}.pressure" if scoped else self.proc / "pressure" / resource
            for line in _read(pressure_path).splitlines():
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
            "scope": scope, "cgroup_root": str(self.cgroup) if scoped else None,
            "cpu": {"capacity": cpu_capacity, "used_units": cpu_units,
                    "used_fraction": cpu_fraction, "throttled_fraction": throttled_fraction,
                    "counters": cpu, "available": bool(cpu)},
            "memory": {"current_bytes": memory, "limit_bytes": memory_limit,
                       "measurement": "cgroup_memory_current" if scoped else "host_memtotal_minus_memavailable",
                       "used_fraction": memory / memory_limit if memory is not None and memory_limit else None,
                       "host_available_bytes": host_memory.get("MemAvailable"),
                       "host_total_bytes": host_memory.get("MemTotal"),
                       "swap_bytes": swap,
                       "events": _pairs(self.cgroup / "memory.events") if scoped else {},
                       "stat": _pairs(self.cgroup / "memory.stat") if scoped else {}},
            "pressure": pressure, "disks": disks, "temperatures": temperatures or None,
            "temperature_available": bool(temperatures),
            "pids": {"current": _integer(self.cgroup / "pids.current") if scoped else None,
                     "limit": _integer(self.cgroup / "pids.max") if scoped else None},
        }
