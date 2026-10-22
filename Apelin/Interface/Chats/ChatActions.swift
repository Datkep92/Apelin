import AlertController
import UIKit

/// The chat page's `…` menu: Rename… for the conversation, then its
/// project's actions (`ProjectActions`). General Chat has no project, so
/// after Rename… come Open in iGhostVT and Open in Fila for the
/// conversation's own working folder, `Temporary/<conversation>/`.
@MainActor
enum ChatActions {
    static func menu(
        for chat: ChatSummary,
        runtime: ChatRuntime,
        from presenter: UIViewController,
        anchor: UIBarButtonItem,
        onPrepareDistribution: @escaping (String) -> Void,
        completion: @escaping ([UIMenuElement]) -> Void,
    ) {
        let rename = renameAction(for: chat.id, runtime: runtime, from: presenter)
        guard let projectName = chat.projectName else {
            let folders = ProjectActions.folderActions(from: presenter, failureTitle: "Unable to Open Folder") {
                try ProjectActions.temporaryDirectory(of: chat.id)
            }
            completion([
                UIMenu(options: .displayInline, children: [rename]),
                UIMenu(options: .displayInline, children: folders),
            ])
            return
        }
        // Distribute… is read off the project's own manifest each time: one
        // with no build description has nothing to package
        Task { [weak presenter, weak anchor] in
            let project = try? await ProjectSummary.load().first { $0.name == projectName }
            guard let presenter, let anchor else {
                completion([])
                return
            }
            completion(ProjectActions.menu(
                projectName: projectName,
                from: presenter,
                anchor: anchor,
                canDistribute: project?.hasBuildDescription == true,
                renameChat: rename,
                onPrepareDistribution: onPrepareDistribution,
            ).children)
        }
    }

    /// The conversation's name, typed into the alert Rename Project… uses.
    /// It is kept for good: the agent's titles no longer replace it
    /// (`ChatRuntime.rename`).
    private static func renameAction(
        for id: UUID,
        runtime: ChatRuntime,
        from presenter: UIViewController,
    ) -> UIAction {
        UIAction(
            title: String(localized: "Rename…"),
            image: UIImage(systemName: "character.cursor.ibeam"),
        ) { [weak presenter, weak runtime] _ in
            guard let presenter, let runtime, let chat = runtime.records[id]?.summary else { return }
            presenter.present(AlertInputViewController(
                title: "Rename Chat",
                message: "Choose a name for this chat. Your agent will no longer rename it.",
                placeholder: "Chat Name",
                text: chat.displayTitle,
                doneButtonText: "Rename",
                onConfirm: { [weak runtime] name in runtime?.rename(id, to: name) },
            ), animated: true)
        }
    }
}
