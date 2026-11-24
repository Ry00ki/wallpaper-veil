"""Offline evidence-format/collection tests; no physical lifecycle acceptance."""
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import qualify_lifecycle as q


KEY = "ab" * 32


def inventory():
    return {"SPDisplaysDataType": [{"spdisplays_ndrvs": [
        {"_name": "PRIVATE DISPLAY", "_spdisplays_displayID": "PRIVATE ID",
         "spdisplays_display-serial-number": "PRIVATE SERIAL",
         "_spdisplays_resolution": "2560 x 1440", "spdisplays_online": "spdisplays_yes",
         "_spdisplays_displayPath": "/PRIVATE/PATH"}]}]}


class EvidenceTests(unittest.TestCase):
    def test_display_allowlist_and_session_scoped_identity(self):
        raw = json.dumps(inventory()).encode()
        value = q.displays(raw, KEY)
        self.assertEqual(value["count"], 1)
        self.assertNotIn("PRIVATE", json.dumps(value))
        self.assertEqual(value, q.displays(raw, KEY))
        self.assertNotEqual(value["displays"][0]["session_token"],
                            q.displays(raw, "cd" * 32)["displays"][0]["session_token"])

    def test_unknown_display_shapes_are_unavailable_not_disconnected(self):
        for value in ({}, {"SPDisplaysDataType": []}, {"SPDisplaysDataType": [{}]},
                      {"SPDisplaysDataType": [{"spdisplays_ndrvs": None}]},
                      {"SPDisplaysDataType": [None]}):
            with self.subTest(value=value):
                result = q.probe(lambda: q.displays(json.dumps(value).encode(), KEY))
                self.assertEqual(result["status"], "unavailable")
                self.assertNotIn("value", result)
        self.assertEqual(q.displays(json.dumps({"SPDisplaysDataType": [{"spdisplays_ndrvs": []}]}).encode(), KEY)["count"], 0)

    def test_preferences_hide_values_keys_and_preserve_types_presence(self):
        def pref(values):
            return {"status": "ok", "value": q.preferences(plistlib.dumps(values), KEY)}
        before = pref({"wallpaperVeil.privateKey": "SECRET", "unrelated": "OTHER SECRET"})
        self.assertNotIn("privateKey", json.dumps(before))
        self.assertNotIn("SECRET", json.dumps(before))
        self.assertEqual(len(before["value"]), 1)
        self.assertEqual(q.compare_preferences(before, before)["status"], "equal")
        self.assertEqual(q.compare_preferences(pref({"wallpaperVeil.enabled": False}), pref({}))["removed"], 1)
        self.assertEqual(q.compare_preferences(pref({"wallpaperVeil.x": 0}), pref({"wallpaperVeil.x": False}))["changed"], 1)
        self.assertEqual(q.compare_preferences({"status": "unavailable"}, before), {"status": "unknown"})

    def test_exact_app_processes_and_other_copies(self):
        app = Path("/Applications/Wallpaper Veil.app")
        raw = (f"10 {app / q.RUNTIME}/Contents/MacOS/WallpaperVeilRuntime\n"
               "11 /Applications/Wallpaper Veil.app.old/Contents/MacOS/WallpaperVeilRuntime\n"
               "12 /Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon\n"
               "13 /usr/bin/unrelated\n").encode()
        value = q.processes(raw, app)
        self.assertEqual(value["selected_app"], [{"pid": 10, "role": "runtime"}])
        self.assertEqual(value["other_candidate_count"], 2)
        self.assertEqual(q.processes(b"1 /sbin/launchd\n", app)["selected_app"], [])
        self.assertEqual(q.probe(lambda: q.processes(b"", app))["status"], "unavailable")

    def test_errors_and_timeouts_do_not_leak_raw_output(self):
        for error in (subprocess.TimeoutExpired("PRIVATE", 20, output=b"SECRET"),
                      subprocess.CalledProcessError(1, "PRIVATE", stderr=b"SECRET"),
                      OSError("SECRET PATH")):
            with self.subTest(error=type(error)):
                value = q.probe(mock.Mock(side_effect=error))
                self.assertEqual(value["status"], "unavailable")
                self.assertNotIn("SECRET", json.dumps(value))
                self.assertNotIn("PRIVATE", json.dumps(value))

    def test_startup_receipt_stays_historical_and_pid_match_is_not_freshness(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "diagnostics.json"
            path.write_text(json.dumps({"ok": True, "identity": {"processID": 4}, "persistedSettings": "SECRET"}))
            os.utime(path, (1, 1))
            process = {"status": "ok", "value": {"selected_app": [{"pid": 4, "role": "runtime"}]}}
            value = q.startup_receipt(path, process)
            self.assertTrue(value["pid_matches_sampled_runtime"])
            self.assertGreater(value["file_age_seconds"], 1000)
            self.assertIn("historical", value["scope"])
            self.assertNotIn("SECRET", json.dumps(value))
            self.assertIsNone(q.startup_receipt(path, {"status": "unavailable"})["pid_matches_sampled_runtime"])

    def test_atomic_exclusive_records_and_ignored_interrupted_temporary_file(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            identifier = q.append_event(directory, {"kind": "checkpoint", "at_utc": q.utc()})
            path = directory / (identifier + ".json")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                q.write_json(path, {"overwrite": True}, exclusive=True)
            (directory / ".pending-interrupted").write_text("{")
            self.assertEqual(len(q.events(directory)), 1)
            self.assertEqual(q.events(directory)[0]["kind"], "checkpoint")

    def test_command_invocation_is_bounded_and_has_no_shell(self):
        with mock.patch.object(q.subprocess, "run", return_value=mock.Mock(stdout=b"{}")) as run:
            q.command(["/usr/bin/defaults", "export", q.APP_ID, "-"])
        self.assertEqual(run.call_args.kwargs["timeout"], 20)
        self.assertNotIn("shell", run.call_args.kwargs)

    def test_event_order_survives_clock_reversal(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            first = q.append_event(directory, {"kind": "observation", "at_utc": "2026-11-03T12:00:00Z"})
            second = q.append_event(directory, {"kind": "observation", "at_utc": "2026-11-03T11:00:00Z"})
            self.assertEqual([e["id"] for e in q.events(directory)], [first, second])


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.app = self.root / "Wallpaper Veil.app"
        self.session = self.root / "evidence"
        for bundle, identifier, executable in (
                (self.app, q.APP_ID + ".launcher", "WallpaperVeil"),
                (self.app / q.RUNTIME, q.APP_ID, "WallpaperVeilRuntime")):
            (bundle / "Contents/MacOS").mkdir(parents=True)
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": identifier, "CFBundleExecutable": executable,
                "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "10"}))
            (bundle / "Contents/MacOS" / executable).write_bytes(b"fake executable")
        (self.app / "Contents/Resources").mkdir()
        (self.app / "Contents/Resources/wallpaper-veil-build.json").write_text(json.dumps({"source": {"local_head": "a" * 40}}))
        self.prefs = {"wallpaperVeil.enabled": True}
        self.running = True
        self.commands = []
        self.patches = [mock.patch.object(q.platform, "system", return_value="Darwin"),
                        mock.patch.object(q, "command", side_effect=self.command),
                        mock.patch.object(q, "SUPPORT", self.root / "support")]
        for patch in self.patches:
            patch.start()
        self.previous_umask = os.umask(0o077)

    def tearDown(self):
        os.umask(self.previous_umask)
        for patch in reversed(self.patches):
            patch.stop()
        self.temporary.cleanup()

    def command(self, args):
        self.commands.append(args)
        if args[0] == "/bin/ps":
            return (f"44 {self.app / q.RUNTIME}/Contents/MacOS/WallpaperVeilRuntime\n" if self.running else "1 /sbin/launchd\n").encode()
        if args[0] == "/usr/sbin/system_profiler":
            return json.dumps(inventory()).encode()
        if args[0] == "/usr/bin/defaults":
            return plistlib.dumps(self.prefs)
        return b"fixture-host"

    def cli(self, *args):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return q.main([*args, "--session", str(self.session)])

    def start(self):
        self.cli("start", "--app", str(self.app), "--setup", "PRIVATE SETUP")

    def checkpoints(self):
        return [e for e in q.events(self.session / "events") if e["kind"] == "checkpoint"]

    def test_end_to_end_offline_session_records_manual_action_and_report(self):
        self.start()
        self.cli("checkpoint", "--case", "quit", "--phase", "before")
        before = self.checkpoints()[-1]["id"]
        self.running = False
        self.cli("checkpoint", "--case", "quit", "--phase", "after")
        after = self.checkpoints()[-1]["id"]
        self.cli("observe", "--case", "quit", "--result", "pass", "--checkpoints", before, after,
                 "--note", "PRIVATE OBSERVATION; fixtures only")
        self.cli("report")
        report = json.loads((self.session / "report.json").read_text())
        self.assertEqual(report["observations"][0]["result"], "pass")
        self.assertIn("requires hardware execution", report["physical_acceptance"])
        self.assertNotIn("PRIVATE", json.dumps(report))
        self.assertNotIn(str(self.root), json.dumps(report))
        self.assertEqual(report["checkpoints"][-1]["sample"]["processes"]["value"]["selected_app"], [])
        self.assertEqual(report["checkpoints"][-1]["preferences_vs_baseline"]["status"], "equal")
        self.assertNotIn("hmac_key", json.dumps(report))
        self.cli("report", "--include-notes")
        self.assertIn("PRIVATE OBSERVATION", (self.session / "report.json").read_text())
        self.assertEqual(self.session.stat().st_mode & 0o777, 0o700)
        # Every invoked command is an explicit read; no app or handoff/self-test invocation.
        allowed = {("/bin/ps", "-ww", "-axo", "pid=,comm="),
                   ("/usr/sbin/system_profiler", "SPDisplaysDataType", "-json", "-detailLevel", "mini"),
                   ("/usr/bin/defaults", "export", q.APP_ID, "-"),
                   ("/usr/bin/sw_vers", "-productVersion"), ("/usr/bin/sw_vers", "-buildVersion"),
                   ("/usr/sbin/sysctl", "-n", "hw.model")}
        self.assertLessEqual({tuple(c) for c in self.commands}, allowed)

    def test_changed_settings_and_app_identity_are_visible(self):
        self.start()
        self.prefs["wallpaperVeil.enabled"] = False
        (self.app / "Contents/MacOS/WallpaperVeil").write_bytes(b"changed binary")
        self.cli("checkpoint", "--case", "persistence", "--phase", "after")
        self.cli("report")
        value = json.loads((self.session / "report.json").read_text())["checkpoints"][-1]
        self.assertEqual(value["preferences_vs_baseline"]["status"], "changed")
        self.assertFalse(value["app_matches_baseline"])

    def test_unavailable_preferences_are_not_reported_equal(self):
        self.start()
        original = self.command
        def failing(args):
            if args[0] == "/usr/bin/defaults":
                raise subprocess.CalledProcessError(1, args, stderr=b"PRIVATE")
            return original(args)
        with mock.patch.object(q, "command", side_effect=failing):
            self.cli("checkpoint", "--case", "persistence", "--phase", "after")
        self.cli("report")
        value = json.loads((self.session / "report.json").read_text())["checkpoints"][-1]
        self.assertEqual(value["preferences_vs_baseline"]["status"], "unknown")

    def test_pass_requires_own_case_before_and_after_and_valid_ids(self):
        self.start()
        baseline = self.checkpoints()[0]["id"]
        for refs in ([baseline], ["unknown"], [baseline, baseline]):
            with self.subTest(refs=refs), self.assertRaises(SystemExit):
                self.cli("observe", "--case", "spaces", "--result", "pass", "--checkpoints", *refs, "--note", "fixture")
        self.cli("checkpoint", "--case", "quit", "--phase", "before")
        wrong_case = self.checkpoints()[-1]["id"]
        with self.assertRaises(SystemExit):
            self.cli("observe", "--case", "spaces", "--result", "fail", "--checkpoints", wrong_case, "--note", "fixture")

    def test_failure_is_not_hidden_by_a_later_observation(self):
        self.start()
        baseline = self.checkpoints()[0]["id"]
        for result in ("fail", "blocked"):
            self.cli("observe", "--case", "sleep-wake", "--result", result, "--checkpoints", baseline, "--note", "fixture")
        self.cli("report")
        report = json.loads((self.session / "report.json").read_text())
        self.assertEqual([o["result"] for o in report["observations"]], ["fail", "blocked"])
        self.assertIn("fail, blocked", (self.session / "report.md").read_text())

    def test_report_without_observations_has_no_pass(self):
        self.start()
        self.cli("report")
        value = json.loads((self.session / "report.json").read_text())
        self.assertEqual(set(value["not_recorded"]), set(q.CASES))
        self.assertEqual(value["observations"], [])

    def test_existing_session_is_not_overwritten(self):
        self.start()
        original = (self.session / "session.json").read_bytes()
        with self.assertRaises(FileExistsError):
            self.start()
        self.assertEqual(original, (self.session / "session.json").read_bytes())

    def test_rejects_wrong_app_and_state_or_bundle_output_directory(self):
        original_session = self.session
        for path in (self.app / "evidence", q.SUPPORT / "evidence"):
            self.session = path
            with self.assertRaises(SystemExit):
                self.start()
            self.assertFalse(path.exists())
        self.session = original_session
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "not-wallpaper-veil"}))
        with self.assertRaises(ValueError):
            self.start()
        self.assertFalse(self.session.exists())

    def test_live_collection_refuses_linux_without_writing(self):
        with mock.patch.object(q.platform, "system", return_value="Linux"), self.assertRaises(SystemExit):
            self.start()
        self.assertFalse(self.session.exists())

    def test_report_rejects_non_session_without_writing(self):
        self.session = self.app
        with self.assertRaises(FileNotFoundError):
            self.cli("report")
        self.assertFalse((self.app / ".lock").exists())


if __name__ == "__main__":
    unittest.main()
