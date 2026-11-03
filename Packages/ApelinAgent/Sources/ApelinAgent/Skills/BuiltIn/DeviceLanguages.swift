extension BuiltInSkills {
    static let deviceLanguages = SkillDocument(
        name: "apelin-device-languages",
        description: "Which languages really run on this device, and through what: shell, Python 3, Perl, Node, and C, C++, Objective-C or Swift once the user has set up a toolchain in Settings; how to tell an interpreter that runs from a name on the search path, and that Theos is never available here. Read before promising to compile, run or test code in another language.",
        body: """
        # What runs on the device, and what does not

        The block before each of the user's messages names what this device
        has: a toolchain, if the user set one up in Settings ▸ Toolchains,
        and the iPhoneOS SDK, if one is imported. Nothing compiles without
        them, and no search of the disk changes that.

        ## A name on the search path is not a working program
        An interpreter or a compiler that resolves on shell_run's search
        path may still fail the moment it starts: a bootstrap ships a stub,
        the version has no arm64 slice for this device, or a needed library
        was never installed. The only honest check is to run it:
        `{"argv": ["python3", "--version"]}`. Exit 127 is the shell saying
        there is no such program; a run that exits 0 and prints a version is
        the program itself. Report what a run answered, never what the
        search path promised. An answer of "it should be there" is not one.

        ## What runs as things stand
        - **Shell.** Apelin's shell_run runs the command itself, so shell
          text needs no separate interpreter, and `/bin/sh` does not exist on
          a jailbroken device: the bootstrap's `dash` is the shell. A script
          that names `#!/bin/sh` fails before its first line runs.
        - **Python 3**, named in the environment block when it is on the
          path: the standard library is there, a third-party module is not
          unless the user installed it. It reads and writes images, JSON,
          archives and text with what it ships. `code_run` runs it as a
          program the assistant wrote.
        - **Perl** likewise. **Node** exists only where the user installed
          it; when it is missing, `code_run` with that interpreter fails
          with the shell's own message, and that message goes to the user.
        - **make**, **git**, **ldid** and **dpkg-deb** are there for reading,
          editing and signing, but a package is made only by a build
          (`apelin_project_build`): dpkg-deb is never run by hand.

        ## What waits for the toolchain
        C, C++, Objective-C and Swift need the compiler, the linker and an
        iPhoneOS SDK that a Command Line Tools release carries; that is
        what the toolchain in Settings installs. Until then the honest
        answer is that the code cannot be compiled here, and the user is the
        one who sets it up. Never install a compiler, an SDK or Theos on
        one's own initiative, and never from a repository the user did not
        name: say what is missing, what installing it would take, and let
        the user decide.

        ## Theos is not here, and is not to be installed
        Apelin has no Theos and no Logos: a tweak is plain Objective-C
        (apelin-tweak-development), built by the project's own build, which
        also signs it. A Theos project the user brings is read for what it
        hooks, then rewritten; its Makefile is not run.

        ## Testing what runs
        A test that can be run is worth more than one that cannot. For
        Python, Node, Perl or shell, `code_run` with the test program and
        its output read is the whole harness; for compiled code, the
        project's own build (apelin-external-build) runs the test step the
        repository declares, and there is no second one invented here. What
        cannot be run on this device is said to be untested, with what the
        user would run to test it.
        """,
    )
}