# 10 Cá nhân hoá/fork

## Identity
- Upstream: `owngoal-dev/Apelin`.
- Fork: `Datkep92/Apelin`.
- Package id and bundle id unchanged (`wiki.qaq.apelin.cn`).
- Main branch main current upstream base + personalization.

## MUST maintain
- `CA_NHAN_HOA.md` history is append-only.
- Merge conflict resolution preserve personalization blocks (`ModelProvidersController.swift`, localization).
- Don't pull/push official tags.
- Release version fork targeted; CI use actions.

## Personalization rule
- One commit per feature/fix.
- Add row each change.
- Always commit/push often due old project folder loss event.

## Major entries summary
- configured provider multiple configurations.
- upstream sync v0.1.8-v0.3.0.
- global data home fix.
- custom provider no verify.
- long press bubble delete.
- delete providers (signed-out/waiting).
- sort/provider sidebar.
- keyboard default Enter.
- one-line menu subtitle last chat.
- DeepSeek reasoning normalization.
---

See `CA_NHAN_HOA.md` for fully enumerated records.
