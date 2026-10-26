extension BuiltInSkills {
    static let deviceCLI = SkillDocument(
        name: "apelin-icli",
        description: "Running icli, the device's command-line tool, through shell_run: apps, URLs, files, preferences, processes, launchd, packages, the screen and input, when no dedicated Apelin tool does it, and icli probe, a JavaScriptCore script with Objective-C reflection for probing what the device has. What runs as mobile, what is never yours to run, roothide paths, and what to tell the user when icli is missing.",
        body: """
        # icli

        icli (package `com.icli.icli`, OwnGoal's) is one executable that
        does on the device what a person at it would: apps, URLs, files,
        property lists and preferences, processes, launchd services, the
        package database, the screen, touch and keys, the clipboard. Apelin
        depends on it, so it is normally installed, and its name resolves on
        shell_run's search path. Apelin's own device tools are built on its
        library.

        ## Running it
        Use shell_run with an argv, never a shell string:
        `{"argv": ["icli", "app", "list"]}`. Each command prints JSON and
        exits non-zero on failure, with the reason in its output. Before a
        command you have not used in this conversation, read its help
        (`icli --help`, `icli <group> --help`, `icli <group> <command>
        --help`) and use only the options it documents; never guess a flag.

        ## Dedicated tools come first
        Where Apelin has a tool, use it, not icli: building and installing
        your package, removing it, respringing (`apelin_device_respring`),
        confirming a tweak loaded, the live log (`apelin_log_read`), crash
        reports, screenshots and the UI tree and its actions. Those go
        through the session host, which asks the user where the approval
        mode says so and keeps the records later steps read. icli is for the
        rest, for example:
        - apps: `app list`, `app info <bundle id>`, `app running`,
          `app frontmost`, `app launch <bundle id>`, `app kill <bundle id>`,
          `url open <url>`; `app network get <bundle id>` when an app says it
          is offline (its Wi-Fi and cellular data policy)
        - state: `device info`, `env` (layout, bootstrap root), `proc list`,
          `svc list`, `svc print <label>`, `pkg list`, `pkg info <id>`,
          `pkg tweaks`
        - files and settings outside the project: `fs ls`, `fs read`,
          `fs plist <path>`, `prefs read <domain>`
        - the screen, when the screen tools are not enough: `screen info`,
          `screen ocr`, `screen tap`, `screen swipe`, `input type`; read
          `screen info` first, since coordinates are points in the
          orientation shown

        ## Probing with JavaScript
        When no command answers a question about the device — whether a
        class or a private method exists, what an object returns, what a
        framework reports — `icli probe` (icli 0.10.0 and later) evaluates a
        JavaScriptCore script in the icli process and prints one JSON line,
        `{"ok": true, "result": …, "output": …}` or `{"ok": false, "error":
        …, "output": …}`, exiting non-zero on `ok: false`:
        `{"argv": ["icli", "probe", "-e", "ObjC.use('UIDevice').currentDevice().systemVersion()"]}`.
        A longer script goes in a file in the project (`icli probe
        probe.js`), or on stdin with `-`. What a script has:
        - `ObjC.use('NSProcessInfo')` or `ObjC.classes.NSProcessInfo`, and
          methods by name, a colon written as `_`
          (`stringWithUTF8String_`), or by selector
          (`obj['setValue:forKey:'](v, k)`); a string, number, boolean or
          date comes back as a JavaScript value, `NSNull` as `null`, any
          other object as a handle with `$value`, `$class` and `$isClass`.
          Structs, non-null pointers and blocks are refused.
        - `fs.ls`, `fs.read`, `fs.write`, `fs.stat`; `console.log` and
          `print`, collected into `output`; `sleep(ms)`.
        - `api(method, params)`, a read-only set of icli's own answers:
          `env.info`, `device.info`, `screen.info`, `svc.list`,
          `svc.status`, `app.list`, `proc.list`.
        It runs inline, as mobile like any shell_run: a crash or hang takes
        that icli process down, and the script cannot start a process
        (`proc.run`) or call `exit()`. Probe to read and understand;
        changing the device stays with the commands and tools above, under
        the same rules. A thrown script is `ok: false`, not a crash. Never
        run `icli probe repl`: it is interactive and shell_run has no
        terminal. An icli older than 0.10.0 has no `probe`; say so and
        point the user to `https://apt.owngoal.dev` for the update.

        ## As mobile, and never as root
        shell_run runs as mobile, and the commands above work so. Never run
        these, as mobile or with `root: true`: package installs and removals
        (`pkg install`, `pkg remove`, `pkg add-repo`, `app install`,
        `app uninstall`: a package goes through `apelin_package_install`, a
        dependency as the apelin-package-dependencies skill says), launchd
        changes (`svc load`, `unload`, `bootstrap`, `bootout`, `start`,
        `stop`, `kill`, `kickstart`, `enable`, `disable`, `setenv`,
        `remove`), `sb respring`, `sb uicache`, `device reboot`, `fs chown`
        and writes under the system or the bootstrap. If the user asks for
        one, say which command would do it and let them run it.

        ## Paths on roothide
        icli takes real filesystem paths, while a bootstrap shell's `/` is
        the bootstrap root: a file icli writes to `/tmp/screen.jpg` is
        `/rootfs/tmp/screen.jpg` to the shell. Hand icli a path the shell
        printed with the `jbroot` that `icli env` reports in front of it.
        The apelin-bootstrap-paths skill has the rest.

        ## When icli is missing
        If shell_run cannot find `icli`, do not look for a replacement or a
        copy. Tell the user that Apelin needs icli and that it comes from
        OwnGoal's repository: add `https://apt.owngoal.dev` to their package
        manager's sources if it is not there, then install icli
        (`com.icli.icli`). Once that repository is among their sources you
        may also offer to install it as the apelin-package-dependencies
        skill says. Go on after it is installed.
        """,
    )
}
