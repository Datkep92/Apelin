# 07 Build và đóng gói

## Local tooling
- `Makefile`:
  - `make harness`: tests.
  - `make check`: core validation first, checklist check script.
  - `make deb-all`: roothide/rootless package generation.
  - `make install DEVICE_HOST=... FLAVOR=...`: install for testing.
- Main build script: `Scripts/package-deb.sh`.
- Version: `Configuration/Version.xcconfig` and `apply-version.sh`.
- SDK/toolchain bindings are in `apelin-project.json` (external workspace).
- CI release artifacts built per SHA.

## Checks
- `make check` scope includes script checks shell deletes, launchd path, access, stale strings, catalog, etc.
- Release notes must be written to `Documents/Releases/<version>.md`.
- App icon generated from icon source.
- Licenses collection required.
- Rpath/abs path checks.

## Packaging rules
- `DebPackageWriter.controlCompression = .gzip`.
- managed package rules: no overwriting externally installed package, no dangerous essential packages, etc.
- `postinst` must never run on agent terminal install (bootout killer).
- App data folder is created safely per level (no `mkdir -p` root).
- roothide launchd paths must use `@PREFIX@`/`@ROOTFS@`.

## Invariants
- use architectures explicitly.
- packaging fields must be final for distribution, checked via `apelin_project_check_distribution`.
- same identifiers for debug/release; never change identifier once published.
- no manual `.deb`.
- release publish only release builds and explicit consent.
