# 11 Quy tắc phát triển

## Core rules from AGENTS.md
- Checklist before code (`CHECKLIST.md`, `make check` fails script first).
- No build flags / no variants app-backend; handshake only.
- daemon absence never error; grace period not count.
- peer auth before request decode.
- no install prefix in Swift.
- realpath before decisions.
- GNU guard for recursive deletes.
- start ExecutableWatch once in didFinishLaunching.
- app never exit in foreground (QuietExit).
- data folder user home; not container.
- cannot use UIImage named AppIcon.
- icon sets compress JPEG etc.
- accessibility elements accessible.
- accessibility semantics only.
- storage app bundle permission.
- versions/deployment target in xcconfig.
- no project generators modifies pbxproj.
- no Swift files naming XPC macros (Swift only via AppXPC).
- no SF symbol above deployment target.
- no no sponsor for dependencies lacking reason.
- license collection build phase.
- no absolute build path shipped binary; concise `#file`.
- localization string value only, one Catalog discipline, stale check runs.
- crashes: symbolicate with dSYM before guesses.

## Git workflow
- commit work automatically using `git_commit` all.
- messages summary then details.
- push only when requested.
- user drives tags/release/version changes.
- do not force push or repoint remote.

## Mode
- Strict/Full; root calls need user.
- screen consent mode if on.
- only explicit user confirms sensitive things: publishing, feedback issue, creating repo, deleting project, etc.
- screen tools never operate Apelin app itself.

## Verification
- On-device test critical behavior.
- log confirmation loaded.
- crash triage, symbolicate before code.
- screenshots need consent.
- respect checklists and scripts (`make check`).

## Repo map maintenance
- New op/module: update guides 04/08/09 + ARCHITECTURE.
- Fork change: append `CA_NHAN_HOA.md`.
- New feature: update guides in same commit.
- Update root `ARCHITECTURE.md` first-level map if structure changes.
- Keep document link names sensible.
- Never leak credentials in docs.
