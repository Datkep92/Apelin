extension BuiltInSkills {
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
        is read and rewritten for what is here, never run as it is. The
        script runs in the bootstrap's shell, whose paths on roothide are not
        the compilers' (the bootstrap-paths skill): give clang relative paths.

        ## What the script does
        1. Compile with the toolchain: `arm64e` for roothide; `arm64` and
           `arm64e` for rootless, joined with `lipo`. Give clang paths
           relative to the project root. Define what a project build would
           (`-DAPELIN_BOOTSTRAP_ROOTHIDE=1` or `-DAPELIN_BOOTSTRAP_ROOTLESS=1`
           from `APELIN_BOOTSTRAP`, `-DAPELIN_PACKAGE_ID=…`) when the code
           tests them, as the bootstrap-paths helper does.
        2. Sign every Mach-O with `ldid -S` (`-S<entitlements.plist>` when it
           needs entitlements); unsigned code does not load, and the
           installer signs nothing for you.
        3. Lay the package out in a staging folder under the build's
           `TMPDIR`: a tweak's dylib at
           `$APELIN_PREFIX/Library/MobileSubstrate/DynamicLibraries/<Name>.dylib`
           with its filter `<Name>.plist` beside it, a tool under
           `$APELIN_PREFIX/usr/bin/`; and `DEBIAN/control` with the
           repository's Package, Version, Name, Author, Description and
           Depends, and `Architecture: $APELIN_ARCHITECTURE`. Add maintainer
           scripts only when the repository has them, with its own tokens
           already filled in. A link in the package is relative: on roothide
           an absolute target resolves against the system.
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

        ## Distribution
        A workspace is distributed like any project: build
        `configuration: release` once per bootstrap, and the script builds
        for `APELIN_BOOTSTRAP` whatever this device runs. check_distribution
        before it only says whether the script is declared; the release build
        checks the package it writes and lists, among its diagnostics, an
        identifier starting `local.apelin.`, a version this project already
        packaged for that target, and a package other than the other
        target's latest release. Fix those in the script or the repository,
        never by renaming one target's package to pass as the other.
        """,
    )
}
