# DroidLens

[Chinese](README.zh-CN.md)

DroidLens lets AI agents inspect, analyze, and operate Android app UIs through ADB.

It is designed for Claude Code, Codex, and other coding agents. Developers describe the result they want in natural language; the agent uses DroidLens as its Android UI toolchain.

```text
Analyze the current app UI.
Open the Settings screen and find UX issues.
Compare this screen with the design.
Run the UI regression. It may reset local test data if needed.
Reproduce why this button does not respond.
```

The command reference below is intended for maintainers, integrations, CI, and advanced troubleshooting. Normal usage should not require developers to run DroidLens commands manually.

## Quick Start

For normal agent usage, open Claude Code or Codex in an Android project and ask for the result:

```text
Use DroidLens to inspect the current app UI and report UX issues.
Use DroidLens to open Settings and verify the theme switch behavior.
Use DroidLens to reproduce the login button issue and collect evidence.
```

The agent should run preflight, resolve the app, inspect the device, navigate, collect screenshots/XML when needed, and report findings. Developers should not need to memorize DroidLens commands.

Optional: to verify that DroidLens is wired into the project, run a manual smoke test from the project root:

```bash
scripts/droidlens/droidlens doctor --ensure --json
scripts/droidlens/droidlens observe --app auto
scripts/droidlens/droidlens summary
scripts/droidlens/droidlens snap /tmp/droidlens-smoke.webp --thumb --json
```

## What It Does

- Resolves the target Android app from project metadata, Gradle config, or ADB launcher data.
- Captures compact WebP screenshots and uiautomator XML.
- Summarizes visible UI text for fast screen inspection.
- Taps by text, content description, resource id, XML bounds, or screenshot metadata.
- Learns page routes and reuses them across sessions with device/app-version buckets.
- Recovers from arbitrary device state, including launcher, overlays, and unknown app pages.
- Provides an agent-oriented ADB command layer.
- Supports scoped approvals for AFK workflows.
- Writes structured failure bundles for debugging.

## Development Tasks

DroidLens is useful for device-side tasks that need UI evidence:

| Task | What DroidLens Collects | Typical Output |
|---|---|---|
| UI inspection | summary, XML, screenshot | prioritized UX findings |
| Bug reproduction | action log, terminal screen, failure bundle | reproducible steps, expected/actual result |
| Design comparison | target screen evidence, screenshots | mismatch list with severity |
| Regression flow | JSONL events, screenshots, notes | pass/fail summary and failed step evidence |
| Accessibility check | visible text, content-desc, XML bounds | missing labels, ambiguous controls, tap target risks |
| Navigation smoke test | learned path, observed pages | route status and stale-edge report |
| Release sanity check | app launch, key screens, dialogs | ship/block recommendation with evidence |

## Example Agent Reports

Use short evidence-led reports. Prefer UI text, XML selectors, and file paths over long screenshot descriptions.

### UI Inspection

```markdown
## Findings

1. Severity: High
   Screen: Settings
   Evidence: `Current theme` row opens a dialog, but the selected value is not exposed in visible text.
   Impact: Users cannot confirm the active theme after returning to Settings.
   Recommendation: Show the current value in the row subtitle or trailing text.

2. Severity: Medium
   Screen: Settings
   Evidence: The `Scan library` action is below the first viewport and has no persistent progress state.
   Impact: Long scans can look stalled after navigation.
   Recommendation: Surface scan state in the row and notification area.

## Evidence

- Summary: `/tmp/droidlens-settings/summary.json`
- Screenshot: `/tmp/droidlens-settings/screen.webp`
- XML: `/tmp/droidlens-settings/hierarchy.xml`
```

### Bug Reproduction

```markdown
## Reproduction

Target: Settings -> Library sync
Result: Reproduced

Steps:
1. Launched the app from a clean foreground state.
2. Opened Settings.
3. Tapped `Sync now`.

Expected:
The app starts sync or shows a recoverable error.

Actual:
The button stays enabled, no progress text appears, and no snackbar/dialog is shown.

Evidence:
- Last screen: `/tmp/droidlens-sync-failure/screen.webp`
- UI summary: `/tmp/droidlens-sync-failure/summary.json`
- Action log: `/tmp/droidlens-sync-failure/events.jsonl`
```

### Regression Result

```markdown
## Regression Result

Flow: `.droidlens/flows/settings.flow`
Status: Failed
Failed step: `wait-text "Dark" 6`

What happened:
The theme dialog opened, but `Dark` was not visible in the current viewport.

Likely cause:
The dialog content or theme labels changed, so the flow selector is stale.

Next action:
Inspect the dialog XML and update the flow selector to the current text or content description.
```

## Supported Environments

| Environment | Status |
|---|---|
| macOS Bash/Zsh | Tested locally for v0.1.0 |
| Linux Bash | Supported target, not manually tested for v0.1.0 |
| Windows Git Bash / MSYS2 / Cygwin | Supported target, not manually tested for v0.1.0 |
| WSL | Supported target, not manually tested for v0.1.0 |
| Native PowerShell | Not supported in v0.1.0 |

Minimum requirements:

- Android SDK platform-tools / `adb`
- Bash
- `python3`
- One authorized Android device or emulator
- Optional but recommended: `cwebp` for default WebP screenshots
- Optional: `pngquant` for PNG compression

## Install

DroidLens is designed to run from an Android project root. The default and recommended layout is:

```text
scripts/droidlens/
  droidlens
  *.sh
  *.py
  LICENSE
  docs/
  flows/
```

This repository can live anywhere as the upstream source. To use DroidLens in an Android app repository, expose the reusable script directory at `scripts/droidlens/`, then run commands from the Android project root.

Install DroidLens into an Android project at this path:

```text
scripts/droidlens/
```

### Option A: copy the scripts

This is the simplest setup when you want to vendor a snapshot into one Android project:

```bash
mkdir -p scripts
cp -R /path/to/DroidLens/scripts/droidlens scripts/droidlens
```

### Option B: use a Git submodule

Use this when you want the Android project to track DroidLens as an upstream dependency:

```bash
git submodule add https://github.com/GuangsenWang/DroidLens.git third_party/DroidLens
mkdir -p scripts
ln -s ../third_party/DroidLens/scripts/droidlens scripts/droidlens
git add .gitmodules third_party/DroidLens scripts/droidlens
git commit -m "Add DroidLens"
```

Then clone the Android project with submodules:

```bash
git clone --recurse-submodules <your-android-project>
```

Or initialize submodules after cloning:

```bash
git submodule update --init --recursive
```

To update DroidLens later:

```bash
git submodule update --remote third_party/DroidLens
git add third_party/DroidLens
git commit -m "Update DroidLens"
```

The submodule should contain the full DroidLens repository. Keep the runtime entry exposed at `scripts/droidlens/`; do not add the full repository directly at `scripts/droidlens`, or the command path becomes nested.

On Windows, symlink creation may require Developer Mode or administrator privileges. If symlinks are unavailable, keep the submodule under `third_party/DroidLens` and copy `third_party/DroidLens/scripts/droidlens` into `scripts/droidlens` when updating.

The Claude and Codex skills, command examples, and script documentation all assume this relative path:

```bash
scripts/droidlens/droidlens
```

Keep this path stable. If you install DroidLens somewhere else, update the project skills and any saved flow documentation before using it.

For Claude Code / Codex usage, the agent should run setup automatically. The command below is only for optional post-install verification or troubleshooting:

```bash
scripts/droidlens/droidlens doctor --ensure --json
```

`doctor --ensure` detects local tools, chooses the authorized device when possible, resolves the app, writes `.droidlens/env.sh`, and keeps the device awake with `adb shell svc power stayon true`.

If a required tool is missing:

```bash
scripts/droidlens/droidlens doctor --ensure --install-missing
```

## Skill Setup

DroidLens ships with agent skill templates:

```text
.claude/skills/droidlens/
.codex/skills/droidlens/
```

To enable them in an Android project:

1. Copy `scripts/droidlens/` into the Android project root.
2. Copy `.claude/skills/droidlens/` into the Android project's `.claude/skills/droidlens/` directory when using Claude Code.
3. Copy `.codex/skills/droidlens/` into the Android project's `.codex/skills/droidlens/` directory when using Codex.
4. Open Claude Code or Codex from the Android project root.
5. Ask for the UI outcome in natural language, for example:

```text
Use DroidLens to inspect the current app UI and report UX issues with evidence.
```

The skill tells the agent to use `scripts/droidlens/droidlens`, run preflight, prefer XML/summary before screenshots, avoid hardcoded coordinates, and ask only for bounded dangerous-action approval when needed.

## Natural-Language Usage

In Claude Code or Codex, ask for the outcome:

```text
Analyze the current UI.
Check whether the Settings screen matches the design.
Run the saved regression flow.
Investigate why the delete dialog behaves incorrectly.
```

The agent should:

1. Run DroidLens preflight.
2. Observe the current device/app state.
3. Navigate, inspect, tap, or run flows as needed.
4. Use summaries and XML before reading screenshots.
5. Ask only for physical device actions, missing credentials, ambiguous targets, or plain yes/no dangerous-action approval.
6. Report findings with concrete UI evidence.

## Safety Model

DroidLens provides a controlled ADB interface. Routine commands can run directly; destructive actions require approval.

Dangerous examples:

- Clear app data
- Uninstall the app
- Tap destructive or privileged UI such as delete, pay, allow, grant, uninstall

For AFK runs, a user can approve intent in natural language, and the agent creates the task-scoped approval.

Example:

```text
Run the Settings regression. To complete the test, you may reset the target app's local data up to 3 times. Do not uninstall the app.
```

Manual equivalent:

```bash
scripts/droidlens/droidlens policy grant \
  --action clear-app-data \
  --app auto \
  --ttl 2h \
  --max-runs 3 \
  --reason "AFK regression reset" \
  --json
```

Approvals are bound to action, app, device, expiration, and run count. Every grant, allow, deny, and revoke event is written to `.droidlens/audit.jsonl`.

`DROIDLENS_ALLOW_DANGEROUS=1` exists only as a single-command escape hatch. It should not be exported or persisted.

## Project Memory

DroidLens separates reusable tooling from project and user memory:

```text
scripts/droidlens/          reusable DroidLens engine
.droidlens/profile.json     project app profile, safe to commit when generic
.droidlens/env.sh           generated local environment, do not commit
.droidlens/flows/           project-specific regression flows
.droidlens/policy.json      local dangerous-action grants, do not commit
.droidlens/audit.jsonl      local dangerous-action audit log, do not commit
~/.droidlens/page-tree.json user route memory across sessions
```

See [scripts/droidlens/docs/schema.md](scripts/droidlens/docs/schema.md) for data formats.

## Command Reference

Prefer the unified entrypoint:

```bash
scripts/droidlens/droidlens doctor --ensure --json
scripts/droidlens/droidlens observe --app auto
scripts/droidlens/droidlens summary
scripts/droidlens/droidlens snap /tmp/screen.webp --thumb --json
scripts/droidlens/droidlens dump /tmp/state --thumb --json
scripts/droidlens/droidlens tap "Settings"
scripts/droidlens/droidlens goto --app auto "Settings"
scripts/droidlens/droidlens flow --jsonl /tmp/out .droidlens/flows/regression.flow
scripts/droidlens/droidlens adb current
scripts/droidlens/droidlens policy list --json
```

### App Resolution

```bash
scripts/droidlens/droidlens app resolve --app auto --json
scripts/droidlens/droidlens app launch --app auto
scripts/droidlens/droidlens app launch --app auto --fresh
```

`--app auto` resolves in this order:

1. CLI or environment app spec
2. `.droidlens/profile.json`
3. Gradle Android application id and suffixes
4. ADB launcher activity

### Screenshots And XML

```bash
scripts/droidlens/droidlens snap /tmp/screen.webp --thumb --json
scripts/droidlens/droidlens snap /tmp/screen.webp --ai --json
scripts/droidlens/droidlens dump /tmp/state --thumb --json
scripts/droidlens/droidlens summary
```

Screenshot modes:

- `--thumb`: 360px-wide WebP, default for fast AI inspection
- `--ai`: 540px-wide WebP for more detail
- `--lossy`: original-size WebP
- `--png`: compressed PNG
- `--raw`: original PNG

Each screenshot writes a `.meta.json` sidecar with device and image dimensions. Agents use it to map compressed-image coordinates back to device coordinates.

### Tapping

```bash
scripts/droidlens/droidlens tap "Visible Text"
scripts/droidlens/droidlens tap --desc "More options"
scripts/droidlens/droidlens tap --id "com.example:id/save"
scripts/droidlens/droidlens tap --contains "Item"
scripts/droidlens/droidlens tap --re "Item.*"
scripts/droidlens/droidlens tap --xml /tmp/state.xml "Save"
scripts/droidlens/droidlens tap --meta /tmp/screen.meta.json 180 650 --json
```

Prefer semantic selectors and XML bounds. Use screenshot coordinates only with `.meta.json`.

### Flows

Flows are small project-specific scripts stored in `.droidlens/flows/`:

```text
launch auto
wait-text "Home" 6
tap-desc "Settings"
wait-text "Settings"
snap
note "Settings screen reached"
```

Run:

```bash
scripts/droidlens/droidlens flow --jsonl /tmp/droidlens-run .droidlens/flows/settings.flow
```

Common flow commands:

```text
launch auto
wait-text "Text" [seconds]
tap "Text"
tap-desc "content-desc"
tap-nth N "Text"
tap-xy X Y
key BACK
sleep 2
snap
note "free text"
```

### Safe ADB Wrapper

```bash
scripts/droidlens/droidlens adb devices
scripts/droidlens/droidlens adb current
scripts/droidlens/droidlens adb wm
scripts/droidlens/droidlens adb density
scripts/droidlens/droidlens adb wake
scripts/droidlens/droidlens adb back
scripts/droidlens/droidlens adb home
scripts/droidlens/droidlens adb tap 50 80
scripts/droidlens/droidlens adb swipe 50 80 50 20 300
scripts/droidlens/droidlens adb install-apk app-debug.apk --json
scripts/droidlens/droidlens adb start-app --app auto --fresh --json
scripts/droidlens/droidlens adb force-stop --app auto --json
```

See [scripts/droidlens/docs/ai-adb.md](scripts/droidlens/docs/ai-adb.md) for the ADB safety boundary.

## Environment Variables

| Variable | Purpose |
|---|---|
| `DROIDLENS_ADB` | Force a specific adb path |
| `DROIDLENS_SERIAL` | Select a device when multiple devices are connected |
| `DROIDLENS_APP` | Default app spec: `auto`, `PKG`, or `PKG/.Activity` |
| `DROIDLENS_APP_VARIANT` | Select a Gradle flavor/build variant |
| `DROIDLENS_PROFILE` | Profile path, default `<project>/.droidlens/profile.json` |
| `DROIDLENS_PROJECT_ROOT` | Project root override |
| `DROIDLENS_STAY_AWAKE=0` | Disable automatic `adb shell svc power stayon true` |
| `DROIDLENS_MAX_IMAGE_BYTES=256000` | Reject oversized non-raw screenshots |
| `DROIDLENS_ALLOW_LARGE_IMAGE=1` | Allow oversized screenshots intentionally |
| `DROIDLENS_OUTPUT_DIR=/tmp` | Failure bundle root |
| `DROIDLENS_REDACT_TEXT=1` | Avoid writing summary text in failure bundles |
| `DROIDLENS_POLICY_FILE` | Policy file path |
| `DROIDLENS_AUDIT_FILE` | Audit log path |

## Failure Bundles

Structured failures return `errorCode` and often a `bundle` directory:

```text
reason.json
observe.json
screen.webp
screen.meta.json
hierarchy.xml
summary.json
*.err / *.log
```

Agents should inspect the bundle before retrying.

Common error codes:

```text
adb_not_found
device_not_authorized
multiple_devices
app_not_installed
app_resolve_ambiguous
screencap_failed
xml_dump_failed
tap_target_not_found
approval_required
meta_device_mismatch
permission_dialog
crash_or_anr_dialog
external_chooser
unknown_page
route_not_found
edge_stale
terminal_mismatch
```

## Development

Before submitting changes:

```bash
bash -n scripts/droidlens/*.sh scripts/droidlens/droidlens tests/droidlens/run.sh
shellcheck -x -P scripts/droidlens scripts/droidlens/*.sh scripts/droidlens/droidlens tests/droidlens/run.sh
python3 -m py_compile scripts/droidlens/*.py
tests/droidlens/run.sh
```

The test suite uses fake ADB where possible and does not require a physical device.

## License

DroidLens is licensed under the [Apache License 2.0](LICENSE).

Copyright 2026 Guangsen Wang.
