#!/usr/bin/env python3
"""Optional passive checkpoints for operator-run macOS lifecycle qualification.

Writes only its evidence directory. Does not launch/quit the app, invoke its
tests, change preferences/brightness, inject code, or request permissions.
"""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import secrets
import subprocess
import sys
import tempfile
import time

APP_ID = "com.ry00ki.wallpaperveil"
SUPPORT = Path.home() / "Library/Application Support/Wallpaper Veil"
RUNTIME = Path("Contents/Helpers/Wallpaper Veil Runtime.app")
CASES = {
    "sleep-wake": "Real system sleep/wake and display-only sleep/wake; repeat with sync enabled and disabled.",
    "spaces": "Switch Spaces on both displays; verify tint below icons, desktop clicks and full-screen transitions.",
    "source-reconnect": "Physically disconnect and reconnect the selected source; verify the same saved pair recovers.",
    "follower-reconnect": "Physically disconnect and reconnect the selected follower; verify the same saved pair recovers.",
    "persistence": "Compare settings and visible controls before events and after a normal quit/relaunch.",
    "quit": "Quit from the app menu; verify overlays/menu disappear and runtime stays absent before relaunch.",
}
LIMITS = [
    "No physical acceptance is computed: results are operator-reported and require review in issue #4.",
    "Checkpoints are sequential samples, not an atomic snapshot or a continuous event trace.",
    "This helper does not read live brightness, app timers/watchers, pixels, clicks or Spaces state.",
    "Startup diagnostics are historical even when their PID matches; they cannot prove event recovery.",
    "No process found is evidence of sampled process absence, not direct inspection of cleanup callbacks.",
    "Unknown/failed diagnostics are not an empty display list, absent process or unchanged settings.",
    "Settings fingerprints cover wallpaperVeil.* only; login registration and OS preferences require manual inspection.",
    "Source independence, fresh-account launch, reboot/login and other hardware/OS versions are not qualified here.",
]


def utc():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds")


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else hashlib.sha256(stream.read()).hexdigest()


def token(key, value):
    return hmac.new(bytes.fromhex(key), value, hashlib.sha256).hexdigest()


def probe(callback):
    """Do not persist exceptions: paths, command output or values may be private."""
    try:
        return {"status": "ok", "value": callback()}
    except subprocess.TimeoutExpired:
        return {"status": "unavailable", "reason": "command-timeout"}
    except subprocess.CalledProcessError as error:
        return {"status": "unavailable", "reason": "command-failed", "returncode": error.returncode}
    except (OSError, ValueError, TypeError, KeyError, plistlib.InvalidFileException):
        return {"status": "unavailable", "reason": "missing-unreadable-or-unrecognised-data"}


def command(args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=20).stdout


def app_identity(app):
    outer = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    inner = plistlib.loads((app / RUNTIME / "Contents/Info.plist").read_bytes())
    if not isinstance(outer, dict) or not isinstance(inner, dict):
        raise ValueError("Unrecognised bundle metadata")
    if (outer.get("CFBundleIdentifier") != APP_ID + ".launcher"
            or inner.get("CFBundleIdentifier") != APP_ID
            or outer.get("CFBundleExecutable") != "WallpaperVeil"
            or inner.get("CFBundleExecutable") != "WallpaperVeilRuntime"):
        raise ValueError("Unexpected app identity")
    manifest = app / "Contents/Resources/wallpaper-veil-build.json"
    provenance = json.loads(manifest.read_text())
    if not isinstance(provenance, dict) or not isinstance(provenance.get("source"), dict):
        raise ValueError("Unrecognised provenance")
    source = provenance["source"].get("local_head")
    return {"version": str(outer.get("CFBundleShortVersionString", "unknown")),
            "build": str(outer.get("CFBundleVersion", "unknown")),
            "manifest_sha256": digest(manifest),
            "launcher_sha256": digest(app / "Contents/MacOS/WallpaperVeil"),
            "runtime_sha256": digest(app / RUNTIME / "Contents/MacOS/WallpaperVeilRuntime"),
            "source_commit": source if isinstance(source, str) and re.fullmatch(r"[0-9a-f]{40}", source) else None}


def processes(raw, app):
    """ps comm (no arguments); exact canonical executable matching, no PID-file trust."""
    expected = {
        str(app / "Contents/MacOS/WallpaperVeil"): "launcher",
        str(app / RUNTIME / "Contents/MacOS/WallpaperVeilRuntime"): "runtime",
        str(app / "Contents/Helpers/WallpaperVeilUpdater"): "updater",
    }
    selected, other_count, parsed = [], 0, 0
    for line in raw.decode("utf-8").splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or not fields[0].isdigit():
            continue
        parsed += 1
        pid, executable = int(fields[0]), str(Path(fields[1]).resolve())
        if executable in expected:
            selected.append({"pid": pid, "role": expected[executable]})
        elif Path(executable).name in {"WallpaperVeil", "WallpaperVeilRuntime", "WallpaperVeilUpdater", "Hammerspoon"}:
            other_count += 1
    if not parsed:
        raise ValueError("Unrecognised process listing")
    return {"selected_app": selected, "other_candidate_count": other_count}


def displays(raw, key):
    adapters = json.loads(raw)["SPDisplaysDataType"]
    if not isinstance(adapters, list) or not adapters:
        raise ValueError("No recognised display adapters")
    result = []
    for adapter in adapters:
        if not isinstance(adapter, dict):
            raise ValueError("Unrecognised adapter")
        # Schema differences must not silently turn unknown into zero displays.
        entries = adapter["spdisplays_ndrvs"]
        if not isinstance(entries, list):
            raise ValueError("Unrecognised display inventory")
        for entry in entries:
            if not isinstance(entry, dict):
                raise ValueError("Unrecognised display")
            identity = {k: entry[k] for k in (
                "_spdisplays_displayID", "_spdisplays_display-product-id",
                "_spdisplays_display-vendor-id", "_spdisplays_display-serial-number",
                "spdisplays_display-serial-number") if k in entry}
            item = {"session_token": token(key, json.dumps(identity, sort_keys=True).encode()) if identity else None}
            # Deliberate allowlist: no names, serials, UUIDs, IO paths or raw inventory.
            for field in ("_spdisplays_resolution", "spdisplays_resolution",
                          "spdisplays_pixelresolution", "spdisplays_main",
                          "spdisplays_mirror", "spdisplays_online", "spdisplays_connection_type"):
                if isinstance(entry.get(field), (str, int, bool)):
                    item[field] = entry[field]
            result.append(item)
    return {"count": len(result), "displays": result,
            "identity_note": "Tokens are session-local and may change on reconnect; map source/follower manually."}


def preferences(raw, key):
    values = plistlib.loads(raw)
    if not isinstance(values, dict):
        raise ValueError("Expected preferences dictionary")
    # Hash names as well as typed values: future/custom keys may contain private data.
    return {token(key, name.encode()): token(key, plistlib.dumps({"value": value}, sort_keys=True))
            for name, value in values.items() if name.startswith("wallpaperVeil.")}


def compare_preferences(baseline, current):
    if baseline.get("status") != "ok" or current.get("status") != "ok":
        return {"status": "unknown"}
    before, after = baseline["value"], current["value"]
    return {"status": "equal" if before == after else "changed",
            "added": len(after.keys() - before.keys()), "removed": len(before.keys() - after.keys()),
            "changed": sum(before[k] != after[k] for k in before.keys() & after.keys())}


def startup_receipt(path, process_probe):
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError("Unrecognised startup receipt")
    identity = value.get("identity", value.get("process", {}))
    if not isinstance(identity, dict):
        raise ValueError("Unrecognised startup identity")
    pid = identity.get("processID")
    candidates = process_probe.get("value", {}).get("selected_app", [])
    modified = path.stat().st_mtime
    return {"file_modified_at_utc": dt.datetime.fromtimestamp(modified, dt.timezone.utc).isoformat(),
            "file_age_seconds": round(time.time() - modified, 3),
            "reported_ok": value.get("ok") if isinstance(value.get("ok"), bool) else None,
            "pid_matches_sampled_runtime": (any(p["pid"] == pid and p["role"] == "runtime" for p in candidates)
                                            if process_probe.get("status") == "ok" else None),
            "scope": "historical startup receipt; not a live lifecycle observation"}


def capture(config):
    app, key = Path(config["app_path"]), config["hmac_key"]
    sample = {"started_at_utc": utc(), "app": probe(lambda: app_identity(app))}
    sample["processes"] = probe(lambda: processes(command(["/bin/ps", "-ww", "-axo", "pid=,comm="]), app))
    sample["displays"] = probe(lambda: displays(command([
        "/usr/sbin/system_profiler", "SPDisplaysDataType", "-json", "-detailLevel", "mini"]), key))
    sample["preferences"] = probe(lambda: preferences(command(["/usr/bin/defaults", "export", APP_ID, "-"]), key))
    sample["startup_receipt"] = probe(lambda: startup_receipt(SUPPORT / "diagnostics.json", sample["processes"]))
    sample["finished_at_utc"] = utc()
    return sample


def write_text(path, text, exclusive=False):
    # Publish only complete files. An interrupted temporary file is ignored.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".pending-", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        if exclusive:
            os.link(temporary, path)  # Fail if another record already owns this name.
        else:
            os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def write_json(path, value, exclusive=False):
    write_text(path, json.dumps(value, indent=2, ensure_ascii=False) + "\n", exclusive)


def append_event(directory, event):
    # Separate immutable entries retain completed checkpoints after interruption.
    event["sequence"] = max((item["sequence"] for item in events(directory)), default=0) + 1
    event["id"] = secrets.token_hex(8)
    write_json(directory / (event["id"] + ".json"), event, exclusive=True)
    return event["id"]


def events(directory):
    result = [json.loads(path.read_text()) for path in directory.glob("*.json")]
    # Wall clocks can jump and multiple records can share a timestamp.
    return sorted(result, key=lambda item: item["sequence"])


def report(config, history, include_notes=False):
    checkpoints = [event for event in history if event["kind"] == "checkpoint"]
    baseline = next((event["sample"] for event in checkpoints if event["case"] == "baseline"), {})
    rendered = []
    for event in checkpoints:
        sample = event["sample"]
        item = {k: event[k] for k in ("id", "sequence", "at_utc", "case", "phase")}
        item["sample"] = {k: v for k, v in sample.items() if k != "preferences"}
        item["preferences_vs_baseline"] = compare_preferences(baseline.get("preferences", {}), sample["preferences"])
        item["app_matches_baseline"] = (sample["app"]["value"] == baseline["app"]["value"]
                                        if sample["app"]["status"] == baseline.get("app", {}).get("status") == "ok" else None)
        rendered.append(item)
    observations = []
    for event in history:
        if event["kind"] == "observation":
            item = {k: event[k] for k in ("id", "sequence", "at_utc", "case", "result", "checkpoint_ids")}
            item["scope"] = "operator-reported; not automatically verified"
            if include_notes:
                item["note"] = event["note"]
            observations.append(item)
    value = {"schema": 1, "created_at_utc": config["created_at_utc"],
             "helper_sha256": config["helper_sha256"], "host": config["host"],
             "physical_acceptance": "requires hardware execution and human review in issue #4",
             "limitations": LIMITS, "checkpoints": rendered, "observations": observations,
             "not_recorded": [case for case in CASES if not any(o["case"] == case for o in observations)]}
    if include_notes:
        value["operator_setup"] = config["setup"]
    return value


def markdown(value):
    lines = ["# Lifecycle qualification evidence", "", value["physical_acceptance"], "",
             "No automatic physical PASS. Observation results below are operator-reported.", "",
             "| Case | Recorded results (all attempts) |", "| --- | --- |"]
    for case in CASES:
        attempts = [o["result"] for o in value["observations"] if o["case"] == case]
        lines.append(f"| {case} | {', '.join(attempts) if attempts else 'NOT RUN'} |")
    lines += ["", "See report.json for timestamped samples, diagnostic failures and checkpoint references.", ""]
    lines += ["- " + limit for limit in LIMITS]
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    start = sub.add_parser("start", help="Create a NEW session and capture baseline; launch the app yourself first")
    start.add_argument("--app", type=Path, required=True)
    start.add_argument("--setup", required=True, help="Private operator notes: Mac, display roles, ports, Spaces, baseline settings")
    checkpoint = sub.add_parser("checkpoint", help="Capture passive evidence around a physical action")
    checkpoint.add_argument("--case", choices=CASES, required=True)
    checkpoint.add_argument("--phase", choices=["before", "during", "after", "recheck"], required=True)
    observe = sub.add_parser("observe", help="Record an operator result; never inferred from diagnostics")
    observe.add_argument("--case", choices=CASES, required=True)
    observe.add_argument("--result", choices=["pass", "fail", "blocked"], required=True)
    observe.add_argument("--checkpoints", nargs="+", required=True, help="IDs printed by checkpoint")
    observe.add_argument("--note", required=True, help="Actual actions, timings, visible outcomes, recovery and limitations")
    export = sub.add_parser("report", help="Write report.json and report.md, with all attempts retained")
    export.add_argument("--include-notes", action="store_true", help="Include operator text; review manually for private data")
    for child in (start, checkpoint, observe, export):
        child.add_argument("--session", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.mode in {"start", "checkpoint"} and platform.system() != "Darwin":
        parser.error("Live collection requires macOS; no physical checks were performed")
    os.umask(0o077)
    session = args.session.expanduser().resolve()
    if args.mode == "start":
        app = args.app.expanduser().resolve()
        if session.is_relative_to(app) or session.is_relative_to(SUPPORT.resolve()):
            parser.error("Evidence must be outside the app bundle and its state directory")
        if not args.setup.strip():
            parser.error("Describe the test setup")
        app_identity(app)  # Fail before creating evidence for an unrecognised bundle.
        session.mkdir(mode=0o700, parents=True, exist_ok=False)
        (session / "events").mkdir(mode=0o700)
        config = {"schema": 1, "created_at_utc": utc(), "app_path": str(app),
                  "setup": args.setup, "hmac_key": secrets.token_hex(32), "helper_sha256": digest(Path(__file__)),
                  "host": {"architecture": platform.machine(),
                           "macos_version": probe(lambda: command(["/usr/bin/sw_vers", "-productVersion"]).decode().strip()),
                           "macos_build": probe(lambda: command(["/usr/bin/sw_vers", "-buildVersion"]).decode().strip()),
                           "model": probe(lambda: command(["/usr/sbin/sysctl", "-n", "hw.model"]).decode().strip())}}
        write_json(session / "session.json", config, exclusive=True)
    # Reject non-session directories before creating a lock file in them.
    config = json.loads((session / "session.json").read_text())
    if not isinstance(config, dict) or config.get("schema") != 1 or not (session / "events").is_dir():
        raise ValueError("Unsupported evidence session")
    # Serialize operations so report cannot read a half-written event.
    with (session / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        history = events(session / "events")
        if args.mode in {"start", "checkpoint"}:
            event = {"kind": "checkpoint", "at_utc": utc(),
                     "case": "baseline" if args.mode == "start" else args.case,
                     "phase": "before" if args.mode == "start" else args.phase,
                     "sample": capture(config)}
            identifier = append_event(session / "events", event)
            print("Checkpoint " + identifier)
            for name, value in event["sample"].items():
                if isinstance(value, dict) and value.get("status") == "unavailable":
                    print(f"  {name}: unavailable ({value['reason']}); not a pass")
        elif args.mode == "observe":
            selected = [event for event in history if event["id"] in args.checkpoints and event["kind"] == "checkpoint"]
            if (len(set(args.checkpoints)) != len(args.checkpoints) or len(selected) != len(args.checkpoints)
                    or any(e["case"] not in {args.case, "baseline"} for e in selected)):
                parser.error("Reference distinct existing checkpoints from this case (or baseline)")
            if args.result == "pass" and not ({"before", "after"} <= {e["phase"] for e in selected if e["case"] == args.case}):
                parser.error("A reported pass requires this case's before and after checkpoints")
            if not args.note.strip():
                parser.error("Describe what actually happened")
            print("Observation " + append_event(session / "events", {
                "kind": "observation", "at_utc": utc(), "case": args.case, "result": args.result,
                "checkpoint_ids": args.checkpoints, "note": args.note}))
        else:
            value = report(config, history, args.include_notes)
            write_json(session / "report.json", value)
            write_text(session / "report.md", markdown(value))
            print("Wrote report.json and report.md. Review before sharing; issue #4 remains open.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException):
        print("Cannot read/create evidence or recognise the app/session. Check paths and data; no acceptance claimed.", file=sys.stderr)
        raise SystemExit(1)
