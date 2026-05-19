---
name: droidlens
description: Use DroidLens for Android device UI inspection, screenshot analysis, design/spec comparison, end-to-end UI regression, accessibility checks, and UI bug reproduction. Trigger whenever a task needs an AI agent to observe or operate a connected Android device/emulator. DroidLens is project-agnostic: app resolution comes from `.droidlens/profile.json`, Gradle, or ADB launcher metadata; screenshots default to token-friendly WebP thumbnails; selectors, XML bounds, and screenshot sidecar metadata prevent hardcoded device coordinates.
metadata:
  keywords:
    - Android UI debugging
    - ADB
    - UI inspection
    - screenshot analysis
    - design comparison
    - end-to-end regression
    - accessibility
    - uiautomator
---

# DroidLens

DroidLens is a project-agnostic Android UI workflow for AI agents. It combines ADB, uiautomator XML, compressed screenshots, selector-based tapping, page-tree memory, and failure bundles.

Use the tool in the current repository at `scripts/droidlens/`. Project-specific memory lives in `.droidlens/`; user/device route memory lives in `~/.droidlens/`.

## User Experience Contract

The developer should not need to type DroidLens commands or remember DroidLens-specific wording. Treat DroidLens as an agent-owned implementation detail:

- When the user asks in natural language, run the needed DroidLens commands yourself.
- Do not ask the user to copy/paste Bash unless the host environment cannot execute commands.
- Do not explain the CLI unless the user asks how DroidLens works.
- Ask the user only for the smallest product-level decision needed: physical/device action, missing credential, ambiguous target, or a plain yes/no dangerous-action approval.
- Never require the user to name actions like `clear-app-data`, `tap-dangerous`, `policy grant`, TTL, or max-runs. Infer a conservative scoped policy from the task.
- If the user says a task may reset data, reinstall, delete test data, accept dialogs, or otherwise allows risky setup, create the narrow policy yourself and continue.
- If the user says a broad phrase like "do whatever is needed", choose the minimum policy needed for the current goal; do not grant unrelated actions.

User prompts that should trigger this skill:

```text
分析一下当前 UI
打开 app 看看 Settings 页面
对比这个页面和设计稿
跑一下 UI 回归，允许本次任务清数据最多 3 次
复现这个按钮点了没反应的问题
```

Good approval question style:

```text
为了完成这次回归，我需要重置目标 app 的本地数据，最多 3 次。是否允许？
```

Bad approval question style:

```text
请运行 droidlens policy grant --action clear-app-data ...
```

## When To Use

Use DroidLens when the task requires any device-side UI evidence:

- verify a UI change on a connected Android device or emulator
- compare an Android screen against a design/spec
- reproduce a UI bug by operating the app
- run an end-to-end regression path and collect screenshots
- inspect accessibility from uiautomator XML
- navigate to a known screen using learned paths

Do not use DroidLens for purely static code review or build-only tasks unless the user asks for device verification.

## Fixed Entry Flow

Always start from the repository root:

```bash
scripts/droidlens/droidlens doctor --ensure --json
scripts/droidlens/droidlens observe --app auto
```

Then choose the next command from `observe.recommendedAction`:

| State | Preferred action |
|---|---|
| `known_app_page` | `goto --app auto "Target"` or inspect current UI |
| `outside_target_app` / `launcher` | `goto --app auto "Target"` or `app launch --app auto` |
| `unknown_app_page` | inspect with `summary`/`dump`, then learn or recover |
| `system_overlay` | use `adb back` once, then observe again |
| `permission_dialog` / `external_chooser` | stop and ask unless the user explicitly authorized that choice |
| `crash_or_anr_dialog` | stop, collect/report the failure bundle |

Prefer the unified CLI:

```bash
scripts/droidlens/droidlens snap /tmp/screen.webp --thumb --json
scripts/droidlens/droidlens dump /tmp/state --thumb --json
scripts/droidlens/droidlens summary
scripts/droidlens/droidlens tap "Visible Text"
scripts/droidlens/droidlens goto --app auto "Settings"
scripts/droidlens/droidlens flow --jsonl /tmp/out .droidlens/flows/regression.flow
scripts/droidlens/droidlens adb current
```

## Cost Rules

- Prefer `summary` and XML text before reading images.
- Use `--thumb` WebP for normal screenshots; use `--ai` only when detail is needed.
- Avoid full-size PNG unless the task explicitly needs pixel-level evidence.
- Reuse existing XML with `tap --xml FILE` instead of dumping repeatedly.
- For long regressions, prefer `goto` or `flow --jsonl` and capture only terminal or failing screens.
- Let `doctor --ensure` / `flow` keep the device awake automatically; do not ask the user to run `adb shell svc power stayon true`.

## Reporting Templates

Keep reports short and evidence-led. Prefer visible UI text, selectors, XML facts, and file paths over broad screenshot narration.

### UI Inspection

```markdown
## Findings

1. Severity: High|Medium|Low
   Screen: <screen name>
   Evidence: <visible text, selector, XML fact, or screenshot path>
   Impact: <user-facing impact>
   Recommendation: <specific change>

## Evidence

- Summary: <path>
- Screenshot: <path>
- XML: <path>
```

### Bug Reproduction

```markdown
## Reproduction

Target: <screen or flow>
Result: Reproduced|Not reproduced|Blocked

Steps:
1. <step>
2. <step>

Expected:
<expected behavior>

Actual:
<actual behavior>

Evidence:
- Last screen: <path>
- UI summary: <path>
- Action log: <path>
```

### Regression Result

```markdown
## Regression Result

Flow: <flow path>
Status: Passed|Failed|Blocked
Failed step: <step, if any>

What happened:
<short explanation>

Likely cause:
<selector drift, app bug, device state, permission, etc.>

Next action:
<specific fix or investigation>
```

## Coordinate Rules

- Prefer semantic selectors: `tap "Text"`, `tap --desc "Description"`, `tap --id "resource/id"`.
- XML `bounds` are device-coordinate truth; use them over visual estimates.
- If tapping from a compressed screenshot, use the sidecar metadata from `snap`:

```bash
scripts/droidlens/droidlens tap --meta /tmp/screen.meta.json X Y --json
```

- Never hardcode screen size, density, orientation, or package names. Let DroidLens resolve device metrics and app metadata.

## App And Memory Rules

- Do not embed an app package/activity into the tool or skill.
- Let `--app auto` resolve from CLI/env, `.droidlens/profile.json`, Gradle config, or ADB launcher data.
- Store project-specific flows in `.droidlens/flows/`.
- Use `learn page-name`, `learn tap`, and `goto` to build reusable page-tree paths.
- Learned route buckets include package/version/display/density data, so route memory is separated across apps and devices.

## ADB Safety

Use `droidlens adb ...` instead of raw `adb` for routine UI work.

Safe defaults include:

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
```

Managed app lifecycle commands are allowed when relevant:

```bash
scripts/droidlens/droidlens adb install-apk app-debug.apk --json
scripts/droidlens/droidlens adb start-app --app auto --fresh --json
scripts/droidlens/droidlens adb force-stop --app auto --json
```

Dangerous commands, app data clearing, destructive taps, permission grants, purchases, deletes, and uninstall operations require a DroidLens policy grant. Do not bypass this with raw adb.

```bash
scripts/droidlens/droidlens policy grant --action clear-app-data --app auto --ttl 30m --max-runs 1 --reason "AFK regression reset" --json
scripts/droidlens/droidlens adb clear-app-data --app auto --json
```

If a dangerous command returns `approval_required`, stop. In an interactive session, explain the exact action, target app, and risk, then ask for approval in natural language. If the user approves, run the narrow `policy grant` yourself and retry the command. In an AFK session, use any policy already granted by the user; if missing, stop and report the exact approval needed. `DROIDLENS_ALLOW_DANGEROUS=1` is only a single-command escape hatch when the user explicitly asks for that exact command; never export or persist it.

## Failure Handling

When a command returns JSON with `errorCode` and `bundle`, read the bundle before retrying:

```text
reason.json
observe.json
hierarchy.xml
summary.json
screen.webp
screen.meta.json
```

Read `reason.json` and `summary.json` first. Read `screen.webp` only if text/XML evidence is insufficient.

Common next steps:

- `adb_not_found`: run `doctor --ensure --install-missing` or report the install command.
- `multiple_devices`: set `DROIDLENS_SERIAL`.
- `app_resolve_ambiguous`: set `DROIDLENS_APP_VARIANT` or pass `--app`.
- `approval_required`: ask for or report a bounded `droidlens policy grant`; do not retry blindly.
- `tap_target_not_found`: dump/summary, inspect actual text/desc/id, then retry by selector.
- `route_not_found`: learn a path with `learn page-name` and `learn tap`.
- `edge_stale`: UI changed; inspect current screen and relearn that edge.

## References

- Full user/tool docs: `scripts/droidlens/README.md`
- ADB policy and command boundaries: `scripts/droidlens/docs/ai-adb.md`
- Data schemas: `scripts/droidlens/docs/schema.md`
- Example flow DSL: `scripts/droidlens/flows/example.flow`
