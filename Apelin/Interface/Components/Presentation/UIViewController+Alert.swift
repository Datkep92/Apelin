import AlertController
import UIKit

/// The two alerts nearly every page needs, a notice to acknowledge and a
/// question to answer, and a line of text to type. Irisin's.
///
/// AlertController runs `String(localized:)` on every title and message it
/// is given, against this app's `Localizable.xcstrings`. Pass the English
/// catalogue key, never already-localized text; the `String` overloads are
/// for text that is dynamic (an error's description), which misses the
/// catalogue and comes back as it is. A literal handed straight to
/// AlertController never reaches the catalogue either: Xcode's extractor
/// only sees one passed to a function declared in this module.
extension UIViewController {
    func presentNotice(
        title: String.LocalizationValue,
        message: String.LocalizationValue,
        dismissTitle: String.LocalizationValue = "Dismiss",
        onDismiss: @escaping () -> Void = {},
    ) {
        present(AlertViewController(title: title, message: message) { context in
            context.addAction(title: dismissTitle) {
                context.dispose { onDismiss() }
            }
        }, animated: true)
    }

    @_disfavoredOverload
    func presentNotice(
        title: String.LocalizationValue,
        message: String,
        dismissTitle: String.LocalizationValue = "Dismiss",
        onDismiss: @escaping () -> Void = {},
    ) {
        presentNotice(
            title: title,
            message: String.LocalizationValue(message),
            dismissTitle: dismissTitle,
            onDismiss: onDismiss,
        )
    }

    /// `destructive` paints the alert in the delete colour, the filled
    /// confirming button and the outlined Cancel. The library has one accent
    /// for all and reads it while the alert is built, so the swap lasts
    /// exactly that long.
    func presentConfirmation(
        title: String.LocalizationValue,
        message: String.LocalizationValue,
        confirmTitle: String.LocalizationValue = "Confirm",
        destructive: Bool = false,
        onConfirm: @escaping () -> Void,
    ) {
        let accent = AlertControllerConfiguration.accentColor
        if destructive {
            AlertControllerConfiguration.accentColor = .systemRed
        }
        let alert = AlertViewController(title: title, message: message) { context in
            context.addAction(title: "Cancel") {
                context.dispose()
            }
            context.addAction(title: confirmTitle, attribute: .accent) {
                context.dispose { onConfirm() }
            }
        }
        AlertControllerConfiguration.accentColor = accent
        present(alert, animated: true)
    }

    func presentTextInput(
        title: String.LocalizationValue,
        message: String.LocalizationValue,
        placeholder: String.LocalizationValue,
        doneTitle: String.LocalizationValue,
        onConfirm: @escaping @MainActor (String) -> Void,
    ) {
        present(AlertInputViewController(
            title: title,
            message: message,
            placeholder: placeholder,
            text: "",
            doneButtonText: doneTitle,
            onConfirm: onConfirm,
        ), animated: true)
    }
}
