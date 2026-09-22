"""Transport reclamation, fair catch-up and durable capacity diagnostics."""
from __future__ import annotations

import gzip
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'src/apps/telemetry'))
from getbible_telemetry import TelemetryStore
from getbible_telemetry.capacity import CapacityTracker, capacity_report, incident_update, GIB
from getbible_telemetry.collector import Collector
from getbible_telemetry.spools import reclaim


def record(n):
    return json.dumps({'time': 100 + n, 'request_id': str(n), 'method': 'GET', 'status': 200,
                       'uri': '/v2/kjv/43/3.json', 'request_time': .01}) + '\n'


class CapacityTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = TelemetryStore(self.root / 'traffic.sqlite3')
        self.collector = Collector(self.store, str(self.root / 'logs'), batch_size=2)

    def tearDown(self):
        self.collector.close()
        self.store.close()
        self.temp.cleanup()

    def archive(self, name='access.log-old.spool', content=None):
        path = self.root / 'logs/api.example.test/archive' / name
        path.parent.mkdir(parents=True, exist_ok=True)
        data = content or record(1)
        if name.endswith('.gz'):
            with gzip.open(path, 'wt') as stream:
                stream.write(data)
        else:
            path.write_text(data)
        return path

    def test_completed_imports_do_not_consume_transport_allowance_or_reinflate(self):
        for name in ('access.log-old.gz', 'access.log-old'):
            with self.subTest(name=name):
                path = self.archive(name)
                before = self.collector.state()
                self.assertGreater(before['pending_archive_bytes'], 0)
                self.collector.ingest_file(path, 'api.example.test', 'edge', rotated=True)
                after = self.collector.state()
                self.assertEqual(after['pending_archive_bytes'], 0)
                self.assertEqual(after['budgeted_spool_bytes'], 0)
                self.assertGreater(after['retained_archive_bytes'], 0)
                restarted = Collector(self.store, str(self.root / 'logs'))
                with patch('getbible_telemetry.collector.gzip.open', side_effect=AssertionError('completed archive reopened')):
                    self.assertEqual(restarted.ingest_file(path, 'api.example.test', 'edge', rotated=True), 0)
                self.assertTrue(path.exists())

    def test_append_and_replacement_invalidate_completed_observation(self):
        path = self.archive(content=record(1))
        self.collector.ingest_file(path, 'api.example.test', 'edge', rotated=True)
        with path.open('a') as stream:
            stream.write(record(2))
        self.assertEqual(self.collector.ingest_file(path, 'api.example.test', 'edge', rotated=True), 1)
        path.write_text(record(3))
        self.assertEqual(self.collector.ingest_file(path, 'api.example.test', 'edge', rotated=True), 1)
        self.assertEqual(self.store.summary(0, 1000)['calls'], 3)

    def test_kernel_lease_preserves_open_writer_then_reclaims_committed_spool(self):
        path = self.archive()
        self.assertEqual(self.collector.cleanup(), 0)
        self.collector.ingest_file(path, 'api.example.test', 'edge', rotated=True)
        self.collector.cleanup()
        with path.open('ab') as writer, patch('getbible_telemetry.collector.time.monotonic', return_value=10**12):
            self.assertEqual(self.collector.cleanup(), 0)
            writer.write(record(2).encode()); writer.flush()
        self.assertEqual(self.collector.cleanup(), 0)  # newly appended bytes are unread
        self.collector.ingest_file(path, 'api.example.test', 'edge', rotated=True)
        self.collector.cleanup()
        with patch('getbible_telemetry.collector.time.monotonic', return_value=2 * 10**12):
            self.assertEqual(self.collector.cleanup(), 1)
        self.assertFalse(path.exists())
        self.assertEqual(self.store.summary(0, 1000)['calls'], 2)

    @unittest.skipUnless(os.geteuid() == 0, 'ownership transition requires root')
    def test_reclamation_of_other_uid_does_not_require_proc_or_new_capabilities(self):
        path = self.archive()
        os.chown(path, 65534, 65534)
        info = path.stat()
        payload = [{'path': str(path), 'identity': f'{info.st_dev}:{info.st_ino}',
                    'size': info.st_size, 'mtime_ns': info.st_mtime_ns}]
        run = subprocess.run([sys.executable, str(ROOT / 'src/apps/telemetry/getbible_telemetry/spools.py')],
                             input=json.dumps(payload), capture_output=True, text=True, check=True)
        result = json.loads(run.stdout)[0]
        self.assertTrue(result['removed'], result)
        self.assertFalse(path.exists())
        self.assertEqual(os.geteuid(), 0)

    def test_lease_failure_and_source_changes_fail_closed(self):
        path = self.archive()
        info = path.stat()
        item = {'path': str(path), 'identity': f'{info.st_dev}:{info.st_ino}',
                'size': info.st_size, 'mtime_ns': info.st_mtime_ns}
        with patch('getbible_telemetry.spools.fcntl.fcntl', side_effect=PermissionError()):
            self.assertFalse(reclaim(item)['removed'])
        self.assertTrue(path.exists())
        self.assertFalse(reclaim({**item, 'size': info.st_size + 1})['removed'])
        link = path.with_name('access.log-link.spool'); link.symlink_to(path)
        self.assertFalse(reclaim({**item, 'path': str(link)})['removed'])
        other = path.with_name('access.log'); other.write_text('retained')
        self.assertFalse(reclaim({**item, 'path': str(other)})['removed'])

    def test_bounded_passes_share_work_between_active_sources_and_archives(self):
        files = [(Path(f'/source/{kind}/{i}'), str(i), 'edge', kind == 'closed')
                 for kind in ('active', 'closed') for i in range(4)]
        clock, calls = [0.0], []
        def ingest(path, *_args, **_kwargs):
            calls.append(str(path)); clock[0] += .2
            self.collector._batch_pending = True
            return 2
        with patch.object(self.collector, 'files', return_value=files), \
             patch.object(self.collector, 'ingest_file', side_effect=ingest), \
             patch('getbible_telemetry.collector.time.monotonic', side_effect=lambda: clock[0]):
            for _ in range(4):
                self.collector.ingest_pass(time_budget=.25)
                self.assertTrue(self.collector._pass_pending)
        self.assertEqual(len(set(calls)), 8)
        self.assertIn('/active/', calls[0]); self.assertIn('/closed/', calls[1])

    def test_incidents_survive_restarts_without_cooldown_repeats(self):
        state = {'budgeted_spool_bytes': 2 * GIB, 'spool_max_bytes': GIB}
        sent = []
        self.collector._notify = lambda *args: sent.append(args)
        self.collector.health({}, state, now=1000)
        self.collector.health({}, state, now=1061)
        restarted = Collector(self.store, str(self.root))
        restarted._notify = lambda *args: sent.append(args)
        for now in (2000, 4000, 8000, 16000):
            restarted.health({}, state, now=now)
        self.assertEqual(len(sent), 1)
        restarted.health({}, {**state, 'budgeted_spool_bytes': 4 * GIB}, now=17000)
        self.assertEqual(len(sent), 2)
        restarted.health({}, {**state, 'budgeted_spool_bytes': 4 * GIB}, now=17000 + 86400)
        self.assertEqual(len(sent), 3)
        healthy = {**state, 'budgeted_spool_bytes': GIB // 2}
        restarted.health({}, healthy, now=110000)
        restarted.health({}, healthy, now=110061)
        restarted.health({}, healthy, now=110090)
        self.assertEqual(len(sent), 4)
        self.assertIn('recovered', sent[-1][1])

    def test_missing_sensor_is_not_a_recovery_and_threshold_noise_does_not_flap(self):
        state = {}
        for t in (0, 61):
            incident_update(state, 100, 90, now=t, hold=60, cooldown=900, reminder=86400)
        self.assertTrue(state['active'])
        self.assertIsNone(incident_update(state, float('nan'), 90, now=100, hold=60, cooldown=900, reminder=86400))
        for t in (100, 200, 300):
            self.assertIsNone(incident_update(state, 89, 90, now=t, hold=60, cooldown=900, reminder=86400))
        self.assertTrue(state['active'])

    def sample(self):
        return {'scope': 'cgroup', 'cpu': {'used_units': 1.9, 'capacity': 2},
                'memory': {'current_bytes': 3.9 * GIB, 'limit_bytes': 4 * GIB, 'host_available_bytes': 32 * GIB},
                'disks': [{'path': '/data', 'total_bytes': 100 * GIB, 'free_bytes': 80 * GIB, 'used_bytes': 20 * GIB}]}

    def observe(self, tracker, t, **extra):
        spool = {'budgeted_spool_bytes': 2 * GIB, 'spool_max_bytes': GIB, 'unread_bytes': 0,
                 'unread_files': 0, 'collector_instance': 'a', 'committed_bytes': t * 100,
                 'committed_records': t, 'problems': {}, **extra}
        with self.store.db:
            return tracker.observe(self.sample(), spool, now=t)

    def test_recommendations_have_evidence_units_and_survive_restart(self):
        tracker = CapacityTracker(self.store)
        first = self.observe(tracker, 100)
        self.assertEqual(first['limits'][0]['recommendation']['status'], 'insufficient_data')
        for t in range(110, 180, 10):
            result = self.observe(tracker, t)
        spool = result['limits'][0]
        self.assertEqual(spool['recommendation']['value'], 3)
        self.assertEqual(spool['unit'], 'GiB')
        self.assertEqual(spool['episodes'], 1)
        self.assertGreater(spool['saturated_seconds'], 0)
        tracker = CapacityTracker(self.store)
        result = self.observe(tracker, 180, collector_instance='b', committed_bytes=0)
        self.assertEqual(result['limits'][0]['high_water'], 2)
        with self.store.db:
            stale = capacity_report(self.store, now=1000)
        self.assertTrue(stale['stale'])
        self.assertIsNone(stale['limits'][0]['recommendation']['value'])

    def test_backlog_stall_is_not_an_instruction_to_raise_the_limit(self):
        tracker = CapacityTracker(self.store)
        for t in range(100, 190, 10):
            result = self.observe(tracker, t, unread_files=1, unread_bytes=2 * GIB, committed_bytes=0)
        self.assertEqual(result['collection']['state'], 'stalled')
        self.assertEqual(result['limits'][0]['recommendation']['status'], 'investigate_collection')
        self.assertIsNone(result['limits'][0]['recommendation']['value'])

    def test_observation_gaps_and_insufficient_headroom_are_not_filled_in(self):
        tracker = CapacityTracker(self.store)
        for t in range(100, 180, 10):
            self.observe(tracker, t)
        previous = self.observe(tracker, 180)['limits'][0]['observed_seconds']
        result = self.observe(tracker, 10000)
        self.assertEqual(result['limits'][0]['observed_seconds'], previous)
        sample = self.sample(); sample['disks'][0]['free_bytes'] = 1 * GIB
        advice = tracker._recommend(result['limits'][0], sample, {})
        self.assertEqual(advice['status'], 'insufficient_headroom')
        self.assertIsNone(advice['value'])


if __name__ == '__main__':
    unittest.main()
