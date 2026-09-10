"""Persistent numeric identities must survive image replacement unchanged."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
LOADER = importlib.machinery.SourceFileLoader("identities", str(ROOT / "src/bin/getbible-identities"))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
identities = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(identities)


def group(name, gid, members=()):
    return SimpleNamespace(gr_name=name, gr_gid=gid, gr_mem=list(members))


def user(name, uid, gid, home="/var/lib/getbible/sync/demo", shell="/usr/sbin/nologin"):
    return SimpleNamespace(pw_name=name, pw_uid=uid, pw_gid=gid, pw_dir=home, pw_shell=shell)


def registry():
    return {"version": 1, "groups": {"getbible-sync-demo": {"gid": 971}, "getbible-readers": {"gid": 972}},
            "users": {"getbible-sync-demo": {"uid": 973, "group": "getbible-sync-demo",
                      "home": "/var/lib/getbible/sync/demo", "shell": "/usr/sbin/nologin",
                      "supplementary_groups": ["getbible-readers"]}}}


class IdentitiesTest(unittest.TestCase):
    def test_recreation_retains_numeric_ids_and_supplementary_groups(self):
        with patch.object(identities.grp, "getgrall", return_value=[]), patch.object(identities.pwd, "getpwall", return_value=[]):
            plan = identities.restore_plan(registry())
        self.assertIn(["groupadd", "--system", "--gid", "971", "getbible-sync-demo"], plan)
        creation = next(command for command in plan if command[0] == "useradd")
        self.assertEqual(creation[creation.index("--uid") + 1], "973")
        self.assertEqual(creation[creation.index("--gid") + 1], "971")
        self.assertIn("--no-create-home", creation)
        self.assertEqual(plan[-1], ["usermod", "--append", "--groups", "getbible-readers", "getbible-sync-demo"])
        self.assertTrue(all(command[0] != "chown" for command in plan))

    def test_uid_collision_rejects_entire_plan_before_any_changes(self):
        with patch.object(identities.grp, "getgrall", return_value=[]), \
                patch.object(identities.pwd, "getpwall", return_value=[user("unrelated", 973, 555)]), \
                patch.object(identities.subprocess, "run") as mutate:
            with self.assertRaisesRegex(identities.IdentityError, "occupied by unrelated"):
                identities.restore_plan(registry())
            mutate.assert_not_called()

    def test_existing_name_with_another_gid_is_never_adopted(self):
        with patch.object(identities.grp, "getgrall", return_value=[group("getbible-sync-demo", 888)]), \
                patch.object(identities.pwd, "getpwall", return_value=[]):
            with self.assertRaisesRegex(identities.IdentityError, "GID conflict"):
                identities.restore_plan(registry())

    def test_existing_correct_accounts_are_not_recreated(self):
        with patch.object(identities.grp, "getgrall", return_value=[group("getbible-sync-demo", 971), group("getbible-readers", 972)]), \
                patch.object(identities.pwd, "getpwall", return_value=[user("getbible-sync-demo", 973, 971)]):
            plan = identities.restore_plan(registry())
        self.assertEqual([command[0] for command in plan], ["usermod"])

    def test_atomic_registry_is_private_and_self_describing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "identities.json"
            identities.save(path, registry())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(identities.load(path), registry())
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_root_and_duplicate_ids_are_rejected(self):
        for identity in (0, 971):
            state = registry()
            state["groups"]["another"] = {"gid": identity}
            with self.assertRaises(identities.IdentityError):
                identities.validate(state)

    def test_missing_supplementary_group_and_invalid_home_are_rejected(self):
        state = registry()
        state["users"]["getbible-sync-demo"]["supplementary_groups"] = ["missing"]
        with self.assertRaisesRegex(identities.IdentityError, "supplementary"):
            identities.validate(state)
        state = registry()
        state["users"]["getbible-sync-demo"]["home"] = "/tmp/bad\nline"
        with self.assertRaisesRegex(identities.IdentityError, "home"):
            identities.validate(state)

    def test_record_captures_service_and_nginx_memberships(self):
        groups = {"www-data": group("www-data", 33), "getbible-readers": group("getbible-readers", 972, ["www-data"])}
        with patch.object(identities.pwd, "getpwnam", return_value=user("www-data", 33, 33, "/var/www")), \
                patch.object(identities.grp, "getgrgid", return_value=groups["www-data"]), \
                patch.object(identities.grp, "getgrall", return_value=list(groups.values())), \
                patch.object(identities.grp, "getgrnam", side_effect=groups.__getitem__):
            state = {"version": 1, "groups": {}, "users": {}}
            identities.record_user(state, "www-data")
        self.assertEqual(state["users"]["www-data"]["uid"], 33)
        self.assertEqual(state["users"]["www-data"]["supplementary_groups"], ["getbible-readers"])
        self.assertEqual(state["groups"]["getbible-readers"]["gid"], 972)


if __name__ == "__main__":
    unittest.main()
