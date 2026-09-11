"""Consistent host/container telemetry from synthetic kernel counters."""

from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from getbible_telemetry.metrics import MetricsSampler


class MetricsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cgroup = self.root / "cgroup"
        self.proc = self.root / "proc"
        self.cgroup.mkdir()
        self.proc.mkdir()
        self.sampler = MetricsSampler(cgroup_root=str(self.cgroup), proc_root=str(self.proc),
                                      thermal_root=str(self.root / "thermal"), disks=[str(self.root)])
        self.clock = 100.0
        self.cpu_count = patch("getbible_telemetry.metrics.os.cpu_count", return_value=4)
        self.cpu_count.start()
        self.addCleanup(self.cpu_count.stop)

    def sample(self):
        self.clock += 2
        with patch("getbible_telemetry.metrics.time.monotonic", return_value=self.clock):
            return self.sampler.sample()

    def host(self):
        (self.proc / "meminfo").write_text("MemTotal: 8192 kB\nMemAvailable: 6144 kB\n"
                                            "SwapTotal: 1024 kB\nSwapFree: 768 kB\n")
        (self.proc / "stat").write_text("cpu 100 50 50 800 0 0 0 0 20 10\ncpu0 1 2 3 4\n")
        (self.proc / "pressure").mkdir(exist_ok=True)
        (self.proc / "pressure" / "cpu").write_text("some avg10=1.5 avg60=0.5 avg300=0.1 total=500\n")

    def container(self, usage=1_000_000, periods=20, throttled=2):
        (self.cgroup / "cpu.stat").write_text(f"usage_usec {usage}\nnr_periods {periods}\nnr_throttled {throttled}\n")
        (self.cgroup / "cpu.max").write_text("200000 100000\n")
        (self.cgroup / "memory.current").write_text("1048576\n")
        (self.cgroup / "memory.max").write_text("8388608\n")
        (self.cgroup / "memory.swap.current").write_text("4096\n")
        (self.cgroup / "memory.events").write_text("oom 1\n")
        (self.cgroup / "cpu.pressure").write_text("some avg10=2.5 avg60=1 avg300=0.5 total=1000\n")

    def test_native_accounting_excludes_duplicate_guest_time(self):
        self.host()
        first = self.sample()
        self.assertEqual(first["scope"], "host")
        self.assertIsNone(first["cpu"]["used_fraction"])
        self.assertIsNone(first["cgroup_root"])
        self.assertEqual(first["memory"]["current_bytes"], 2048 * 1024)
        self.assertEqual(first["memory"]["measurement"], "host_memtotal_minus_memavailable")
        self.assertEqual(first["memory"]["swap_bytes"], 256 * 1024)
        self.assertEqual(first["pressure"]["cpu"]["some"]["avg10"], 1.5)
        (self.proc / "stat").write_text("cpu 150 75 75 900 0 0 0 0 60 30\n")
        second = self.sample()
        self.assertTrue(second["cpu"]["available"])
        self.assertEqual(second["cpu"]["used_fraction"], 0.5)
        self.assertEqual(second["cpu"]["used_units"], 2)
        self.assertIsNone(second["cpu"]["throttled_fraction"])

    def test_partial_cgroup_accounting_uses_host_for_all_resources(self):
        self.host()
        self.container()
        for missing in ("cpu.stat", "memory.current"):
            with self.subTest(missing=missing):
                self.container()
                (self.cgroup / missing).unlink()
                sample = self.sample()
                self.assertEqual(sample["scope"], "host")
                self.assertEqual(sample["cpu"]["capacity"], 4)
                self.assertEqual(sample["memory"]["current_bytes"], 2048 * 1024)
                self.assertEqual(sample["memory"]["limit_bytes"], 8192 * 1024)
                self.assertEqual(sample["memory"]["events"], {})
                self.assertEqual(sample["pressure"]["cpu"]["some"]["avg10"], 1.5)

    def test_container_preserves_quota_and_throttling_counters(self):
        self.container()
        first = self.sample()
        self.assertEqual(first["scope"], "cgroup")
        self.assertIsNone(first["cpu"]["used_units"])
        self.assertEqual(first["cpu"]["capacity"], 2)
        self.assertEqual(first["memory"]["current_bytes"], 1048576)
        self.assertEqual(first["memory"]["measurement"], "cgroup_memory_current")
        self.assertEqual(first["memory"]["events"], {"oom": 1})
        self.assertEqual(first["pressure"]["cpu"]["some"]["avg10"], 2.5)
        self.container(3_000_000, 30, 4)
        second = self.sample()
        self.assertEqual(second["cpu"]["used_units"], 1)
        self.assertEqual(second["cpu"]["used_fraction"], 0.5)
        self.assertEqual(second["cpu"]["throttled_fraction"], 0.2)

    def test_scope_transitions_require_a_new_interval(self):
        self.host()
        self.sample()
        self.container()
        self.assertIsNone(self.sample()["cpu"]["used_fraction"])
        self.container(3_000_000)
        self.assertIsNotNone(self.sample()["cpu"]["used_fraction"])
        (self.cgroup / "memory.current").unlink()
        self.assertIsNone(self.sample()["cpu"]["used_fraction"])
        (self.proc / "stat").write_text("cpu 150 75 75 900 0 0 0 0\n")
        self.assertEqual(self.sample()["cpu"]["used_fraction"], 0.5)

    def test_counter_resets_are_not_reported_as_zero_utilization(self):
        self.container(3_000_000)
        self.sample()
        self.container(1_000_000)
        self.assertIsNone(self.sample()["cpu"]["used_fraction"])
        self.container(2_000_000)
        self.assertIsNotNone(self.sample()["cpu"]["used_fraction"])
        (self.cgroup / "memory.current").unlink()
        self.host()
        self.sample()
        (self.proc / "stat").write_text("cpu 10 5 5 80 0 0 0 0\n")
        self.assertIsNone(self.sample()["cpu"]["used_fraction"])

    def test_missing_or_invalid_host_counters_remain_unavailable(self):
        first = self.sample()
        self.assertFalse(first["cpu"]["available"])
        self.assertIsNone(first["memory"]["current_bytes"])
        self.host()
        (self.proc / "stat").write_text("cpu invalid counters\n")
        (self.proc / "meminfo").write_text("MemTotal: 8192 kB\n")
        sample = self.sample()
        self.assertFalse(sample["cpu"]["available"])
        self.assertIsNone(sample["cpu"]["used_fraction"])
        self.assertIsNone(sample["memory"]["current_bytes"])

    def test_unlimited_container_memory_uses_host_capacity(self):
        self.host()
        self.container()
        (self.cgroup / "memory.max").write_text("max\n")
        sample = self.sample()
        self.assertEqual(sample["scope"], "cgroup")
        self.assertEqual(sample["memory"]["limit_bytes"], 8192 * 1024)
        self.assertEqual(sample["memory"]["current_bytes"], 1048576)


if __name__ == "__main__":
    unittest.main()
