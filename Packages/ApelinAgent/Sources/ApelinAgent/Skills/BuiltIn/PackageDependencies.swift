extension BuiltInSkills {
    static let packageDependencies = SkillDocument(
        name: "package-dependencies",
        description: "Getting a package installed: your project's own build goes through apelin_package_install; a dependency from the user's repositories goes through shell_run as root with irisin-cli, with the user's approval. Why apt and dpkg are never the way.",
        body: """
        # Installing packages

        shell_run runs as **mobile** (uid 501). Installing, removing and
        respringing act on the whole device as root, so they go through the
        dedicated tools, except one case below that runs as root.

        ## Your project's build → apelin_package_install
        A package you built installs with `apelin_package_install` (the package artifact's id
        and digest), then `apelin_package_confirm_loaded` and `apelin_package_remove`, as the
        packaging-and-install skill says. That path keeps the approval, the
        load check and the removal handle working; nothing else does. Never
        place the `.deb` yourself, and never install it with irisin-cli.

        ## A dependency from a repository → irisin-cli as root
        A project may depend on a package from a repository the user has (an
        injection framework, a library, a tool). Declare it in
        `package.depends` (project-description), then install it with
        shell_run and `root: true`:
        `{"argv": ["irisin-cli", "install", "--yes", "<package id>"], "root": true}`.
        `irisin-cli` installs only as root (as mobile it exits 77), and
        `--yes` because nothing can answer a prompt. In Strict and Relaxed
        mode the user approves each such call, with Face ID, Touch ID or the
        passcode; in Full mode it runs at once. Say which package and why
        before you ask. If the user declines, or the package is in none of
        their repositories, ask them to install it with their package
        manager instead, then install your build again.
        - Never `apt`, `dpkg` or `sudo`: they bypass Irisin, and newer
          bootstraps no longer ship apt or dpkg at all.
        - Use `root: true` for nothing else: what it writes belongs to
          root, so mobile cannot change it afterwards.
        An install whose dependency is missing fails: the installer resolves
        nothing. Never drop the dependency, copy its files into your package
        or rename your package to get past it. The tweak extension depends on
        `mobilesubstrate` and the preferences extension on `preferenceloader`,
        so both are there wherever those extensions are; `projectCheck` warns
        when a support component's runtime dependency is missing from
        `package.depends`.

        ## The toolchain and the SDK are different
        A missing **compiler toolchain** or **iPhoneOS SDK** is not a package
        dependency: set those up with `apelin_toolchain_setup` and `apelin_sdk_import`
        (which ask the user and download from Apple's catalogue and the SDK
        sources), or bind the project to an installed one with
        `apelin_project_set_environment`. The environment section of the prompt lists
        what is installed; do not look for compilers on the device.
        """,
    )
}
