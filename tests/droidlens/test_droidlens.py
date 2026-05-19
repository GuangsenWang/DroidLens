from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DROIDLENS = ROOT / "scripts" / "droidlens"


def run_cmd(args: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        **kwargs,
    )


def write_executable(path: Path, content: str) -> None:
    path.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def write_fake_adb(path: Path) -> None:
    write_executable(
        path,
        r"""
        #!/usr/bin/env bash
        log="${FAKE_ADB_LOG:?FAKE_ADB_LOG is required}"
        if [[ "$1" == "-s" ]]; then
            shift 2
        fi
        printf '%s\n' "$*" >> "$log"
        if [[ "$1" == "devices" ]]; then
            printf 'List of devices attached\nfake-device\tdevice\n'
            exit 0
        fi
        if [[ "$1" == "exec-out" && "$2" == "screencap" ]]; then
            python3 - <<'PY'
import base64
import sys

png = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/l7tP2wAAAABJRU5ErkJggg=="
)
sys.stdout.buffer.write(png + (b"0" * 2048))
PY
            exit 0
        fi
        if [[ "$1" == "shell" && "$2" == dumpsys* ]]; then
            if [[ "$*" == *"dumpsys display"* ]]; then
                printf 'mCurrentDisplayRect=Rect( 0, 0 - 1000, 2000)\n'
                exit 0
            fi
            if [[ "$*" == *"dumpsys package"* ]]; then
                printf 'versionCode=1 minSdk=23 targetSdk=35\n'
                exit 0
            fi
        fi
        if [[ "$1" == "shell" && "$2" == wm* && "$*" == *"wm density"* ]]; then
            printf 'Physical density: 440\n'
            exit 0
        fi
        if [[ "$1" == "shell" && "$2" == cmd* && "$*" == *"cmd package resolve-activity"* ]]; then
            printf 'com.example.app/com.example.app.MainActivity\n'
            exit 0
        fi
        if [[ "$1" == "shell" && "$2" == pm* && "$*" == *"pm path"* ]]; then
            printf 'package:/data/app/base.apk\n'
            exit 0
        fi
        exit 0
        """,
    )


def fake_adb_env(tmp_path: Path) -> dict[str, str]:
    fake_adb = tmp_path / "adb"
    log = tmp_path / "adb.log"
    write_fake_adb(fake_adb)
    env = os.environ.copy()
    env["DROIDLENS_ADB"] = str(fake_adb)
    env["FAKE_ADB_LOG"] = str(log)
    env["DROIDLENS_SERIAL"] = "fake-device"
    env["DROIDLENS_APP"] = "com.example.app/.MainActivity"
    env["DROIDLENS_POLICY_FILE"] = str(tmp_path / "policy.json")
    env["DROIDLENS_AUDIT_FILE"] = str(tmp_path / "audit.jsonl")
    return env


class DroidLensTest(unittest.TestCase):
    def test_unified_cli_help(self) -> None:
        result = run_cmd([str(DROIDLENS / "droidlens"), "help"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("droidlens doctor", result.stdout)
        self.assertIn("droidlens adb COMMAND", result.stdout)

    def test_app_resolver_reads_profile_and_gradle_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profile_dir = root / ".droidlens"
            profile_dir.mkdir()
            profile = profile_dir / "profile.json"
            profile.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "projectId": "fixture",
                        "app": {
                            "package": "com.example.profile",
                            "activity": ".MainActivity",
                            "variant": "debug",
                        },
                    }
                ),
                encoding="utf-8",
            )
            build = root / "build.gradle.kts"
            build.write_text(
                """
                plugins { id("com.android.application") }
                android {
                    namespace = "com.example"
                    defaultConfig { applicationId = "com.example.gradle" }
                    productFlavors {
                        create("demo") { applicationIdSuffix = ".demo" }
                    }
                }
                """,
                encoding="utf-8",
            )
            result = run_cmd(
                [
                    sys.executable,
                    str(DROIDLENS / "app_resolver.py"),
                    "--root",
                    str(root),
                    "--profile",
                    str(profile),
                ]
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            candidates = json.loads(result.stdout)["candidates"]
            packages = {candidate["package"] for candidate in candidates}
            self.assertIn("com.example.profile", packages)
            self.assertIn("com.example.gradle", packages)
            self.assertIn("com.example.gradle.demo", packages)

    def test_uixml_find_reports_scrollable_context(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            xml = Path(tmp) / "hierarchy.xml"
            xml.write_text(
                """
                <hierarchy>
                  <node class="androidx.recyclerview.widget.RecyclerView" scrollable="true" bounds="[0,100][1000,1600]">
                    <node text="Unique Row" class="android.widget.TextView" bounds="[20,120][400,200]" enabled="true" />
                  </node>
                </hierarchy>
                """,
                encoding="utf-8",
            )
            result = run_cmd(
                [
                    sys.executable,
                    str(DROIDLENS / "uixml.py"),
                    "find",
                    str(xml),
                    "--by",
                    "text",
                    "--value",
                    "Unique Row",
                    "--json",
                ]
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["total"], 1)
            self.assertTrue(payload["picked"]["inScrollable"])

    def test_pagetree_transition_route_and_alias_are_atomic(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            store = Path(tmp) / "page-tree.json"
            result = run_cmd(
                [
                    sys.executable,
                    str(DROIDLENS / "pagetree.py"),
                    "learn-transition",
                    str(store),
                    "bucket",
                    "Home",
                    "bucket",
                    "Settings",
                    "text:Settings",
                    "10",
                    "20",
                    "text",
                    "Settings",
                    "0",
                ]
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(Path(str(store) + ".lock").exists())

            route = run_cmd(
                [
                    sys.executable,
                    str(DROIDLENS / "pagetree.py"),
                    "route",
                    str(store),
                    "bucket",
                    "Home",
                    "Settings",
                ]
            )
            self.assertEqual(route.returncode, 0, route.stderr)
            self.assertEqual(route.stdout.strip(), "Home\ttext:Settings\t10\t20\tSettings\t0")

            alias = run_cmd(
                [
                    sys.executable,
                    str(DROIDLENS / "pagetree.py"),
                    "alias-page",
                    str(store),
                    "bucket",
                    "Start",
                    "Home",
                    "abc123",
                    "MainActivity",
                    '["Home", "Settings"]',
                ]
            )
            self.assertEqual(alias.returncode, 0, alias.stderr)
            self.assertEqual(alias.stdout.strip(), "1")

    def test_flow_jsonl_stdout_is_parseable_without_device_for_notes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            flow = Path(tmp) / "smoke.flow"
            out = Path(tmp) / "out"
            flow.write_text('note "done"\nsleep 0\n', encoding="utf-8")
            result = run_cmd([str(DROIDLENS / "flow.sh"), "--jsonl", str(out), str(flow)])
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = [line for line in result.stdout.splitlines() if line.strip()]
            self.assertGreaterEqual(len(lines), 4)
            for line in lines:
                json.loads(line)

    def test_snap_rejects_oversized_image_with_fake_adb_and_cwebp(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            fake_adb = tmp_path / "adb"
            fake_cwebp = tmp_path / "cwebp"
            out = tmp_path / "shot.webp"
            log = tmp_path / "adb.log"
            write_fake_adb(fake_adb)
            write_executable(
                fake_cwebp,
                r"""
                #!/usr/bin/env bash
                out=""
                while [[ $# -gt 0 ]]; do
                    if [[ "$1" == "-o" ]]; then
                        out="$2"
                        shift 2
                    else
                        shift
                    fi
                done
                printf 'not-a-real-webp-but-large-enough' > "$out"
                """,
            )
            env = os.environ.copy()
            env["DROIDLENS_ADB"] = str(fake_adb)
            env["FAKE_ADB_LOG"] = str(log)
            env["DROIDLENS_SERIAL"] = "fake-device"
            env["DROIDLENS_MAX_IMAGE_BYTES"] = "1"
            env["PATH"] = f"{tmp}{os.pathsep}{env.get('PATH', '')}"
            result = run_cmd(
                [str(DROIDLENS / "snap.sh"), str(out), "--thumb", "--json"],
                env=env,
            )
            self.assertEqual(result.returncode, 1)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["errorCode"], "image_too_large")
            self.assertTrue(payload["rejected"])

    def test_adbctl_swipe_uses_percent_coordinates(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            env = fake_adb_env(tmp_path)
            result = run_cmd(
                [str(DROIDLENS / "adbctl.sh"), "swipe", "50", "80", "50", "20", "300"],
                env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            log = (tmp_path / "adb.log").read_text(encoding="utf-8")
            self.assertIn("shell input swipe 500 1600 500 400 300", log)

    def test_adbctl_install_apk_is_managed_and_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            env = fake_adb_env(tmp_path)
            apk = tmp_path / "app-debug.apk"
            apk.write_bytes(b"fake apk")
            result = run_cmd(
                [str(DROIDLENS / "adbctl.sh"), "install-apk", str(apk), "--grant", "--json"],
                env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertTrue(payload["ok"])
            self.assertEqual(payload["action"], "install-apk")
            log = (tmp_path / "adb.log").read_text(encoding="utf-8")
            self.assertIn(f"install -r -g {apk}", log)

    def test_adbctl_start_and_force_stop_are_scoped_to_resolved_app(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            env = fake_adb_env(tmp_path)
            start = run_cmd(
                [str(DROIDLENS / "adbctl.sh"), "start-app", "--app", "com.example.app", "--fresh", "--json"],
                env=env,
            )
            self.assertEqual(start.returncode, 0, start.stderr)
            start_payload = json.loads(start.stdout)
            self.assertEqual(start_payload["package"], "com.example.app")

            stop = run_cmd(
                [str(DROIDLENS / "adbctl.sh"), "force-stop", "--app", "com.example.app", "--json"],
                env=env,
            )
            self.assertEqual(stop.returncode, 0, stop.stderr)
            stop_payload = json.loads(stop.stdout)
            self.assertEqual(stop_payload["package"], "com.example.app")

            log = (tmp_path / "adb.log").read_text(encoding="utf-8")
            self.assertIn("shell am force-stop com.example.app", log)
            self.assertIn("shell am start -n com.example.app/com.example.app.MainActivity", log)

    def test_adbctl_uninstall_is_blocked_without_dangerous_flag(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            env = fake_adb_env(tmp_path)
            result = run_cmd(
                [str(DROIDLENS / "adbctl.sh"), "uninstall", "--app", "com.example.app", "--json"],
                env=env,
            )
            self.assertEqual(result.returncode, 1)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["errorCode"], "approval_required")
            self.assertEqual(payload["action"], "uninstall")

    def test_adbctl_clear_data_is_blocked_without_dangerous_flag(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            env = fake_adb_env(tmp_path)
            result = run_cmd(
                [str(DROIDLENS / "adbctl.sh"), "clear-app-data", "--app", "com.example.app", "--json"],
                env=env,
            )
            self.assertEqual(result.returncode, 1)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["errorCode"], "approval_required")
            self.assertEqual(payload["action"], "clear-app-data")

    def test_policy_grant_allows_clear_data_once_and_audits(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            env = fake_adb_env(tmp_path)
            grant = run_cmd(
                [
                    str(DROIDLENS / "policy.sh"),
                    "grant",
                    "--action",
                    "clear-app-data",
                    "--app",
                    "com.example.app",
                    "--serial",
                    "fake-device",
                    "--ttl",
                    "30m",
                    "--max-runs",
                    "1",
                    "--reason",
                    "test reset",
                    "--json",
                ],
                env=env,
            )
            self.assertEqual(grant.returncode, 0, grant.stderr)
            grant_payload = json.loads(grant.stdout)
            self.assertTrue(grant_payload["ok"])
            self.assertEqual(grant_payload["grant"]["usedRuns"], 0)

            allowed = run_cmd(
                [str(DROIDLENS / "adbctl.sh"), "clear-app-data", "--app", "com.example.app", "--json"],
                env=env,
            )
            self.assertEqual(allowed.returncode, 0, allowed.stderr)
            self.assertEqual(json.loads(allowed.stdout)["package"], "com.example.app")

            blocked = run_cmd(
                [str(DROIDLENS / "adbctl.sh"), "clear-app-data", "--app", "com.example.app", "--json"],
                env=env,
            )
            self.assertEqual(blocked.returncode, 1)
            self.assertEqual(json.loads(blocked.stdout)["errorCode"], "approval_required")

            audit = (tmp_path / "audit.jsonl").read_text(encoding="utf-8")
            self.assertIn('"event": "grant"', audit)
            self.assertIn('"event": "allow"', audit)
            self.assertIn('"event": "deny"', audit)

    def test_adbctl_clear_data_is_scoped_after_dangerous_flag(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            env = fake_adb_env(tmp_path)
            env["DROIDLENS_ALLOW_DANGEROUS"] = "1"
            result = run_cmd(
                [str(DROIDLENS / "adbctl.sh"), "clear-app-data", "--app", "com.example.app", "--json"],
                env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["package"], "com.example.app")
            log = (tmp_path / "adb.log").read_text(encoding="utf-8")
            self.assertIn("shell pm clear com.example.app", log)

    def test_tap_meta_coordinate_conversion_is_precise(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            env = fake_adb_env(tmp_path)
            meta = tmp_path / "shot.meta.json"
            meta.write_text(
                json.dumps(
                    {
                        "image": str(tmp_path / "shot.webp"),
                        "mode": "--thumb",
                        "coordinateSystem": "device pixels from adb screencap/uiautomator bounds",
                        "deviceWidth": 1000,
                        "deviceHeight": 2000,
                        "imageWidth": 250,
                        "imageHeight": 500,
                        "scaleX": 4.0,
                        "scaleY": 4.0,
                    }
                ),
                encoding="utf-8",
            )
            result = run_cmd(
                [
                    str(DROIDLENS / "tap.sh"),
                    "--dry-run",
                    "--meta",
                    str(meta),
                    "125",
                    "250",
                    "--json",
                ],
                env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["x"], 500)
            self.assertEqual(payload["y"], 1000)


if __name__ == "__main__":
    unittest.main()
