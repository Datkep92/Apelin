import Foundation

/// The skills every session has. They are source, not bundle resources: a
/// resource bundle's accessor would carry the build machine's path into the
/// binary.
enum BuiltInSkills {
    static let all: [SkillDocument] = [tweakDevelopment, packagingAndInstall, crashTriage]

    static let tweakDevelopment = SkillDocument(
        name: "tweak-development",
        description: "Writing and changing a tweak in an Apelin project: layout, hooks, filters, the on-device toolchain and SDK, and the edit-build loop.",
        body: """
        # Tweak development on the device

        You are on a jailbroken iPhone or iPad (iOS 16 or later, roothide or
        rootless). The project lives in `~/Documents/wiki.qaq.apelin/Projects/<name>/`
        and every file tool works relative to that root. Nothing you write can
        leave it.

        ## The project
        - `apelin-project.json` is the build description: sources, compile and
          link flags, frameworks, the deployment target (16.0) and build steps.
          Changing it, or a build script it names, makes the next `build` ask the
          user once (Strict mode); editing sources never does. Change it only
          when the task needs it, and say why.
        - Sources are Objective-C by default; write hooks the way the
          project's template does (its hook API comes from the injection
          framework the tweak extension depends on). Swift is available only if
          the user set it up with the toolchain.
        - The filter plist (`<Tweak>.plist`) selects the processes the dylib
          loads into, by bundle id (`Filter.Bundles`) or executable
          (`Filter.Executables`). SpringBoard is `com.apple.springboard`.
        - Read the template's files before writing new ones; keep its naming.
        - `apelin-icon.png`, beside `apelin-project.json`, is the project's
          icon in Apelin: a square PNG, 1024 points or less. Write it when the
          user asks for an icon; without it Apelin shows its kind's default.
          It is Apelin's alone and never goes into the package.

        ## Finding the API you hook
        - `analyze_framework` lists a framework's exported symbols and
          Objective-C classes from the SDK's `.tbd`; pass `private: true` for
          `PrivateFrameworks`, and `symbol_filter` to narrow.
        - `framework_header` reads a public header. Private frameworks usually
          have no headers in the SDK: declare the interface you need in a local
          header, only the selectors you call.
        - Check availability: the build uses `-Werror=unguarded-availability-new`.
          Guard newer API with `@available(iOS 17.0, *)`.

        ## Writing hooks
        - Hook the narrowest method that produces the behaviour. Call the
          original unless the task is to replace it.
        - Never block the main thread in SpringBoard; a hang there is a
          respring loop for the user.
        - Keep the template's load-time marker log line intact so
          `confirm_loaded` can see it.
        - Symbols are hidden by default (`-fvisibility=hidden`); export only
          what the loader needs.

        ## The loop
        1. Read the relevant files (`read_file`, `grep`, `find`).
        2. Edit with `patch_file` (exact snippet, one occurrence) or
           `write_file`/`create_file` for new files.
        3. `build`. Fix every error diagnostic by file and line, rebuild.
           Treat warnings as work unless they are in the template.
        4. Install and confirm as the packaging-and-install skill describes.
        Keep each step its own call: build, install, respring and
        confirm_loaded are approved one by one.
        """,
    )

    static let packagingAndInstall = SkillDocument(
        name: "packaging-and-install",
        description: "From a successful build to a confirmed load: the package artifact, install through the system installer, respring, confirm_loaded, removal.",
        body: """
        # Packaging and install

        `build` compiles, links, makes the dSYM, strips and signs (signing is
        last; nothing touches the binary after it), then writes the `.deb`. Its
        result lists artifacts with an `id`, a `kind` and a `digest`.

        ## Install
        - Call `install` with the `package` artifact's `id` and `digest`
          exactly as `build` returned them. The host copies that artifact to
          private staging and checks the digest before the installer sees it; a
          mismatch is refused, so never guess or reuse a digest from an older
          build.
        - The packaging description (control fields, maintainer scripts,
          install layout, dependencies) is compared with the template. Matching
          installs run; a changed one asks the user once, showing the package
          id, the diff and every maintainer script. Do not add maintainer scripts
          unless the task needs them; they run as root.
        - The result carries a `transactionID` and, on success, an
          `installationID`. Keep the installation id: it is the only handle for
          `remove_package`.
        - Installation goes through Irisin's installer. There is no `dpkg` or
          `apt` for you to call, and `run_code` must not try.

        ## Respring and confirm
        - A tweak loaded into SpringBoard needs `respring`. Apps can instead be
          relaunched. After respring the session continues; the app may
          reconnect.
        - `confirm_loaded` with the `buildID` and the target process reports
          the marker log line and whether the filter selects the target,
          separately; the image list is not read. The marker is logged once,
          when the target starts, and is only seen while `confirm_loaded`
          listens: for a SpringBoard tweak pass `respring: true` instead of a
          separate `respring`; for an app, relaunch it during the call.
          "Installed" is not "loaded": report both.
        - If nothing loaded: check the filter plist's bundle id against the
          target, the injection framework dependency, then `read_logs` for the
          target process.

        ## Removal
        - `remove_package` takes an `installationID` from an install in this
          project. Packages Apelin did not build and install, bootstrap packages
          and Apelin itself are out of reach, and removal is confirmed every
          time.
        """,
    )

    static let crashTriage = SkillDocument(
        name: "crash-triage",
        description: "When the target crashes or resprings after an install: find the report, symbolicate it against this build's dSYM, read it before changing code.",
        body: """
        # Crash triage

        A crash is read before anything is changed.

        1. `list_crashes` for the target process (SpringBoard, the hooked app),
           newest first. A respring loop shows several close together.
        2. `symbolicate_crash` with the report id and the `buildID` you
           installed. The host matches the report's image UUID to the project's
           dSYM; if `matchedImageUUID` is empty, the report is from another
           build: rebuild, reinstall and reproduce instead of reading stale
           frames.
        3. Read the crashed thread top down. The first frame in your image is
           where to look; frames above it in system code tell you what your code
           passed in. `suspects` ranks images by blame; your tweak first is
           likely, but a system frame on top is common for a bad argument.
        4. `read_crash` for the exception type, the termination reason and the
           other threads when the crashed thread is not enough.
           - `EXC_BAD_ACCESS` / `KERN_INVALID_ADDRESS`: a released object, a
             wrong ivar or method signature, a hook on the wrong class.
           - `EXC_BREAKPOINT` / `SIGTRAP`: a Swift runtime trap or an
             `NSException`; the last exception backtrace names it.
           - `unrecognized selector`: the class or OS version lacks the method
             you called; check with `analyze_framework` and guard it.
           - Termination reason `FRONTBOARD` / watchdog: the main thread was
             blocked.
        5. `read_logs` for the process around the crash time for the marker
           line and anything the tweak logged.
        6. Fix, rebuild, reinstall, respring, then `confirm_loaded` and check
           that no new report appears.

        If SpringBoard keeps crashing, the safest step is `remove_package` with
        this build's installation id; say so to the user rather than retrying
        blindly.
        """,
    )
}
