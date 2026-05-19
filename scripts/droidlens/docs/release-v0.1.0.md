# DroidLens v0.1.0 Release Notes

`droidlens` is an experimental Android UI debugging workflow for AI agents and developers. It wraps ADB, screenshots, UIAutomator XML, selector-based tapping, route memory, and structured failure bundles into a repeatable workflow that can be copied into Android projects.

## Highlights

- Project-agnostic app resolution through profile, Gradle, and ADB launcher discovery.
- `doctor --ensure --json` preflight for local tooling and connected devices.
- Low-token screenshot defaults with WebP thumbnails and hard image-size limits.
- Accurate coordinate conversion through screenshot `.meta.json` sidecars.
- XML selectors for text, content-desc, resource-id, class, regex, and contains matching.
- Page-tree route memory keyed by app package, version code, screen size, and density.
- `observe` and `goto` for starting from arbitrary app/system state.
- Strict JSON/JSONL contracts for automation.
- Risk-tiered `droidlens adb` command set for AI-safe device interaction.
- Apache-2.0 license for open-source distribution.
- Tests and CI for no-device logic.

## Support Matrix

| Platform | Status |
|---|---|
| macOS Bash/Zsh | Supported target |
| Linux Bash | Supported target |
| Windows Git Bash / MSYS2 / Cygwin | Supported target |
| WSL | Supported target |
| Native PowerShell | Not supported in v0.1.0 |

## Known Limits

- Real-device validation is still required per project and device farm.
- Native PowerShell wrappers are not provided.
- Foldables, multi-window, and tablet-specific layout semantics are not a v0.1.0 target.
- Page-tree schemas are versioned, but migrations beyond version 1 are not needed yet.

## Recommended First Run

```bash
cd scripts/droidlens
./droidlens doctor --ensure --json
./droidlens observe --app auto
./droidlens snap /tmp/droidlens-smoke.webp --thumb --json
```

## Upgrade Notes

This is the first release. For future upgrades, preserve:

- project `.droidlens/profile.json`
- project `.droidlens/flows/`
- user `~/.droidlens/page-tree.json`

Do not commit generated `.droidlens/env.sh`.
