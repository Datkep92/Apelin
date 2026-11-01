# 06 Packages (Packages/)

| Package | Role |
|---|---|
| `ApelinKit` | central protocol operation definitions, shared types |
| `ApelinProtocol` | envelope and transport wire definition |
| `ApelinAgent` | agent session/context/tools/prompt |
| `ApelinDiagnostics` | diagnostics worker library |
| `ApelinFormats` | formats, code sign, shared format libs |
| `ApelinToolchain` | toolchain SDK, environment package, filtering |
| `ApelinToolHost` | toolchain's host/testing layer (`ApelinToolCore`) |
| `Runestone` | vendored text editor dependency |
| `Package.resolved` | Swift PM pins |

## Boundaries/tests

- `Apelind` only links approved system libs; broad harness validation.
- tests in `Packages/*/Tests` cover operations/backends.
- Agent tests include protocol contracts and conversation regressions.
- Keep `make check` and harness both relevant.
