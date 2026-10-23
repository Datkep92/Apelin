import enum ApelinProject.ProjectValidation
import Foundation

/// The skills every session has. They are source, not bundle resources: a
/// resource bundle's accessor would carry the build machine's path into the
/// binary.
enum BuiltInSkills {
    static let all: [SkillDocument] = [tweakDevelopment, projectDescription, externalBuild, packagingAndInstall, crashTriage]

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
          when the task needs it, and say why. The project-description skill
          lists every member; read it before you edit the file.
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

        ## Beside other tweaks
        Other tweaks load into the same process and often hook the same
        methods.
        - Install hooks with `MSHookMessageEx` or `MSHookFunction`, which
          chain with theirs, and call the original.
          `method_exchangeImplementations` and `method_setImplementation`
          can drop another tweak's hook.
        - Everything you name shares the process with them. Keep hook
          functions, saved originals and globals `static`. Give any method
          you add to a system class, and any class you create, your tweak's
          own prefix: when two tweaks use one name, one of them silently
          loses. Never override a system method in a category.
        - Key associated objects by the address of a `static` variable,
          never by a string.

        ## Theos and Logos
        Apelin does not build Theos projects: there is no Logos preprocessor
        and no Theos makefile system, and an Objective-C product compiles
        only `.m` and `.c` files (no `.x`, `.xm`, `.mm` or C++). Never
        download or vendor Theos. Rewrite a Theos tweak instead, keeping its
        logic, in the template's style:
        - A `%hook Class` method becomes a `static` function taking `id self,
          SEL _cmd` and the method's arguments, installed in the constructor
          with `MSHookMessageEx(objc_getClass("Class"), @selector(name:),
          (IMP)Hooked, (IMP *)&Original)`; `%orig` becomes
          `Original(self, _cmd, …)`. A class method hooks the metaclass,
          `object_getClass(objc_getClass("Class"))`.
        - `%ctor` is `__attribute__((constructor)) static void …(void)`;
          `%group` and `%init` are that constructor installing each group's
          hooks when its condition holds.
        - `%c(Name)` is `objc_getClass("Name")`; `%new` is `class_addMethod`
          with the method's type encoding; `%property` is a getter and setter
          on `objc_getAssociatedObject`; `%hookf` is `MSHookFunction`; `%log`
          is `os_log`.
        - Logos gave every hook a mangled name unique to the tweak
          (`_logos_method$…`); a rewrite names them itself, by the rules in
          Beside other tweaks. A Swift or C++ function is hooked by its
          mangled symbol, as analyze_framework lists it, looked up with
          `dlsym` or `MSFindSymbol`: a demangled name finds nothing. Check
          the symbol on each iOS version the package supports.
        - A `.x` file becomes `.m`; an `.xm` that uses C++ is rewritten
          without it.
        - The build links the SDK's public frameworks only. Reach a private
          class at run time with `objc_getClass`, and a private function with
          `dlopen` and `dlsym`.
        - Never link with `-undefined dynamic_lookup` or `suppress`, in
          `linkFlags` or a build script: CLT 15.0's linker then binds an
          arm64e slice without pointer authentication, and it crashes on its
          first constant string or imported call (the build refuses one).
          Leave a symbol to load time with `-Wl,-U,_symbol`, one per symbol.
        - An imported repository stays a workspace: its Theos Makefile is
          replaced by a build script of its own that compiles the rewritten
          sources with the toolchain (the external-build skill), reading
          `TWEAK_NAME`, `_FILES`, `_FRAMEWORKS`, `_LIBRARIES`, `_CFLAGS`, the
          filter plist and `control` for what to build and package. Keep the
          package id, version and author the repository already has.

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

    static let projectDescription = SkillDocument(
        name: "project-description",
        description: "Every member of apelin-project.json, the build description Apelin's build reads: products, flags, steps, package, layout, tweak filter, the macros the build defines, and what asks the user.",
        body: """
        # The project description

        `apelin-project.json` at the project root is the one thing Apelin's
        build reads. It is checked strictly: an unknown member, a duplicate
        key or a wrong type is an error naming its field, such as
        `/products/0/sources`. The complete schema is this skill's file
        `apelin-project.schema.json` (read_skill with that file).

        ## Members Apelin writes
        Never invent, copy or change these:
        - `schemaVersion` (1) and `projectID`, a lowercase UUID approvals are
          bound to.
        - `template`: the template the project was made from.
        - `environment` `{toolchain, sdk}`, each `{id, digest}`: the
          registered toolchain and SDK. Change them only with
          project_environment_set; never type a digest.
        - `displayName` and `autoName`: the name Apelin shows.

        ## What it builds
        - `kind`: `tweak` (a `dylib` product and `package.tweakFilter`),
          `app` (an `app` product), `cli` (an `executable`) or `preferences`
          (a `bundle`).
        - `language`: `objc` and `c` compile `.m` and `.c` files only;
          `swift` compiles `.swift` only. A product never mixes them.
        - `deploymentTarget`: a string, "16.0" or later.
        - `architectures`: `{"rootless": ["arm64", "arm64e"], "roothide":
          ["arm64e"]}`. The keys present are the bootstraps it packages for.
        - `configurations`: `Debug` and `Release`, each `{optimization,
          debugInfo, defines?, cFlags?, swiftFlags?, linkFlags?}`.
          `optimization` is "0", "1", "2", "3", "s" or "z". `defines` maps a
          name to its value; no name starts with `APELIN_`. Each flag is one
          argument starting with `-`, never shell text: `-framework X` is two
          items. The member is `linkFlags`, not `linkerFlags`.

        ## products (one to eight)
        `{id, type, name, sources, …}`:
        - `id`: lowercase, such as `tweak`. `type`: `dylib`, `app`, `bundle`
          or `executable`. `name`: the Mach-O file name.
        - `sources`: project paths that may use `*`, `**` and `?`, such as
          `Sources/*.m` or `src/**/*.m`.
        - Optional: `headerSearchPaths`, `frameworks`, `weakFrameworks`,
          `libraries` (`-l` names, such as `substrate`),
          `frameworkSearchPaths` and `librarySearchPaths` (project paths),
          `objcARC`, `installName` (dylib only; default
          `@rpath/<name>.dylib`), `entitlements` (a project plist), and
          `infoPlist` and `resources` (app and bundle only).
        - `extensionSupport`: `[{extension, component}]`, the headers, link
          stubs and rpaths an installed development extension provides, the
          build picking each bootstrap's own. A tweak hooking with substrate
          has `{"extension": "wiki.qaq.apelin.dev.tweak", "component":
          "substrate"}`, `libraries: ["substrate"]` and depends on
          `mobilesubstrate`.

        ## build.steps
        Per product, in this order: `compile`, `link`, `bundle-resources`
        (app and bundle), `lipo`, `dsym`, `strip`, `sign`. `compile`, `link`,
        `lipo` and `sign` are required and `sign` comes last, as `{"type":
        "sign", "product": "tweak", "identity": "adhoc"}`. `compile` and
        `link` take extra `flags`; `strip` takes `style`, `non-global` or
        `debug`. A `script` step, `{"type": "script", "id", "interpreter",
        "file", "arguments"?, "inputs"?, "outputs"?, "requiresApproval":
        true}`, runs a project script (sh, bash, zsh, python3 or perl) as
        mobile in the project root, to generate sources; it always asks the
        user in Strict mode.

        ## package
        `{id, name, version, description, author, section, layout, …}`:
        - `id`: the Debian package name. `version`: a Debian version.
          `section`: Tweaks, Utilities, Development, System, Applications or
          Addons. Optional: `maintainer`, `longDescription` (a list of lines).
        - Relations: `depends`, `recommends`, `suggests`, `conflicts`,
          `breaks`, `replaces` and `provides`, each item like `"name (>=
          1.0)"`, alternatives joined by ` | `; `dependsByBootstrap`
          `{rootless?, roothide?}` for one bootstrap only. The packager adds
          `firmware` and the `Architecture`; never write them.
        - `layout`: `{path, product}` or `{path, file, mode?,
          substitutePrefix?}` items. Paths are as the package sees them,
          rooted at the bootstrap, such as
          `/Library/MobileSubstrate/DynamicLibraries/X.dylib`; the packager
          maps them for rootless and roothide. Never write `/var/jb` or a
          jbroot path.
        - `tweakFilter` (tweak only): `{dylib: <product id>, bundles?,
          executables?, classes?}`. The packager writes the filter plist
          beside the dylib; do not ship one yourself.
        - `maintainerScripts`: `{preinst?, postinst?, prerm?, postrm?}`, each
          a project file. Only `@PREFIX@` and `@ROOTFS@` are substituted;
          `sh -n` must pass. They run as root and the install card shows
          them in full: add one only when the task needs it.

        ## What the build defines
        On every C and Objective-C compile: `APELIN_BUILD_ID`,
        `APELIN_PACKAGE_ID`, `APELIN_VERSION` and `APELIN_PRODUCT_NAME`
        (string literals); `APELIN_BOOTSTRAP_ROOTLESS` or
        `APELIN_BOOTSTRAP_ROOTHIDE` (1, for the bootstrap being built); and
        `APELIN_CONFIGURATION_DEBUG` or `APELIN_CONFIGURATION_RELEASE` (1).
        Swift gets the bootstrap and configuration as conditions. Code that
        behaves differently per bootstrap tests these; a repository's own
        macro is defined from them in a header. The build always passes the
        SDK, `-arch`, the deployment target, `-fvisibility=hidden` and
        `-Werror=unguarded-availability-new`, and `-fobjc-arc` with `objcARC`.

        ## What asks the user
        In Strict mode the next build asks once after a change to `kind`,
        `language`, `deploymentTarget`, `architectures`, `configurations`,
        `build`, `products` (except their `sources`, `headerSearchPaths` and
        `resources`), or an entitlements or script file. The next install
        asks once after a change to `package` (except `version`), a
        maintainer script or an installed file. Editing sources and bumping
        `version` never ask.

        ## A tweak's build members
        ```json
        "products": [{
          "id": "tweak", "type": "dylib", "name": "MyTweak",
          "sources": ["Sources/*.m"], "objcARC": true,
          "frameworks": ["Foundation", "UIKit"], "libraries": ["substrate"],
          "extensionSupport": [{"extension": "wiki.qaq.apelin.dev.tweak", "component": "substrate"}]
        }],
        "build": {"steps": [
          {"type": "compile", "product": "tweak"}, {"type": "link", "product": "tweak"},
          {"type": "lipo", "product": "tweak"}, {"type": "dsym", "product": "tweak"},
          {"type": "strip", "product": "tweak", "style": "non-global"},
          {"type": "sign", "product": "tweak", "identity": "adhoc"}
        ]},
        "package": {
          "id": "com.example.mytweak", "name": "MyTweak", "version": "1.0.0",
          "description": "What it does.", "author": "Someone", "section": "Tweaks",
          "depends": ["mobilesubstrate"],
          "layout": [{"path": "/Library/MobileSubstrate/DynamicLibraries/MyTweak.dylib", "product": "tweak"}],
          "tweakFilter": {"dylib": "tweak", "bundles": ["com.apple.springboard"]}
        }
        ```
        """,
        files: ["apelin-project.schema.json": ProjectValidation.schemaText],
    )

    static let externalBuild = SkillDocument(
        name: "external-build",
        description: "Building and installing a workspace (an imported repository) with its own tools: the build script Apelin runs, what it gets, the one package it writes, and how that package is installed.",
        body: """
        # Building a workspace

        A workspace — an imported repository, or an empty project — keeps its
        own way of building. Apelin runs one script of the project's and
        installs the one package it writes; it does not compile, sign or
        package for it.

        ## Declare the script
        In `apelin-project.json` (Apelin's file, which git ignores), beside
        what is already there:
        ```json
        "external": {"script": "apelin/build.sh", "interpreter": "sh", "arguments": []}
        ```
        - `script`: a file in the project. Use the repository's own build
          script when it already does everything below; otherwise write a
          short one, such as `apelin/build.sh`, that calls the repository's
          build.
        - `interpreter`: `sh` (the default), `bash`, `zsh`, `python3` or
          `perl`, the bootstrap's own. `arguments`: at most 32, optional.
        - Add no other member to `external`, and never change `projectID`,
          `kind` or `buildSystem`.

        ## What the script gets
        It runs as mobile in the project root, with no input, for at most 30
        minutes, and its output is the build log. Its environment:
        - the prepared toolchain first on `PATH`, with `SDKROOT` and
          `IPHONEOS_DEPLOYMENT_TARGET`, as run_code has it: clang builds for
          iOS without `-isysroot`; pass `-arch`.
        - `APELIN_BUILD_ID`: the marker below.
        - `APELIN_BOOTSTRAP`: `roothide` or `rootless`, the package's target.
        - `APELIN_ARCHITECTURE`: the package's `Architecture`,
          `iphoneos-arm64e` for roothide, `iphoneos-arm64` for rootless.
        - `APELIN_PREFIX`: where package paths start, `/var/jb` for rootless
          and empty for roothide.
        - `APELIN_CONFIGURATION`: `debug` or `release`.
        - `APELIN_PROJECT_ROOT`: the project's real path.
        - `APELIN_PACKAGE_DIR`: an empty folder outside the project.

        Only the commands the environment section lists are there: no
        Apple `xcrun`, and usually no `make` or `python3`. A Mac build script
        is read and rewritten for what is here, never run as it is.

        ## What the script does
        1. Compile with the toolchain: `arm64e` for roothide; `arm64` and
           `arm64e` for rootless, joined with `lipo`. Give clang paths
           relative to the project root.
        2. Sign every Mach-O with `ldid -S` (`-S<entitlements.plist>` when it
           needs entitlements); unsigned code does not load.
        3. Lay the package out in a staging folder under the build's
           `TMPDIR`: a tweak's dylib at
           `$APELIN_PREFIX/Library/MobileSubstrate/DynamicLibraries/<Name>.dylib`
           with its filter `<Name>.plist` beside it, a tool under
           `$APELIN_PREFIX/usr/bin/`; and `DEBIAN/control` with the
           repository's Package, Version, Name, Author, Description and
           Depends, and `Architecture: $APELIN_ARCHITECTURE`. Add maintainer
           scripts only when the repository has them, with its own tokens
           already filled in.
        4. Write exactly one `.deb` into `$APELIN_PACKAGE_DIR`, for example
           `dpkg-deb -b --root-owner-group "$stage" "$APELIN_PACKAGE_DIR/"`
           when the environment section lists dpkg-deb.

        A tweak logs the marker `confirm_loaded` looks for from its
        constructor: `ApelinLoaded <APELIN_BUILD_ID>` with `os_log`, under a
        log whose subsystem is the package ID, as the tweak template does. Pass
        the ID in at compile time, such as
        `-DAPELIN_BUILD_ID="\\"$APELIN_BUILD_ID\\""`.

        ## Then
        `build` runs the script (in Strict mode it asks the user every time)
        and answers the package's artifact ID and digest; `install`,
        `confirm_loaded` and `remove_package` work as the
        packaging-and-install skill describes. The first install asks the
        user; it asks again only when the control file (but `Version`), a
        maintainer script or an installed path changes. A package someone
        installed on this device without Apelin is never replaced: never
        rename the package to get past that, tell the user. Write how the
        project builds into `AGENTS.md` once it works.
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
