# What this device can be made to do, measured

Order `0825a253` point 1 ("AI tự lái iPhone + trình duyệt") asks first for a survey
of what the phone and its browser actually expose. This file is that survey: every
line below was measured on this device (`iPhone10,6`, iOS 16.6 build `20G75`,
rootless bootstrap under `/private/preboot/.../procursus`) on 2026-11-04, with the
command that established it. Where something could **not** be measured, it says so
instead of guessing.

## 1. What the toolbox has

Measured by running each command through the shell tool.

| Tool | State |
| --- | --- |
| `clang` | present (bootstrap, targets arm64-apple-ios16.0) |
| `swiftc` | **absent** — this device cannot compile the app at all; only CI does |
| `gcc`, `cmake`, `ninja`, `xcrun` | absent |
| `make`, `git`, `ldid`, `dpkg-deb` | present |
| `python3` | present (3.9.9) |
| `perl` | present |
| `node` | present (v22.19.0) — the built-in `apelin-device-languages` skill still claims it is missing; that skill needs the correction |
| `/bin/sh` | **absent**; the bootstrap's `.../procursus/bin/sh` is the shell everything runs under |

`WebKit.framework` is present — the engine a browser uses exists on the device. That
does not mean the agent may reach into it: only the process that owns a `WKWebView`
can run JavaScript in it, so DOM-level control of Safari would need a **tweak
injected into MobileSafari**. Apelin does not install one, so the reachable route is
the accessibility tree, and that is what the `apelin_browser` tool (point 3) uses.

## 2. No XCTest, no simulator

Checked by path, all four **absent**:

- `/Developer/Library/Frameworks/XCTest.framework`
- `/Developer/usr/bin/xctest`
- `/usr/lib/libXCTestBundleInject.dylib`
- `/System/Library/PrivateFrameworks/XCTestCore.framework`

Also absent: `simctl`, `iproxy`, `xcodebuild`. There is therefore no on-device XCTest
harness of any kind. A test that runs **on the phone** has to be a program of our own
that drives the phone through `icli` (or through the host's screen operations) and
prints a verdict; Swift unit tests stay on CI. This is why point 5's harness is a
script, not an XCTest bundle.

## 3. A program we compile runs only with `no-sandbox`

```
clang hello.c -o hello      # exit 0
ldid -S hello               # exit 0
./hello                     # Killed: 9  (status 137)
```

Same binary, re-signed with one entitlement at a time:

| Entitlement alone | Result |
| --- | --- |
| `platform-application` | Killed: 9 |
| `com.apple.private.security.no-sandbox` | runs, prints `ok`, exit 0 |
| `get-task-allow` | Killed: 9 |

So a helper built and signed here runs as `mobile` **only** when it carries
`com.apple.private.security.no-sandbox`; the sandbox inherited from the shell kills it
otherwise. The built-in `apelin-device-executables` skill says plain `ldid -S` is
enough — that is wrong on this OS and needs the same correction.

## 4. `icli` reaches the phone, with one gap

`icli --help` lists `device, screen, button, input, app, ui, clipboard, fs, log, url,
pkg, sb, svc, account, env, proc` and answers JSON by default.

```
icli screen info
{"height":812,"locked":false,"orientation":0,"scale":3,"screen_off":false,"width":375}
```

So the display is 375 × 812 points at 3×, unlocked and on — the numbers any
coordinate swipe needs.

The gap is **frontmost verification**. While more than one app is "focal" to
RunningBoard, every screen read and every element tap refuses:

```
icli app frontmost
{"bundle_id":"wiki.qaq.apelin", ... "focal":["com.atebits.Tweetie2","wiki.qaq.apelin"],
 "reason":"several_focal_apps", "verified":false}

icli ui tree --clickable-only
{"error":"failed","message":"frontmost application could not be verified"}

host readUITree(target: com.apple.mobilesafari)
conflict: com.apple.mobilesafari is not the verified foreground app after 3 s
```

`icli app launch com.apple.mobilesafari` answered `{"frontmost":true}`, and the very
next read still refused. A launch that reports success is therefore not proof that a
later read will be allowed.

Consequences that shape the design:

- Safari's own accessibility tree could **not** be measured this session. The
  `apelin_browser` tool must therefore describe what it finds (roles, labels) rather
  than assume a page layout, and it must report this exact message — not "the page is
  empty" — when the read is refused for this reason.
- Anything that works by raw coordinates (`icli screen tap/swipe`) does not need
  frontmost verification, but coordinates have to come from a tree read, which does.
  So the two are not interchangeable: a browser driver built only on coordinates
  would be blind.
- `com.atebits.Tweetie2` stayed in the focal set while the foreground app was Apelin.
  Whether the user can clear this state (bring Twitter to the front once, or
  respring) was not determined; it is a device condition, not a code path.

## 5. What the agent may then use

The agent's own tools reach the phone through the host's fixed operations only —
`readUITree`, `uiAction`, `crashList`, no free-form command — and the host applies the
screen rules there: while Ask Before Using the Screen is on, each read and each action
spends one approval the user granted for exactly that operation and request. A browser
tool built on those operations inherits that consent model for every step it takes,
and cannot be turned into a way around it.

Recorded here so a later session does not re-derive it: the honest ceiling of this
feature is "drive the browser's *screen* — address bar, links, buttons, scrolling,
tabs — and report what changed", not "call the page's JavaScript".