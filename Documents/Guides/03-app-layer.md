# 03 Tầng app (Apelin/)

## Purpose

App cung cấp UI cho toàn workflow: projects, chats, settings, onboarding, transfer, distribution. App không giữ daemon state và không set install root.

## Key modules

- `main.swift`: app entry; cold launch no saved state restore (main deletes saved state stub).
- `DaemonClient.swift`: XPC connection lifecycle/retry/proxy.
- `Application/`:
  - `AppDelegate.swift` (data folder).
  - `LegacyHome.swift`: main project list.
  - `ApelinLinkRouter.swift`, project owner checks, ExecutableWatch, QuietExit.
- `Interface/`:
  - `Chats/`: chat runtime, transcript, composer, message rows, compaction.
  - `Projects/`: create/selection/distribution templates.
  - `Root/`: split view/sidebar/navigation order.
  - `Settings/`: model providers/accounts, toolchain/SDK, git, env tasks, licenses/logs/memory/skills/transfer.
  - `Feedback/`, `Onboarding/`, `Transfer/`.
- `Service/ApelinService.swift`: central call wrappers to ops.
- `Resources/`: localization xcstrings.

## Important app invariants

- app icon uses `AppIconMark`, not `UIImage(named: "AppIcon")`.
- cold launch deletes saved application state.
- accessible labels/settings on icon-only controls.
- no toolbar app's own screens via screen tools.
- data home per container fixed to mobile home (fork history).
