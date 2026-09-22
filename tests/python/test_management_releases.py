"""Local release preparation and compatibility-aware recovery, without systemd."""
from contextlib import closing
from pathlib import Path
import json
import os
import runpy
import shutil
import sqlite3
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MODULE = runpy.run_path(str(ROOT / 'src/bin/getbible-management-release'))
Releases = MODULE['Releases']
HELPERS = MODULE['HELPERS']
UNITS = MODULE['UNITS']


class ManagementReleasesTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'source'
        self.systemd = self.root / 'systemd'
        self.systemd.mkdir()
        self.releases = Releases(self.root / 'management')
        self.db = self.root / 'history.sqlite3'
        self.make_source(3)

    def make_source(self, schema):
        source = self.source
        (source / 'src/bin').mkdir(parents=True, exist_ok=True)
        (source / 'src/systemd').mkdir(parents=True, exist_ok=True)
        (source / 'VERSION').write_text('3.2.0\n')
        for package in ('dashboard', 'telemetry'):
            folder = source / 'src/apps' / package / ('getbible_' + package)
            folder.mkdir(parents=True, exist_ok=True)
            (folder / '__init__.py').write_text('')
        (source / 'src/apps/telemetry/getbible_telemetry/store.py').write_text(f'SCHEMA_VERSION = {schema}\n')
        static = source / 'src/apps/dashboard/static'
        static.mkdir(exist_ok=True)
        (static / 'index.html').write_text('<script src="/app.js"></script>')
        (static / 'app.js').write_text('void 0;')
        for helper in HELPERS:
            (source / 'src/bin' / helper).write_text('#!/usr/bin/env python3\nprint("help")\n')
        for unit in UNITS:
            (source / 'src/systemd' / (unit + '.tmpl')).write_text('[Unit]\nDescription=fixture\n')
            (self.systemd / unit).write_text('old ' + unit)

    def stage(self):
        with self.releases.locked():
            return self.releases.stage(self.source)

    def select(self, candidate):
        with self.releases.locked():
            return self.releases.select(candidate, self.systemd)

    def test_stage_is_not_activation_and_unchanged_code_reuses_release(self):
        candidate = self.stage()
        self.assertIsNone(self.releases.current())
        self.assertTrue(self.select(candidate))
        self.releases.finish('current')
        (self.source / 'VERSION').write_text('3.2.1\n')
        self.assertEqual(candidate, self.stage())
        self.assertFalse(self.select(candidate))
        self.assertEqual(self.releases.current(), candidate)
        self.assertEqual(json.loads((candidate / 'apps/dashboard/release.json').read_text())['version'], '3.2.0')

    def test_restrictive_umask_does_not_make_published_code_private(self):
        previous = os.umask(0o077)
        try:
            candidate = self.stage()
            self.select(candidate)
        finally:
            os.umask(previous)
        for directory in (self.releases.root, self.releases.releases, candidate,
                          *(p for p in candidate.rglob('*') if p.is_dir())):
            self.assertEqual(directory.stat().st_mode & 0o777, 0o755, str(directory))
        for member in candidate.rglob('*'):
            if member.is_file():
                self.assertEqual(member.stat().st_mode & 0o444, 0o444, str(member))
                self.assertEqual(member.stat().st_mode & 0o022, 0, str(member))
        self.assertEqual(self.releases.state_file.stat().st_mode & 0o777, 0o600)
        state = json.loads(self.releases.state_file.read_text())
        self.assertEqual(Path(state['unit_backup']).stat().st_mode & 0o777, 0o700)

    def test_unreadable_retained_code_is_replaced_without_mutating_it(self):
        old = self.stage()
        self.select(old)
        (old / 'bin').chmod(0o700)
        candidate = self.stage()
        self.assertNotEqual(candidate, old)
        self.assertEqual((candidate / 'bin').stat().st_mode & 0o777, 0o755)
        self.assertEqual((old / 'bin').stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.releases.current(), old)

    def test_missing_assets_and_invalid_python_fail_before_activation(self):
        current = self.stage()
        self.select(current)
        path = self.source / 'src/apps/dashboard/static/app.js'
        path.unlink()
        with self.assertRaises(ValueError):
            self.stage()
        self.assertEqual(self.releases.current(), current)
        path.write_text('void 1;')
        (self.source / 'src/bin/getbible-dashboard').write_text('invalid syntax!')
        with self.assertRaises(SyntaxError):
            self.stage()
        self.assertEqual(self.releases.current(), current)

    def test_tampered_release_is_not_repaired_in_place(self):
        old = self.stage()
        self.select(old)
        member = old / 'bin/getbible-telemetry'
        member.write_text(member.read_text() + '# changed\n')
        candidate = self.stage()
        self.assertNotEqual(old, candidate)
        self.assertIn('# changed', member.read_text())
        self.assertEqual(self.releases.current(), old)

    def test_failure_restores_prior_code_and_unit_files_when_schema_matches(self):
        old = self.stage()
        self.select(old)
        self.releases.finish('current')
        (self.source / 'src/apps/dashboard/static/app.js').write_text('void 1;')
        candidate = self.stage()
        self.select(candidate)
        for unit in UNITS:
            (self.systemd / unit).write_text('new ' + unit)
        with closing(sqlite3.connect(self.db)) as db, db:
            db.execute('PRAGMA user_version=3')
            db.execute('CREATE TABLE retained(value)')
            db.execute('INSERT INTO retained VALUES (42)')
        self.assertTrue(self.releases.rollback(self.db, self.systemd))
        self.assertEqual(self.releases.current(), old)
        for unit in UNITS:
            self.assertEqual((self.systemd / unit).read_text(), 'old ' + unit)
        with closing(sqlite3.connect(self.db)) as db, db:
            self.assertEqual(db.execute('SELECT value FROM retained').fetchone()[0], 42)

    def test_committed_migration_is_never_reverted_by_code_recovery(self):
        self.make_source(2)
        old = self.stage()
        self.select(old)
        self.releases.finish('current')
        self.make_source(3)
        candidate = self.stage()
        self.select(candidate)
        with closing(sqlite3.connect(self.db)) as db, db:
            db.execute('PRAGMA user_version=3')
            db.execute('CREATE TABLE retained(value)')
            db.execute('INSERT INTO retained VALUES (99)')
        self.assertFalse(self.releases.rollback(self.db, self.systemd))
        self.assertEqual(self.releases.current(), candidate)
        state = json.loads(self.releases.state_file.read_text())
        self.assertEqual(state['phase'], 'recovery-required')
        with closing(sqlite3.connect(self.db)) as db, db:
            self.assertEqual(db.execute('SELECT value FROM retained').fetchone()[0], 99)

    def test_capture_preserves_original_installation_and_provides_recovery(self):
        installed = self.root / 'installed'
        baseline = self.stage()
        shutil.copytree(baseline / 'apps', installed / 'apps')
        for helper in HELPERS:
            shutil.copy2(baseline / 'bin' / helper, installed / helper)
        with self.releases.locked():
            retained = self.releases.capture(installed, self.systemd)
        self.assertIsNotNone(retained)
        self.assertEqual(self.releases.current(), retained)
        self.assertTrue((installed / 'apps/dashboard').is_dir())
        self.select(baseline)
        self.assertTrue(self.releases.rollback(self.db, self.systemd))
        self.assertEqual(self.releases.current(), retained)

    def test_forward_retry_retains_last_verified_recovery_point(self):
        good = self.stage()
        self.select(good)
        self.releases.finish('current')
        asset = self.source / 'src/apps/dashboard/static/app.js'
        asset.write_text('void 1;')
        bad = self.stage()
        self.select(bad)
        self.releases.finish('failed')
        asset.write_text('void 2;')
        retry = self.stage()
        self.select(retry)
        self.assertEqual(json.loads(self.releases.state_file.read_text())['previous'], str(good))
        self.assertTrue(self.releases.rollback(self.db, self.systemd))
        self.assertEqual(self.releases.current(), good)

    def test_unknown_activation_journal_is_not_discarded(self):
        good = self.stage()
        self.select(good)
        self.releases.finish('current')
        state = json.loads(self.releases.state_file.read_text())
        state['phase'] = 'unexpected'
        self.releases.state_file.write_text(json.dumps(state))
        (self.source / 'src/apps/dashboard/static/app.js').write_text('void 2;')
        with self.assertRaises(ValueError):
            self.select(self.stage())
        self.assertEqual(self.releases.current(), good)
        self.assertEqual(json.loads(self.releases.state_file.read_text())['phase'], 'unexpected')

    def test_unknown_journal_and_external_release_paths_fail_closed(self):
        outside = self.root / 'other'
        outside.mkdir()
        with self.assertRaises(ValueError):
            self.select(outside)
        with closing(sqlite3.connect(self.db)) as db, db:
            db.execute('CREATE TABLE unversioned(value)')
        with self.assertRaises(ValueError):
            MODULE['database_schema'](self.db)


if __name__ == '__main__':
    unittest.main()
