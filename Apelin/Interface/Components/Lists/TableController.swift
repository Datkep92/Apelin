import UIKit

/// A table view controller whose table is a `FirstFillTableView`: every
/// page that is one table derives from this rather than from
/// `UITableViewController` itself.
class TableController: UITableViewController {
    private let tableStyle: UITableView.Style

    override init(style: UITableView.Style) {
        tableStyle = style
        super.init(style: style)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(style:)")
    }

    override func loadView() {
        let table = FirstFillTableView(frame: .zero, style: tableStyle)
        table.dataSource = self
        table.delegate = self
        tableView = table
    }
}
