# Quick on-device testing (no GitHub CI)

Use this for fast iteration of small C/Obj-C prototypes on the iPhone:

```
sh Scripts/local-quick-test.sh Tests/LocalQuick/quicktest.m
```

The script:
- compiles with procursus `clang` against SDK `iphoneos16.4` (`-target arm64-apple-ios16.0`);
- signs via `ldid` using `Packaging/Apelin.entitlements`;
- runs the binary immediately.

Notes:
- Requires procursus clang (already installed on this device) and SDK `iphoneos16.4`;
- Only for isolated prototypes, not for full Apelin app/tweak packages (those still go through `apelin_project_build`/CI);
- For real validation, run `apelin_project_build` or CI afterwards.
