extension BuiltInSkills {
    static let preferenceBundle = SkillDocument(
        name: "preference-bundle",
        description: "A Settings pane for a tweak: the PSListController subclass, Root.plist specifiers, the PreferenceLoader entry, the preferences domain it stores to, and how the tweak reads the same setting.",
        body: """
        # A preference bundle

        A tweak's settings live in a preference bundle that PreferenceLoader
        shows inside the Settings app. Start from the Objective-C Preference
        Bundle template (`kind: preferences`); it is the shape below.

        ## The pieces
        - **The principal class** is a `PSListController` subclass (its name
          is the bundle's `NSPrincipalClass`). It loads its rows from
          `Root.plist` and lets the framework read and write the values:
          ```objc
          #import <Preferences/PSListController.h>
          @interface MyRootListController : PSListController
          @end
          @implementation MyRootListController
          - (NSArray *)specifiers {
              if (_specifiers == nil) {
                  _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
              }
              return _specifiers;
          }
          @end
          ```
          Cache in the framework's own `_specifiers` ivar, not a static, so a
          second showing reloads. Let `PSListController` read and write
          values through `readPreferenceValue:`/`setPreferenceValue:`; do not
          override them with NSUserDefaults. The `Preferences` framework is
          private: it is reached through the preferences extension's support
          component (project-description), which supplies the declarations and
          a link stub — do not expect SDK headers for it.
        - **Root.plist** is `items`, an array of specifiers, each a `cell`
          plus its keys:
          - `PSGroupCell` — a section header with `label` and optional
            `footerText`.
          - `PSSwitchCell` — a bool: `label`, `key`, `default`, `defaults`
            (the preferences domain), `PostNotification`.
          - `PSEditTextCell` — a string: the same keys.
          Other cells exist (`PSSliderCell`, `PSLinkListCell` with its value
          list, `PSButtonCell`, `PSLinkCell` for a child pane). `defaults` on
          a row is the domain the value is stored in — the package id — and
          `PostNotification` is the Darwin name posted after a change.
        - **The PreferenceLoader entry** is a plist at
          `/Library/PreferenceLoader/Preferences/<Name>.plist` with one
          `entry` dictionary: `bundle` (the bundle's name), `detail` (the
          controller class), `cell` `PSLinkCell`, `isController` true,
          `label` (the Settings row). The package depends on
          `preferenceloader`.
        - **The bundle Info.plist** names `NSPrincipalClass` and
          `CFBundlePackageType` `BNDL`.

        ## How the tweak reads it
        The pane writes the value into the package's preferences domain and
        posts `<package id>/changed`. The tweak reads that domain and listens
        for that name, as the tweak-runtime skill describes. Keep the row's
        `defaults`, the tweak's domain and the notification name the same
        string — the package id — on both sides.

        ## Layout
        - The bundle: `/Library/PreferenceBundles/<Name>.bundle` (a `bundle`
          product, with a `bundle-resources` step and `resources`:
          `Resources/Root.plist`).
        - The entry: `/Library/PreferenceLoader/Preferences/<Name>.plist`, a
          `{path, file}` layout entry, mode `0644`.
        Settings reads the row at launch; a change to the entry or the bundle
        shows after Settings is relaunched.
        """,
    )
}
