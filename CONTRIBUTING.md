# Contributing To DroidLens

Thanks for improving DroidLens.

## Development Setup

Run checks from the repository root:

```bash
bash -n scripts/droidlens/*.sh scripts/droidlens/droidlens tests/droidlens/run.sh
shellcheck -x -P scripts/droidlens scripts/droidlens/*.sh scripts/droidlens/droidlens tests/droidlens/run.sh
python3 -m py_compile scripts/droidlens/*.py
tests/droidlens/run.sh
```

The unit tests use fake ADB where possible and should not require a physical device.

## Compatibility

DroidLens targets:

- macOS Bash/Zsh
- Linux Bash
- Windows Git Bash / MSYS2 / Cygwin
- WSL

Native PowerShell wrappers are not part of v0.1.x.

## Engineering Rules

- Keep the reusable engine under `scripts/droidlens/`.
- Do not hardcode app package names, screen sizes, densities, or coordinates.
- Prefer XML selectors, content descriptions, resource ids, and screenshot metadata over raw pixel guesses.
- Keep source comments and script help text in English.
- Keep Chinese user-facing docs in `README.zh-CN.md`.
- Dangerous operations must go through DroidLens policy grants.
- Do not commit generated local files such as `.droidlens/env.sh`, `.droidlens/policy.json`, or `.droidlens/audit.jsonl`.

## Documentation

Update these files when behavior changes:

- `README.md`
- `README.zh-CN.md`
- `scripts/droidlens/docs/schema.md`
- `scripts/droidlens/docs/ai-adb.md`
- `CHANGELOG.md`

## License

By contributing, you agree that your contributions are licensed under the Apache License 2.0.
