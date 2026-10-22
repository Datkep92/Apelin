# Distributing a project

Open a project's menu and choose **Distribute…**. Choose **roothide** or
**rootless**, then tap **Build**. Opening the page or choosing a target does
not start a build. Build opens the build page, which runs one existing
release build for that target, showing Preparing, Compiling, Packaging and
Verifying; its `…` menu has the Build Log. Stop cancels that build; the page
stays open with its outcome, and Retry starts a new build for the same
target. Once it succeeds, Export Package opens the system share sheet with its
one `.deb` file. Go back, choose the other target and tap Build to make a
separate package. Exporting does not install either package.

## Before distributing

The first page lists what a package for other people should not carry yet,
from `projectCheck` with `purpose: distribution` (and the chosen target as
`bootstrap`). Each finding is a warning with a `distribution.*` code:

- `distribution.package.name.template`, `.description.template`,
  `.author.template`: the field is still a string default of the project's
  template.
- `distribution.package.version.template`: the version is still the one the
  template's project file starts with.
- `distribution.package.id.local`, `distribution.bundleID.local`: the package
  ID or an app's `CFBundleIdentifier` is still the `local.apelin.` one
  `projectCreate` made up.
- `distribution.icon.missing`: an app's Info.plist names no icon.
- `distribution.version.packaged`: a release package of this ID and version
  was already built for the target (any target, without one).

They are advice. Build still goes ahead after a confirmation, and the build
itself is never refused for them. **Ask Agent to Prepare** closes the page and
sends the project's conversation a request to run `check_distribution`, fix
what it lists and report back without building. The agent's
`check_distribution` tool answers the same findings; its `build` with
`configuration: release` and a `bootstrap` returns them among the
diagnostics, and its system prompt tells it to check before a distribution
build.

The project must have a valid `apelin-project.json`, an SDK and toolchain binding,
and architectures for the chosen bootstrap. An empty workspace needs a real build
description before distribution; the agent can create that description as part
of implementing the project. Until it has one — a workspace, a manifest with
`buildSystem: external`, or one with no `build` — **Distribute…** in the menu is
disabled and says it needs a build description, and the distribution page, if
it is open when that is found, offers no target and says the same.

Use the project's existing build and packaging description:

- Declare each target's actual architectures and bootstrap dependencies.
- Keep package layout paths logical. The packager maps rootless paths under
  `/var/jb` and writes roothide's unprefixed relocatable layout. The package
  architecture is `iphoneos-arm64` or `iphoneos-arm64e`, respectively.
- Declare maintainer scripts in `package.maintainerScripts` only when needed.
  Refer to bootstrap paths with `@PREFIX@` and real system paths with `@ROOTFS@`.
  The packager substitutes these per target and checks every script with `sh -n`.
- Use the typed `build` tool with `configuration: "release"` and an explicit
  `bootstrap: "roothide"` or `"rootless"` when asking the agent to build a
  distribution. Omit bootstrap for an ordinary build for the current device.
- Do not create a second packaging script that bypasses these checks. Never
  rename or copy one target's package and call it the other target.

The wire remains the existing `buildStart` operation, with an optional bootstrap
field; old requests retain their current-device behavior. Each target has its
own task, build directory, artifact ID and dSYMs. The worker reads the finished
Debian archive back, validates its structure and package identity/architecture,
checks the bytes against the recorded digest, then publishes the artifact.
The export page checks the digest again before presenting the share sheet.

Builds retain the existing cancellation, on-demand session-host lifecycle and
resumption behavior. A distribution page itself is transient; if it is closed
or the app exits, its already completed artifacts remain in the normal Builds
folder. It does not modify project source, install packages or change the
current toolchain selection.
