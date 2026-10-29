import AlertController
import ApelinProtocol
import SPIndicator
import UIKit

/// Once the reader has signed in with GitHub, the tenth build that
/// completes asks whether they like Apelin, and Star Now stars its
/// repository with that sign-in (owner, 2026-10-29). Only builds that
/// complete while the sign-in is there count: a conversation's
/// (`CompletedBuilds`) and the distribution page's. It asks once: an
/// account that has starred Apelin already is never asked, and Maybe Later
/// is an answer too. When it cannot ask yet — the app is in the background,
/// another alert is up, GitHub did not answer — or Star Now did not get
/// through, the next build tries again.
@MainActor
enum StarPrompt {
    static let buildsBeforeAsking = 10

    private static let buildsKey = "starPrompt.builds"
    private static let askedKey = "starPrompt.asked"
    /// GitHub is being asked whether there is a star already, so a build
    /// completing meanwhile does not ask twice.
    private static var isChecking = false

    /// The builds that completed while the reader was signed in with GitHub.
    private static var builds: Int {
        get { UserDefaults.standard.integer(forKey: buildsKey) }
        set { UserDefaults.standard.set(newValue, forKey: buildsKey) }
    }

    private static var asked: Bool {
        get { UserDefaults.standard.bool(forKey: askedKey) }
        set { UserDefaults.standard.set(newValue, forKey: askedKey) }
    }

    /// `count` builds completed; the prompt goes over whatever is on top of
    /// `controller`'s window.
    static func buildsCompleted(_ count: Int, from controller: UIViewController) {
        guard count > 0, !asked else { return }
        Task { [weak controller] in
            guard await isSignedInWithGitHub() else { return }
            builds += count
            guard builds >= buildsBeforeAsking, !asked, !isChecking else { return }
            isChecking = true
            defer { isChecking = false }
            guard let state = try? await ApelinService.app.feedbackStarState() else { return }
            guard !state.starred else {
                asked = true
                return
            }
            guard let page = controller.flatMap({ topPage(over: $0) }) else { return }
            page.presentConfirmation(
                title: "Do You Like Apelin?",
                message: "Please star us on GitHub. It helps us go further.",
                cancelTitle: "Maybe Later",
                confirmTitle: "Star Now",
            ) {
                star(from: page)
            }
            // asked only once UIKit took the alert: one it refused asks again
            if page.presentedViewController is AlertBaseController {
                asked = true
            }
        }
    }

    private static func isSignedInWithGitHub() async -> Bool {
        guard let settings = try? await ApelinService.app.gitSettings() else { return false }
        return settings.credentials.contains { $0.host == GitHubDeviceFlow.host }
    }

    private static func star(from page: UIViewController) {
        Task {
            do {
                _ = try await ApelinService.app.feedbackStar()
                let star = UIImage(systemName: "star.fill")?.withTintColor(.systemYellow, renderingMode: .alwaysOriginal)
                SPIndicator.present(
                    title: String(localized: "Thank You"),
                    message: String(localized: "Starred on GitHub"),
                    preset: star.map { .custom($0) } ?? .done,
                    haptic: .success,
                )
            } catch {
                // GitHub refusing the star is an answer; a lost connection,
                // or a sign-in to make again, is asked about with a later build
                let refused = (error as? ApelinError).map { $0.code == .denied && $0.reason != .authenticationRequired }
                if refused != true {
                    asked = false
                }
                (topPage(over: page) ?? page).presentNotice(title: "Unable to Star Apelin", message: error.readableMessage)
            }
        }
    }

    /// The page at the top of `controller`'s window, while the app is in
    /// front and nothing is coming or going there; never an alert, so one
    /// question is asked at a time.
    private static func topPage(over controller: UIViewController) -> UIViewController? {
        guard UIApplication.shared.applicationState == .active,
              var page = controller.view.window?.rootViewController
        else { return nil }
        while let presented = page.presentedViewController {
            guard !presented.isBeingDismissed else { return nil }
            page = presented
        }
        guard !page.isBeingPresented, !(page is AlertBaseController), !(page is UIAlertController) else { return nil }
        return page
    }
}
