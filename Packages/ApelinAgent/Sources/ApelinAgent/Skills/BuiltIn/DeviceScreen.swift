extension BuiltInSkills {
    static let deviceScreen = SkillDocument(
        name: "apelin-screen-reading",
        description: "Reading and driving another app's screen: what apelin_screen_read_tree answers, why a whole page is expensive to keep, how match, clickable_only and max_elements cut it down, how to tell a filtered read from an empty page, and that each read or action is its own consent. Read before reading or touching the screen.",
        body: """
        # Reading another app's screen, and acting on it

        Two tools do this, and no others. `apelin_screen_read_tree` answers
        the foreground app's accessibility tree: the text, the controls, the
        role of each element, whether it is clickable, and its frame.
        `apelin_screen_interact` performs one action: a tap at a point or on
        an element, a double tap, a long press, a drag, typing, a swipe, a
        hardware button, a key, opening a URL. A target may be named, and
        then the app comes to the front first.

        ## A read is context, and it is paid for again
        The tree of a page is hundreds of elements, and everything the tool
        answers stays in the conversation: every later request in the session
        carries it and is billed for it again. Reading a whole settings page
        to find one switch is the most expensive way to find it.

        So a read takes three filters, and all of them run inside the
        session, on the tree the device has already sent — no second read, no
        second consent, nothing new on the wire.
        - `match` keeps only elements whose label, value, identifier or role
          contains the text, case- and diacritic-insensitively.
        - `clickable_only` keeps what a tap can land on: buttons, fields,
          switches, cells. Use it when a page's prose drowns its controls.
        - `max_elements` keeps at most that many, up to 1000.

        A filtered read answers `elementsTotal` (how many the page had),
        `elementsMatched` (how many matched) and `truncated`. Read those
        before saying anything about the page.

        ## An empty answer is not an empty page
        A match that keeps nothing looks exactly like a page with nothing on
        it. `elementsTotal` is what tells them apart: when it is a number and
        the kept list is empty, the page had elements and the filter was
        wrong. Read the same page again without the filter, or with a shorter
        match, before reporting that there is nothing there. `truncated` true
        means the list is cut — a limit bit, or the device sent it cut — so
        the element looked for may be below the cut, and the fix is a match
        rather than a bigger limit.

        ## Acting: one action, then look
        Each `apelin_screen_interact` call is one thing done. After it,
        read the screen again and say what changed; an action's own answer
        says it was performed, never that it worked. Tap an element by its id
        from a read rather than by a remembered point: a page moves under a
        long conversation, and a point is stale as soon as the list scrolls.
        Before tapping something that changes state for good — deleting,
        sending, buying, turning a service off — say what the tap will do and
        have the user agree.

        ## Consent, one step at a time
        While Ask Before Using the Screen is on, every read and every action
        is its own consent, in every mode, and asking the user and waiting is
        the normal way this works — not a failure to work around. Do not
        batch a task into "read and act twice" and hope. A screenshot needs
        asking for separately and each time, and only when appearance is the
        question; the tree is text, and for reading state it is better.

        Apelin's own screens cannot be driven from here: an approval, a
        setting, a project deleted — those the user does in Apelin, so ask
        them.

        ## A locked device is the user's
        A device that is locked or has its screen off answers a tap with a
        refusal, and the only thing that works is waking it. Never guess a
        passcode, never type one, never ask for one. A device with a passcode
        stays on its lock screen after waking: say so and ask the user to
        unlock it, then go on.

        ## Saying what happened
        Report the elements by the words on them, and quote the figure that
        changed. "the page has no such button" is only honest with
        `elementsTotal` behind it. A step is verified when the after-read
        shows it, and not when the tap was accepted. When a step could not be
        taken — the user declined the consent, the tool refused, the screen
        stayed on the lock screen — that step is untested, and the report
        says so with what the user can do to test it.
        """,
    )
}
