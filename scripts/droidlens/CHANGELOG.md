# Changelog

## 0.1.0 - 2026-05-19

Initial experimental release.

### Added

- Unified `droidlens` CLI wrapper.
- Environment doctor for ADB, SDK, Python, WebP, PNG tooling, device selection, and app resolution.
- Token-friendly screenshot capture with WebP thumbnail mode and max-byte guard.
- XML-driven UI summary and selector-based tapping.
- Screenshot metadata sidecars for accurate compressed-image-to-device coordinate conversion.
- JSON and JSONL output contracts for automation.
- Page-tree memory with per app/version/resolution/density buckets.
- Locked page-tree writes and atomic learned transitions.
- `observe` and `goto` workflows for recovering from arbitrary device state.
- Risk-tiered `droidlens adb` wrapper:
  - safe UI/device operations
  - managed app lifecycle and APK install commands
  - dangerous operations blocked by default
- Unit tests with fake ADB/CWebP coverage.
- GitHub Actions workflow for Bash syntax, ShellCheck, Python compile, and unit tests.
- Apache-2.0 license.
- README task matrix and agent report templates.

### Stability

- `0.1.0` is experimental.
- Documented commands and documented JSON fields are intended to be stable within the `0.1.x` line.
- Undocumented fields and internal script implementation details may change.
