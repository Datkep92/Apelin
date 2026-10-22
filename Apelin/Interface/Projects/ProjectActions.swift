import AlertController
import ApelinCore
import ApelinProtocol
import UIKit

/// Actions for the project behind the current chat. Folder names are stable
/// identities; links are made from their canonical path, never an install prefix.
@MainActor
enum ProjectActions {
    /// `onPrepareDistribution` sends the distribution page's request to the
    /// project's conversation.
    static func menu(
        projectName: String,
        from presenter: UIViewController,
        anchor: UIBarButtonItem,
        onPrepareDistribution: ((String) -> Void)? = nil,
    ) -> UIMenu {
        let terminal = UIAction(
            title: String(localized: "Open in iGhostVT"),
            image: UIImage(systemName: "terminal"),
        ) { [weak presenter] _ in
            guard let presenter else { return }
            open(projectName, in: "ighostvt", from: presenter)
        }
        let files = UIAction(
            title: String(localized: "Open in Fila"),
            image: UIImage(systemName: "folder"),
        ) { [weak presenter] _ in
            guard let presenter else { return }
            open(projectName, in: "fila", from: presenter)
        }
        let renameAction = UIAction(
            title: String(localized: "Rename Project…"),
            image: UIImage(systemName: "pencil"),
        ) { [weak presenter] _ in
            guard let presenter else { return }
            rename(projectName, from: presenter)
        }
        let export = UIAction(
            title: String(localized: "Export…"),
            image: UIImage(systemName: "square.and.arrow.up"),
        ) { [weak presenter, weak anchor] _ in
            guard let presenter, let anchor else { return }
            TransferExporter.confirmAndExport(
                kind: .project,
                id: projectName,
                name: projectName,
                from: presenter,
                anchor: anchor,
            )
        }
        let distribute = UIAction(
            title: String(localized: "Distribute…"),
            image: UIImage(systemName: "shippingbox"),
        ) { [weak presenter] _ in
            presenter?.presentPageAsFormSheet(
                ProjectDistributionController(projectName: projectName, onPrepare: onPrepareDistribution),
            )
        }
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: [renameAction]),
            UIMenu(options: .displayInline, children: [terminal, files]),
            UIMenu(options: .displayInline, children: [export, distribute]),
        ])
    }

    static func rename(_ projectName: String, from presenter: UIViewController) {
        Task { [weak presenter] in
            guard let presenter else { return }
            let current = try? await ProjectSummary.load().first { $0.name == projectName }
            presenter.present(AlertInputViewController(
                title: "Rename Project",
                message: "Choose a display name. The project folder and build settings stay the same.",
                placeholder: "Project Name",
                text: current?.displayTitle ?? projectName,
                doneButtonText: "Rename",
                onConfirm: { [weak presenter] name in
                    Task { [weak presenter] in
                        do {
                            _ = try await ApelinService.app.projectRename(.init(
                                projectID: current?.projectID ?? projectName,
                                displayName: name,
                            ))
                            NotificationCenter.default.post(name: .apelinProjectsChanged, object: nil)
                        } catch {
                            presenter?.presentNotice(title: "Unable to Rename Project", message: error.readableMessage)
                        }
                    }
                },
            ), animated: true)
        }
    }

    static func directory(named name: String) throws -> String {
        guard let folder = DataFolder.app.project(named: name),
              let projects = CanonicalPath.resolve(DataFolder.app.projects.path),
              let path = CanonicalPath.resolve(folder.path),
              path == projects + "/" + name
        else {
            throw ApelinError(.notFound, String(localized: "The project folder is no longer available."))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ApelinError(.notFound, String(localized: "The project folder is no longer available."))
        }
        return path
    }

    private static func open(_ name: String, in scheme: String, from presenter: UIViewController) {
        do {
            let path = try directory(named: name)
            var components = URLComponents()
            components.scheme = scheme
            components.host = scheme == "fila" ? "open" : "new"
            components.queryItems = scheme == "fila"
                ? [URLQueryItem(name: "path", value: path), URLQueryItem(name: "tab", value: "new")]
                : [URLQueryItem(name: "directory", value: path)]
            guard let url = components.url else { return }
            UIApplication.shared.open(url) { [weak presenter] opened in
                guard !opened, let presenter else { return }
                presenter.presentNotice(title: "Unable to Open App", message: String(localized: "Install or update the required app with your preferred package manager, then try again."))
            }
        } catch {
            presenter.presentNotice(title: "Unable to Open Project", message: error.readableMessage)
        }
    }
}
