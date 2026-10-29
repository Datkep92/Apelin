extension BuiltInSkills {
    static let packagingAndInstall = SkillDocument(
        name: "apelin-packaging-and-install",
        description: "From a successful build to a confirmed load: the package artifact, install through the system installer and what to do when another package is in its way, maintainer scripts, respring, apelin_package_confirm_loaded, and removal.",
        body: """
        # Packaging and install

        `apelin_project_build` compiles, links, makes the dSYM, strips and signs (signing is
        last; nothing touches the binary after it), then writes the `.deb`. Its
        result lists artifacts with an `id`, a `kind` and a `digest`.

        ## Install
        - Call `apelin_package_install` with the `package` artifact's `id` and `digest`
          exactly as `apelin_project_build` returned them. The host copies that artifact to
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
          `apelin_package_remove`.
        - Installation goes through Irisin's installer. There is no `dpkg` or
          `apt` for you to call, and `shell_run` must not try; the
          apelin-package-dependencies skill covers what installs a dependency.

        ## When another package is in the way
        The installer resolves nothing: it never removes a package to make
        room for yours. An install fails when an installed package owns one
        of its files (`… is owned by …; Replaces is required`) or when its
        `package.conflicts` or `package.breaks` names an installed package
        (`Conflicting final packages`). The result's `conflicts` then names
        each package in the way, the file, and the `installationID` when
        Apelin installed it.
        - After renaming the package ID, or reusing a product name another
          package already installs, remove the installation named there
          with `apelin_package_remove` (the user confirms it), then install
          again. A package Apelin did not install is the user's to remove
          with their package manager: ask them.
        - Adding `conflicts` or `breaks` removes nothing; it only makes the
          install fail while that package is there.
        - Name a package in `package.replaces` only when the user wants
          yours to take over its files.
        - Never rename the dylib or drop a file to get past the failure
          without telling the user.

        ## Maintainer scripts
        Add one only when the task needs it (postinst, prerm, …), as a project
        file named in `package.maintainerScripts`. They run as **root**, in
        the bootstrap, and the install card shows each in full:
        - Spell paths `@PREFIX@/…` (bootstrap) and `@ROOTFS@/…` (system), the
          only tokens substituted, as the apelin-bootstrap-paths skill says; `sh -n`
          must pass.
        - A daemon your package ships is loaded by its postinst: boot the
          label out of `system/`, `user/501/` and `gui/501/` (roothide's
          launchctl can put a bootstrap daemon in the per-user domain), then
          `launchctl bootstrap system "@PREFIX@/Library/LaunchDaemons/<label>.plist"`;
          prerm boots it out on `remove`. Keep the label in a variable alone
          on its line. A daemon your tweak injects into is restarted by your
          postinst too; a SpringBoard tweak needs a respring, not a script.
        - Do not register the app, rebuild the icon cache or respring from a
          script, and do not `mkdir -p` a folder for mobile as root (it leaves
          the parents root-owned): make each level with `mkdir -m 0755` and
          `chown -h 501:501`, skipping a level that exists and never following
          a symlink.
        - A link you ship or create is relative (apelin-bootstrap-paths).

        ## Respring and confirm
        - A tweak loaded into SpringBoard needs `apelin_device_respring`. Apps can instead be
          relaunched. After respring the session continues; the app may
          reconnect.
        - `apelin_package_confirm_loaded` with the `buildID` and the target process reports
          the marker log line and whether the filter selects the target,
          separately; the image list is not read. The marker is logged once,
          when the target starts, and is only seen while `apelin_package_confirm_loaded`
          listens (15 s; 30 s with a respring): for a SpringBoard tweak pass
          `respring: true` instead of a separate `apelin_device_respring`. For an app, your
          tool calls run one at a time, so ask the user to open it (quitting
          it first if it runs) while the call listens. "Installed" is not
          "loaded": report both.
        - If nothing loaded: check the filter plist's bundle id against the
          target, the injection framework dependency (`mobilesubstrate` in
          `depends`), then `apelin_log_read` for the target process. A daemon
          started with `DISABLE_TWEAKS=1`, and an app on roothide's blacklist,
          load no tweaks at all.

        ## Removal
        - `apelin_package_remove` takes an `installationID`: one an install
          returned, or one a refused install names in `conflicts`. Packages
          Apelin did not build and install, bootstrap packages
          and Apelin itself are out of reach, and removal is confirmed every
          time.
        """,
    )
}
