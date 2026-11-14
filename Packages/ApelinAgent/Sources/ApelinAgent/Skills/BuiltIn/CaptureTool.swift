extension BuiltInSkills {
    static let captureTool = SkillDocument(
        name: "apelin-capture-tool",
        description: "Using the Apelin Capture app (com.apelin.capture) on the device: open a web page, read the API calls it captured (status log, captured calls, cURL), or call an API found that way. Read before opening a page, reading what was captured, or calling an API found that way.",
        body: """
        # Apelin Capture — API capture tool on the device

        Apelin Capture is a separate test app (`com.apelin.capture`, installed at `/var/jb/Applications/ApelinCapture.app`). It opens a web page in a WKWebView, injects a script that captures every `fetch` and `XMLHttpRequest`, and writes the results into the app's own folder. Apelin reads those results to find and call the real API.

        ## Where the results are

        The app's data folder is `/private/var/mobile/Containers/Data/Application/<UUID>/Documents/apelin-bridge/`. Find the UUID by matching the app's id in `.com.apple.mobile_container_manager.metadata.plist`; the UUID changes on reinstall, so always look it up; never reuse one from an earlier session.

        - `status.txt`: the log (launch, open, loaded, fail, failprov, desktop, zoom). Read it with `tail -n 30`.
        - `captures.ndjson`: one API call per line (kind, url, method, reqBody, status, resBody, ...). Read it with `grep`, `cat` or `head -c`, because the file can be large.
        - `url.txt`: the address opened at launch (if empty, example.com opens).
        - `done.txt`: marks the page as finished (if present).

        Tip: Python is denied when reading this folder; use `cat`, `grep`, `head` and `tail`.

        ## Opening a page

        1. Write the address into `url.txt` in the folder above (http and https only).
        2. Launch the app with `icli app launch com.apelin.capture` (or `apelin_screen_interact`, if allowed). Note that `icli app launch` does not bring the app to the front while Apelin is open.
        3. Read `status.txt` for `open` and `loaded`. Opening a new page clears `captures.ndjson` and `done.txt`.

        Opening through an `apelincapture://open?url=...` link has not been verified on the device; do not promise that it works.

        ## Using the results

        - Filter `captures.ndjson` for calls whose `url` contains `/api/`, and skip static resources.
        - For a call you need, build a `curl` command from its URL, method, headers and body. Cookies are not in the record; if the API needs a login, tell the user.
        - Call it with `apelin_http_request` when the API is public and needs no cookie. For an API that needs cookies, use `curl` in shell_run and warn about the cookies.

        ## Known limits

        - Whether the app shows the new buttons (share, Safari, desktop/phone) correctly on screen is not verified; it has only been installed successfully.
        - A page with many calls produces a very large file; read it in pieces.
        - An error call on the page can produce unexpected results; check `status`.
        """,
    )
}
