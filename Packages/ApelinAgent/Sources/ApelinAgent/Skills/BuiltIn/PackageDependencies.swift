extension BuiltInSkills {
    static let packageDependencies = SkillDocument(
        name: "package-dependencies",
        description: "Getting a package installed: your project's own build goes through apelin_package_install; a dependency from a repository is the user's to install in Irisin. Why shell_run cannot install, remove or respring, and why apt, dpkg and irisin-cli do not work for you.",
        body: """
        # Installing packages

        You cannot install, remove or respring from shell_run. Those act on the
        whole device as root, and shell_run runs as **mobile** (uid 501). Use
        the dedicated tools, which go through the privileged session host, and
        for anything they do not cover, hand it to the user.

        ## Your project's build → apelin_package_install
        A package you built installs with `apelin_package_install` (the package artifact's id
        and digest), then `apelin_package_confirm_loaded` and `apelin_package_remove`, as the
        packaging-and-install skill says. That path keeps the approval, the
        load check and the removal handle working; nothing else does. Never
        try to place the `.deb` yourself.

        ## A dependency from a repository → the user
        A project may depend on a package from a repository the user has (an
        injection framework, a library, a tool). You cannot fetch or install
        it:
        - `apt` and `dpkg` change the system as root, and newer bootstraps no
          longer ship them at all. Do not reach for them.
        - `irisin-cli` installs only as **root**: under any other user it
          says so and exits 77, and Irisin's daemon takes an external client
          only at euid 0. shell_run is mobile, has no terminal for `sudo` to
          ask a password on, and must never ask the user for one, so
          `irisin-cli` (and `sudo irisin-cli`) from shell_run fails. Do not run
          it and do not put it in a script.
        So declare the dependency in `package.depends` (project-description)
        and ask the user to install it: name the package ID and why it is
        needed, and have them install it with their package manager (Irisin
        is always there, since Apelin depends on it), or run
        `sudo irisin-cli install <package id>` themselves in a terminal; then
        install again. An install whose dependency is missing fails: the
        installer resolves nothing. Never drop the dependency, copy its files
        into your package or rename your package to get past it. The tweak
        extension depends on `mobilesubstrate` and the preferences extension
        on `preferenceloader`, so both are there wherever those extensions
        are; `projectCheck` warns when a support component's runtime
        dependency is missing from `package.depends`.

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
