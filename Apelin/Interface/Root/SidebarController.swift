import SnapKit
import Then
import UIKit

/// The sidebar: beside the detail column when the window is wide, a
/// drawer under it when narrow (`RootInterfaceController`). Its bar: the open project's name as a plain title,
/// a folder menu that switches projects or opens the picker, and
/// a plus that makes a new project, with a search field under it that a
/// pull on the list brings out; the button that hides the sidebar is on
/// the detail column's bar. With no project open the title is Apelin's,
/// with no menu, and a new conversation is a temporary one, kept apart from
/// every project's. Below it the project's conversations, a plain inset
/// grouped table: the pinned ones, then the rest under the day they were
/// last active. At the bottom a new conversation on the
/// left, and Projects beside Settings on the right: glass on iOS 26, the toolbar's blur
/// before it.
final class SidebarController: UIViewController {
    private enum Section: Hashable {
        case pinned
        case day(Date)
    }

    /// The conversation to show, as it is picked, made or deleted: nil when
    /// none is left picked. `picked` when the reader chose it, by its row or
    /// New Chat, which puts a drawer away; a conversation that follows a
    /// project switch, a deletion or the launch changes behind it.
    var onSelect: ((ChatSummary?, _ picked: Bool) -> Void)?
    var onProjectsLoaded: (() -> Void)?
    /// A message to send in the conversation just picked, as if typed.
    var onSendPrompt: ((String) -> Void)?
    private(set) var hasLoadedProjects = false
    var runtime: ChatRuntime!

    func select(_ summary: ChatSummary) {
        if project?.name != summary.projectName {
            project = summary.projectName.map { name in
                projects.first { $0.name == name } ?? ProjectSummary(name: name, kind: .workspace)
            }
        }
        UserDefaults.standard.set(summary.projectName, forKey: "chat.selectedProject")
        selectedID = summary.id
        applySnapshot()
        onSelect?(summary, false)
    }

    func refresh() {
        let previous = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })
        chats = runtime.summaries.filter { $0.projectName == project?.name }
        let changedRows = chats.compactMap { chat -> UUID? in
            guard let old = previous[chat.id],
                  old.title != chat.title || old.isWorking != chat.isWorking
            else { return nil }
            return chat.id
        }
        if isViewLoaded {
            applySnapshot(changedRows: changedRows, restoreSelection: false)
        }
    }

    /// The projects in `Projects/`, once the host lists them; none until then.
    private var projects: [ProjectSummary] = []
    private let projectMonitor = ProjectCatalogMonitor()
    private let pacing = ListPacing()

    /// The open project's conversations; what is picked among them is
    /// `switchProject(to:)`'s, or the launch's to restore.
    private var project: ProjectSummary? {
        didSet {
            UserDefaults.standard.set(project?.name, forKey: "chat.selectedProject")
            showProject()
            guard oldValue?.name != project?.name else { return }
            // another project's list replaces this one; it is not a change
            pacing.begin()
            refresh()
        }
    }

    /// Opens `candidate` on its most recent conversation, or none when it
    /// has none yet.
    private func switchProject(to candidate: ProjectSummary?) {
        guard candidate?.name != project?.name else {
            project = candidate
            return
        }
        project = candidate
        selectedID = chats.max { $0.updated < $1.updated }?.id
        applySnapshot()
        onSelect?(selectedID.flatMap(chat), false)
    }

    /// The open project's conversations, as the runtime lists them.
    private var chats: [ChatSummary] = []

    /// What the search field holds; the list shows the conversations whose
    /// title has it, ignoring case and diacritics.
    private var query = ""

    private lazy var searchController = UISearchController(searchResultsController: nil).then {
        $0.searchResultsUpdater = self
        $0.obscuresBackgroundDuringPresentation = false
        $0.searchBar.placeholder = String(localized: "Search chats")
    }

    /// The picked conversation, kept across a change to the list, which
    /// moves rows between sections and would drop the table's selection.
    private var selectedID: UUID?

    /// "Today" and "Yesterday" in the reader's language.
    private static let relativeDayFormatter = DateFormatter().then {
        $0.dateStyle = .medium
        $0.timeStyle = .none
        $0.doesRelativeDateFormatting = true
    }

    private lazy var newChatButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.title = String(localized: "New Chat")
        configuration.image = UIImage(systemName: "square.and.pencil")
        // the symbol at the text's own size and weight, not a step above it
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: font, scale: .small)
        configuration.imagePadding = 6
        configuration.baseForegroundColor = .label
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = font
            return attributes
        }
        return UIButton(
            configuration: configuration,
            primaryAction: UIAction { [weak self] _ in self?.startNewChat() },
        )
    }()

    private lazy var projectMenuButton: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "folder"),
            menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.projectMenu().children ?? [])
            }]),
        )
        item.preferredMenuElementOrder = .fixed
        item.accessibilityLabel = String(localized: "Projects")
        return item
    }()

    /// The system's inset grouped list, cells, headers and selection as
    /// they come.
    private let tableView = FirstFillTableView(frame: .zero, style: .insetGrouped).then {
        $0.backgroundColor = .panelBackground
        $0.register(UITableViewCell.self, forCellReuseIdentifier: "chat")
        // The first conversation is picked at launch, and after that a tap
        // picks: in a primary column the selection would otherwise follow
        // a keyboard's focus.
        $0.selectionFollowsFocus = false
        // the symbol alone; the words are for VoiceOver
        $0.backgroundView = EmptyStateView(
            symbolName: "bubble.left.and.bubble.right.fill",
            text: String(localized: "No chats yet. Tap New Chat to start one."),
            showsText: false,
        )
    }

    /// A picked row's ground, lighter than the system's: black at 0.1 in
    /// the light, white at 0.1 in the dark (owner, 2026-10-21).
    private static let selectionColor = UIColor(
        light: UIColor.black.withAlphaComponent(0.1),
        dark: UIColor.white.withAlphaComponent(0.1),
    )

    /// The rows are conversation IDs.
    private lazy var dataSource = SwipeableTableDataSource<Section, UUID>(
        tableView: tableView,
    ) { [unowned self] tableView, indexPath, id in
        let cell = tableView.dequeueReusableCell(withIdentifier: "chat", for: indexPath)
        let summary = chat(id)
        var content = UIListContentConfiguration.cell()
        content.text = summary?.title
        content.textProperties.numberOfLines = 1
        cell.contentConfiguration = content
        let isWorking = summary?.isWorking == true
        if isWorking {
            let indicator = cell.accessoryView as? UIActivityIndicatorView ?? UIActivityIndicatorView(style: .medium)
            indicator.isAccessibilityElement = false
            indicator.startAnimating()
            cell.accessoryView = indicator
        } else {
            (cell.accessoryView as? UIActivityIndicatorView)?.stopAnimating()
            cell.accessoryView = nil
        }
        cell.isAccessibilityElement = true
        cell.accessibilityValue = isWorking ? String(localized: "Working") : nil
        cell.configurationUpdateHandler = { cell, state in
            var background = UIBackgroundConfiguration.listGroupedCell().updated(for: state)
            if state.isSelected || state.isHighlighted {
                background.backgroundColor = Self.selectionColor
            }
            cell.backgroundConfiguration = background
        }
        return cell
    }.then {
        $0.sectionTitle = { Self.title(for: $0) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        projectMonitor.start()
        view.backgroundColor = .panelBackground

        // The project name stays at the leading edge; the folder owns switching.
        navigationItem.style = .editor
        // under the bar, hidden until the list is pulled down
        navigationItem.preferredSearchBarPlacement = .stacked
        navigationItem.hidesSearchBarWhenScrolling = true
        // New Project stays in the top bar; project switching lives below.
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                image: UIImage(systemName: "plus"),
                primaryAction: UIAction { [weak self] _ in self?.openNewProject() },
            ).then { $0.accessibilityLabel = String(localized: "New Project") },
        ]
        showProject()
        refresh()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(projectsChanged),
            name: .apelinProjectsChanged,
            object: nil,
        )
        Task { await refreshProjects() }
        toolbarItems = [
            UIBarButtonItem(customView: newChatButton),
            .flexibleSpace(),
            projectMenuButton,
            UIBarButtonItem(
                image: UIImage(systemName: "gearshape"),
                primaryAction: UIAction { [weak self] _ in self?.presentPageAsFormSheet(SettingsViewController()) },
            ).then { $0.accessibilityLabel = String(localized: "Settings") },
        ]

        tableView.delegate = self
        // a row that arrives fades in where it belongs, rather than sliding
        dataSource.defaultRowAnimation = .fade
        view.addSubview(tableView)
        // the list the bar watches, for the pull that brings out the search;
        // an empty or short one still gives way to the pull
        setContentScrollView(tableView)
        tableView.alwaysBounceVertical = true
        tableView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
        applySnapshot()
    }

    /// A search controller given before the bar is first shown is shown
    /// with it, whatever `hidesSearchBarWhenScrolling` says; given after,
    /// it starts tucked away.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if navigationItem.searchController == nil {
            navigationItem.searchController = searchController
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    // MARK: - The list

    private func chat(_ id: UUID) -> ChatSummary? {
        chats.first { $0.id == id }
    }

    private func applySnapshot(changedRows: [UUID] = [], restoreSelection: Bool = true) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, UUID>()
        let shown = query.isEmpty ? chats : chats.filter {
            $0.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let newestFirst = shown.sorted { $0.updated > $1.updated }
        let pinned = newestFirst.filter(\.isPinned)
        if !pinned.isEmpty {
            snapshot.appendSections([.pinned])
            snapshot.appendItems(pinned.map(\.id))
        }
        let calendar = Calendar.current
        let days = Dictionary(grouping: newestFirst.filter { !$0.isPinned }) { calendar.startOfDay(for: $0.updated) }
        for (day, rows) in days.sorted(by: { $0.key > $1.key }) {
            snapshot.appendSections([.day(day)])
            snapshot.appendItems(rows.map(\.id))
        }
        let current = dataSource.snapshot()
        let old = Set(current.itemIdentifiers)
        let reconfigured = changedRows.filter { old.contains($0) && snapshot.indexOfItem($0) != nil }
        snapshot.reconfigureItems(reconfigured)
        let hasChanges = !reconfigured.isEmpty || current.sectionIdentifiers != snapshot.sectionIdentifiers
            || current.itemIdentifiers != snapshot.itemIdentifiers
        // Streamed text changes the runtime timestamp on every batch, but it
        // must not rebuild an unchanged row while its swipe actions are open.
        tableView.backgroundView?.isHidden = !shown.isEmpty
        guard tableView.isFilled else {
            pacing.begin()
            dataSource.applyFirst(snapshot, to: tableView) { [weak self] in self?.selectPicked() }
            return
        }
        if hasChanges {
            dataSource.applyChange(snapshot, to: tableView, animated: pacing.animatesChange(in: tableView))
        }
        if hasChanges || restoreSelection {
            selectPicked()
        }
    }

    private func selectPicked() {
        if let selectedID, let indexPath = dataSource.indexPath(for: selectedID) {
            tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
        }
    }

    /// An empty conversation at the top of today, picked and shown: the
    /// project's untouched one if it has one, so empty rows never pile up.
    func startNewChat(picked: Bool = true) {
        let chat = runtime.newChat(project: project?.name, preferring: selectedID)
        refresh()
        selectedID = chat.id
        applySnapshot()
        onSelect?(chat, picked)
        // only when it is out of sight: scrolling the list moves the bar's
        // hidden search field too, and left it half drawn
        if let indexPath = dataSource.indexPath(for: chat.id),
           tableView.indexPathsForVisibleRows?.contains(indexPath) != true
        {
            tableView.scrollToRow(at: indexPath, at: .none, animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }

    private func togglePin(_ id: UUID) {
        runtime.togglePin(id)
        refresh()
    }

    private func stop(_ id: UUID) {
        Task {
            do { try await runtime.stop(id) }
            catch { presentNotice(title: "Unable to Stop", message: error.readableMessage) }
        }
    }

    private func delete(_ id: UUID) {
        Task {
            do {
                try await runtime.delete(id)
                if selectedID == id {
                    selectedID = nil; onSelect?(nil, false)
                }
                refresh()
            } catch { presentNotice(title: "Unable to Delete Chat", message: error.readableMessage) }
        }
    }

    /// Pinned, then Today, Yesterday, the weekday within the week, then the date.
    private static func title(for section: Section) -> String {
        let now = Date()
        guard case let .day(day) = section else { return String(localized: "Pinned") }
        let calendar = Calendar.current
        if calendar.isDateInToday(day) || calendar.isDateInYesterday(day) {
            return relativeDayFormatter.string(from: day)
        }
        let age = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: now)).day ?? .max
        if age < 7 {
            return day.formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(day, equalTo: now, toGranularity: .year) {
            return day.formatted(.dateTime.month(.abbreviated).day())
        }
        return day.formatted(.dateTime.year().month(.abbreviated).day())
    }

    // MARK: - The project

    private func showProject() {
        title = project?.displayTitle ?? String(localized: "Apelin")
        projectMenuButton.image = project.flatMap { ProjectIcon.menuImage(for: $0) } ?? UIImage(systemName: "folder")
        projectMenuButton.accessibilityValue = project?.displayTitle ?? String(localized: "General Chat")
    }

    /// The projects to switch to, the open one ticked, and the picker,
    /// which also makes a new one.
    private func projectMenu() -> UIMenu {
        let switches = projects.map { candidate in
            UIAction(
                title: candidate.displayTitle,
                state: candidate == project ? .on : .off,
            ) { [weak self] _ in
                self?.switchProject(to: candidate)
            }
        }
        let general = UIAction(
            title: String(localized: "General Chat"),
            state: project == nil ? .on : .off,
        ) { [weak self] _ in self?.switchProject(to: nil) }
        let allProjects = UIAction(title: String(localized: "All Projects…")) { [weak self] _ in
            self?.openProjectPicker()
        }
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: [general]),
            UIMenu(options: .displayInline, children: switches),
            UIMenu(options: .displayInline, children: [allProjects]),
        ])
    }

    @objc private func projectsChanged() {
        Task { await refreshProjects() }
    }

    private func refreshProjects() async {
        do {
            projects = try await ProjectSummary.load()
            if let name = project?.name, let resolved = projects.first(where: { $0.name == name }),
               resolved != project
            {
                project = resolved
            } else if let name = UserDefaults.standard.string(forKey: "chat.selectedProject"),
                      let saved = projects.first(where: { $0.name == name }), project == nil
            {
                project = saved
            }
            showProject()
            if !hasLoadedProjects {
                hasLoadedProjects = true
                onProjectsLoaded?()
            }
        } catch { presentNotice(title: "Projects Unavailable", message: error.readableMessage) }
    }

    private func openNewProject() {
        let page = NewProjectController()
        page.onCreate = { [weak self] project, firstPrompt in
            self?.openCreatedProject(project, firstPrompt: firstPrompt)
        }
        presentPageAsFormSheet(page)
    }

    /// Opens a project just made on a new conversation, which sends
    /// `firstPrompt` when there is one.
    func openCreatedProject(_ project: ProjectSummary, firstPrompt: String? = nil) {
        projects.removeAll { $0.name == project.name }
        projects.append(project)
        self.project = project
        startNewChat()
        if let firstPrompt {
            onSendPrompt?(firstPrompt)
        }
    }

    private func openProjectPicker() {
        let picker = ProjectPickerController(projects: projects, current: project?.name)
        picker.onPick = { [weak self] project in self?.switchProject(to: project) }
        picker.onCreate = { [weak self] project, firstPrompt in
            self?.openCreatedProject(project, firstPrompt: firstPrompt)
        }
        picker.onDelete = { [weak self] project in
            guard let self else { return }
            try await runtime.deleteProject(project.name)
            projects.removeAll { $0.name == project.name }
            if self.project?.name == project.name {
                switchProject(to: nil)
            }
            showProject()
            NotificationCenter.default.post(name: .apelinProjectsChanged, object: nil)
        }
        presentPageAsFormSheet(picker)
    }
}

extension SidebarController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let text = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        guard text != query else { return }
        query = text
        pacing.begin()
        applySnapshot()
    }
}

extension SidebarController: UITableViewDelegate {
    /// Again on the row already picked, which puts a drawer away.
    func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        selectedID = dataSource.itemIdentifier(for: indexPath)
        onSelect?(selectedID.flatMap(chat), true)
    }

    // MARK: Pin and delete

    func tableView(
        _: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let chat = chat(id) else { return nil }
        let pin = UIContextualAction(
            style: .normal,
            title: chat.isPinned ? String(localized: "Unpin") : String(localized: "Pin"),
        ) { [weak self] _, _, completion in
            // the swipe's own transaction has to end for the row to settle
            completion(true)
            self?.togglePin(id)
        }
        pin.image = UIImage(systemName: chat.isPinned ? "pin.slash.fill" : "pin.fill")
        pin.backgroundColor = .systemOrange
        return UISwipeActionsConfiguration(actions: [pin])
    }

    func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let chat = chat(id) else { return nil }
        let delete = UIContextualAction(
            style: .destructive,
            title: String(localized: "Delete"),
        ) { [weak self] _, _, completion in
            // The snapshot removes the row only after deletion succeeds.
            completion(false)
            self?.delete(id)
        }
        delete.image = UIImage(systemName: "trash.fill")
        guard chat.isWorking else { return UISwipeActionsConfiguration(actions: [delete]) }
        let stop = UIContextualAction(
            style: .normal,
            title: String(localized: "Stop"),
        ) { [weak self] _, _, completion in
            completion(true)
            self?.stop(id)
        }
        stop.image = UIImage(systemName: "stop.fill")
        stop.backgroundColor = .darkGray
        let actions = UISwipeActionsConfiguration(actions: [delete, stop])
        actions.performsFirstActionWithFullSwipe = false
        return actions
    }

    /// A swipe that ends after the list changed under it, as deleting the
    /// picked conversation does, leaves no row highlighted.
    func tableView(_: UITableView, didEndEditingRowAt _: IndexPath?) {
        applySnapshot()
    }

    /// The swipes' two actions, for a long press and a pointer.
    func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let chat = chat(id) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let pin = UIAction(
                title: chat.isPinned ? String(localized: "Unpin") : String(localized: "Pin"),
                image: UIImage(systemName: chat.isPinned ? "pin.slash" : "pin"),
            ) { _ in self?.togglePin(id) }
            let delete = UIAction(
                title: String(localized: "Delete"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive,
            ) { _ in self?.delete(id) }
            var actions = [pin, delete]
            if chat.isWorking {
                actions.insert(
                    UIAction(
                        title: String(localized: "Stop"),
                        image: UIImage(systemName: "stop.fill"),
                    ) { _ in self?.stop(id) },
                    at: 0,
                )
            }
            return UIMenu(children: actions)
        }
    }
}

/// A diffable table data source whose rows can be swiped: UIKit offers a
/// row's swipe actions only when its data source calls it editable, and a
/// diffable one says no unless it is told otherwise. Xrash's, with each
/// section's header title from `sectionTitle`.
final class SwipeableTableDataSource<Section: Hashable, Item: Hashable>:
    UITableViewDiffableDataSource<Section, Item>
{
    var sectionTitle: ((Section) -> String?)?

    override func tableView(_: UITableView, canEditRowAt _: IndexPath) -> Bool {
        true
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        sectionIdentifier(for: section).flatMap { sectionTitle?($0) }
    }
}
