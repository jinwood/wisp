import AppKit

@MainActor
final class ChatListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((ChatRow) -> Void)?

    private let store: MessageStore
    private var chats: [ChatRow] = []
    private var selectedJID: String?
    private var suppressSelection = false
    private let tableView = NSTableView()

    init(store: MessageStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        tableView.addTableColumn(NSTableColumn(identifier: .init("chat")))
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowHeight = 54
        tableView.dataSource = self
        tableView.delegate = self

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
    }

    /// Re-queries the chat list. A few hundred indexed rows: well under a millisecond.
    func reload() {
        loadViewIfNeeded()
        let fresh = store.chats()
        guard fresh != chats else { return }
        chats = fresh
        suppressSelection = true
        tableView.reloadData()
        if let selectedJID, let row = chats.firstIndex(where: { $0.jid == selectedJID }) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        suppressSelection = false
    }

    func reset() {
        selectedJID = nil
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { chats.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ChatCell.identifier, owner: nil) as? ChatCell ?? ChatCell()
        cell.configure(chats[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < chats.count else { return }
        selectedJID = chats[row].jid
        onSelect?(chats[row])
    }
}

private final class ChatCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ChatCell")

    private let title = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let preview = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        time.font = .systemFont(ofSize: 11)
        time.textColor = .secondaryLabelColor
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        preview.font = .systemFont(ofSize: 12)
        preview.textColor = .secondaryLabelColor
        preview.lineBreakMode = .byTruncatingTail
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 8
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let top = NSStackView(views: [title, time])
        let bottom = NSStackView(views: [preview, badge])
        let stack = NSStackView(views: [top, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
            badge.heightAnchor.constraint(equalToConstant: 16),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ chat: ChatRow) {
        let unread = chat.unread != 0
        title.stringValue = (chat.isPinned ? "📌 " : "") + chat.title
        title.font = .systemFont(ofSize: 13, weight: unread ? .semibold : .regular)
        time.stringValue = chat.lastTs > 0 ? relativeTime(chat.lastTs) : ""
        preview.stringValue = chat.preview
        badge.isHidden = !unread
        badge.stringValue = chat.unread > 0 ? " \(chat.unread) " : " "
        badge.textColor = .white
        badge.layer?.backgroundColor = (chat.isMuted ? NSColor.systemGray : NSColor.controlAccentColor).cgColor
    }
}

func relativeTime(_ ts: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(ts))
    let cal = Calendar.current
    if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    if let days = cal.dateComponents([.day], from: date, to: .now).day, days < 7 {
        return date.formatted(.dateTime.weekday(.wide))
    }
    return date.formatted(date: .numeric, time: .omitted)
}
