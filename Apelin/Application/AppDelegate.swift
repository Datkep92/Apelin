import AlertController
import ApelinProtocol
import UIKit

/// Apelin is also the gateway's switch: check it as soon as the app opens and
/// whenever a scene comes back. A gateway that died while the app was closed
/// starts again; a switch the reader turned off stays off — a stopped gateway
/// with no saved `since` was never turned off.
@MainActor
private enum GatewayAccessCheck {
    private static let minimumGap: TimeInterval = 15
    private static var lastAttempt: Date?
    private static var inFlight: Task<Void, Never>?

    static func run() {
        let now = Date()
        guard inFlight == nil else { return }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.minimumGap { return }
        lastAttempt = now
        inFlight = Task { @MainActor in
            defer { inFlight = nil }
            do {
                // This is also the early hello: it starts the handshake that
                // would otherwise wait for the first chat request.
                let response = try await ApelinService.app.gatewayStatus()
                let record = response.record
                guard record.state != .dang_chay else { return }
                guard record.enabled || record.since == nil else { return }
                try? await ApelinService.app.gatewaySetEnabled(true)
            } catch {
                // The daemon may still be starting. The next access retries.
            }
        }
    }
}

/// Not `@main`: `main.swift` clears saved scenes before `UIApplicationMain`.
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?,
    ) -> Bool {
        ExecutableWatch.start {
            let alert = UIAlertController(
                title: String(localized: "Apelin Updated or Removed"),
                message: String(localized: "Quit to apply the change, or keep using this version for now."),
                preferredStyle: .alert,
            )
            alert.addAction(UIAlertAction(title: String(localized: "Later"), style: .cancel))
            alert.addAction(UIAlertAction(title: String(localized: "Quit"), style: .destructive) { _ in
                QuietExit.run()
            })
            Self.presentWhenActive(alert, in: application)
        }
        // before anything reads the folder the package made: a build that
        // saved on the container side is brought across by its first launch
        LegacyHome.bringDataAcross()
        AppJournal.start()
        NetworkAccess.start()
        // Warm the backend and the gateway as the app opens, not on first chat.
        GatewayAccessCheck.run()
        ConversationNotices.start()
        // the progress card and the alerts carry the app's icon, as Fila's do
        AlertControllerConfiguration.alertImage = UIImage(named: "AppIconMark")
        // the app's own accent (`AppAccent`); the library's default is red
        AlertControllerConfiguration.accentColor = AppAccent.color(glass: .systemBlue)
        AlertControllerConfiguration.accentForegroundColor = AppAccent.foreground(glass: .white)
        ConsoleLaunch.start()
        return true
    }

    /// A quit takes the Live Activity with it: nothing would update it
    /// after (`ChatWidgetPublisher.endActivitiesForQuit`).
    func applicationWillTerminate(_: UIApplication) {
        ChatWidgetPublisher.endActivitiesForQuit()
    }

    func application(
        _: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options _: UIScene.ConnectionOptions,
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    /// The watch fires once, and may fire with no scene active: at launch,
    /// in the background, or on resume before the scene activates. The
    /// notice then waits for the next activation instead of being lost.
    private static func presentWhenActive(_ alert: UIAlertController, in application: UIApplication) {
        let active = application.connectedScenes.first { $0.activationState == .foregroundActive }
        guard let scene = active as? UIWindowScene else {
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: UIScene.didActivateNotification,
                object: nil,
                queue: .main,
            ) { _ in
                MainActor.assumeIsolated {
                    if let observer {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    presentWhenActive(alert, in: application)
                }
            }
            return
        }
        // In front of whatever the scene shows: a root already presenting a
        // sheet or another alert would drop it.
        guard var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        top.present(alert, animated: true)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo _: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions,
    ) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.tintColor = AppAccent.windowTint
        window.rootViewController = RootInterfaceController()
        window.makeKeyAndVisible()
        self.window = window
        // A cold launch by Open in Apelin or an `apelin://` link: the URL
        // comes with the scene. Opened on the next turn, once the root is on
        // screen to present from.
        DispatchQueue.main.async { [weak self] in self?.openURLs(connectionOptions.urlContexts, in: scene) }
    }

    /// Coming back to Apelin is another chance to check the gateway: a scene
    /// left for hours can find a process that died in the meantime.
    func sceneDidBecomeActive(_: UIScene) {
        GatewayAccessCheck.run()
    }

    /// Open in Apelin, or an `apelin://` link, while the app runs.
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let scene = scene as? UIWindowScene else { return }
        openURLs(contexts, in: scene)
    }

    /// An `apelin://` link goes to its conversation or project
    /// (`ApelinLinkRouter`); anything else is a transfer file, and the
    /// opener refuses what is not one with a notice. One at a time: a
    /// second sheet could not be presented over the first.
    private func openURLs(_ contexts: Set<UIOpenURLContext>, in scene: UIWindowScene) {
        guard let context = contexts.first, !ApelinLinkRouter.open(context.url, in: scene) else { return }
        if CaptureOpener.open(context.url) { return }
        TransferOpener.open(context.url, in: scene)
    }
}
