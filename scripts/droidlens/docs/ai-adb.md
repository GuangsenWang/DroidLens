# AI ADB Usage

AI agents should prefer `droidlens` commands over raw `adb`.

For Claude Code / Codex usage, DroidLens commands are agent-owned implementation details. The developer should be able to ask in natural language, for example "analyze the current UI" or "run this UI regression"; the agent runs the commands, summarizes evidence, and only asks the developer for physical device actions or plain yes/no dangerous-action approval. Do not require users to remember DroidLens commands, action names, TTLs, or policy syntax.

Raw `adb` is powerful enough to install/uninstall apps, grant permissions, delete data, change system settings, or trigger irreversible UI actions. For repeatable UI debugging, the stable interface is:

```bash
scripts/droidlens/droidlens adb COMMAND [args...]
```

## Risk Tiers

`adbctl.sh` is intentionally tiered:

- **Safe**: low-risk UI/device observation and interaction. AI can run these directly.
- **Managed**: common test-lifecycle actions with scoped parameters and structured output.
- **Dangerous**: destructive or broad actions. These are blocked unless a bounded DroidLens policy grant exists, or the user explicitly uses the single-command `DROIDLENS_ALLOW_DANGEROUS=1` escape hatch.

## Safe Commands

```bash
droidlens adb devices       # list authorized devices
droidlens adb current       # print current package/activity
droidlens adb wm            # print active display size
droidlens adb density       # print display density
droidlens adb wake          # wake and swipe unlock using screen-relative coordinates
droidlens adb back          # KEYCODE_BACK
droidlens adb home          # KEYCODE_HOME
droidlens adb key BACK      # bounded keyevent wrapper
droidlens adb text "query"  # input escaped text
droidlens adb tap 50 80     # tap by screen percent, not hardcoded pixels
droidlens adb swipe 50 80 50 20 300  # swipe by screen percent
```

`tap` and `swipe` use percentages so they work across devices and orientations:

```text
swipe FROM_X% FROM_Y% TO_X% TO_Y% [DURATION_MS]
```

## Managed Commands

```bash
droidlens adb install-apk app/build/outputs/apk/debug/app-debug.apk --json
droidlens adb install-apk app.apk --grant --downgrade --json
droidlens adb start-app --app auto --fresh --json
droidlens adb force-stop --app auto --json
```

Managed commands may change app state, but they are useful for UI regression workflows. They are intentionally scoped:

- `install-apk` only accepts existing `.apk` files and defaults to `adb install -r`.
- `start-app` and `force-stop` resolve the app through `.droidlens/profile.json`, Gradle, or explicit `--app`.
- JSON output is available for automation.

## Dangerous Commands

```bash
droidlens adb clear-app-data --app auto --json
droidlens adb uninstall --app auto --json
```

Dangerous commands are blocked by default and return `approval_required` JSON when no grant exists. `clear-app-data` is dangerous because it deletes app-local state, databases, preferences, caches, login/session data, and test fixtures.

For AFK automation, the user should pre-authorize a narrow policy:

```bash
droidlens policy grant \
  --action clear-app-data \
  --app auto \
  --ttl 2h \
  --max-runs 3 \
  --reason "AFK regression reset" \
  --json
```

Policy grants are bound to action, resolved app package, device serial, TTL, and max-runs. Dangerous commands consume a grant and write `.droidlens/audit.jsonl`.

`DROIDLENS_ALLOW_DANGEROUS=1` remains available only as a single-command escape hatch:

```bash
DROIDLENS_ALLOW_DANGEROUS=1 droidlens adb clear-app-data --app auto --json
```

AI agents must not export or persist `DROIDLENS_ALLOW_DANGEROUS=1`.

## Rules For Agents

- Start every session with `droidlens doctor --ensure --json`.
- Use `droidlens observe --app auto` before deciding whether to launch, recover, inspect, or navigate.
- Use `droidlens tap` selectors before coordinate taps.
- Use `droidlens snap --thumb --json` or `droidlens dump --thumb --json`; avoid raw full-size screenshots.
- Use `droidlens adb` for device state, percent-based gestures, app lifecycle, and APK installation.
- Do not run raw `adb shell pm`, `adb shell settings`, `adb uninstall`, `adb install`, `adb shell rm`, or permission-changing commands as part of automated UI exploration.
- If a task truly requires destructive or privileged ADB operations, use an existing policy grant. If none exists, return/ask for a `droidlens policy grant ...` command instead of bypassing the tool.
- In interactive sessions, explain the `approval_required` risk and wait for the user to grant or deny.
- In AFK sessions, stop on `approval_required` and report the missing grant; do not wait for stdin.

## Why Not Expose All ADB?

The tool is meant to be safe for generic Android projects and arbitrary devices. A narrow wrapper keeps the AI workflow stable:

- fewer command variants to remember
- consistent serial and timeout handling through `lib.sh`
- fewer device-specific side effects
- easier CI and documentation
- clearer security boundary for open-source users
