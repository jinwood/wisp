import AppKit

/// Message timeline for one chat. Holds a window of rows paged in from SQLite
/// (newest page on open, older pages on scroll-up), freed when switching chats.
/// Row heights are measured once per message per width bucket and cached, so
/// scrolling never lays out text.
@MainActor
final class TimelineViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let pageSize = 200

    private let store: MessageStore
    private var chat: ChatRow?
    private var messages: [MessageRow] = []
    private var hasOlder = false
    private var layouts: [Int64: BubbleLayout] = [:]
    private var layoutWidth: CGFloat = 0

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let input = NSTextField()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let placeholder = NSTextField(labelWithString: "Select a chat")

    init(store: MessageStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Chat switching and updates

    func show(_ chat: ChatRow) {
        loadViewIfNeeded()
        self.chat = chat
        messages = store.messages(chat: chat.jid, before: nil, limit: Self.pageSize)
        hasOlder = messages.count == Self.pageSize
        layouts.removeAll(keepingCapacity: true)
        tableView.reloadData()
        scrollToBottom()
        placeholder.isHidden = true
        input.isEnabled = true
        sendButton.isEnabled = true
        input.placeholderString = "Message \(chat.title)"
        view.window?.makeFirstResponder(input)
        if chat.unread != 0 { Core.shared.markRead(chat: chat.jid) }
    }

    func reset() {
        loadViewIfNeeded()
        chat = nil
        messages = []
        hasOlder = false
        layouts.removeAll()
        tableView.reloadData()
        placeholder.isHidden = false
        input.isEnabled = false
        sendButton.isEnabled = false
        input.placeholderString = "Message"
    }

    func chatsChanged(_ jids: Set<String>?) {
        guard let chat, jids?.contains(chat.jid) ?? true else { return }
        guard let last = messages.last else {
            show(chat)
            return
        }
        let newer = store.messages(chat: chat.jid, after: last)
        guard !newer.isEmpty else { return }
        let atBottom = isScrolledToBottom
        let start = messages.count
        messages.append(contentsOf: newer)
        tableView.insertRows(at: IndexSet(start..<messages.count), withAnimation: [])
        if atBottom || newer.contains(where: \.fromMe) { scrollToBottom() }
        if NSApp.isActive, newer.contains(where: { !$0.fromMe }) {
            Core.shared.markRead(chat: chat.jid)
        }
    }

    private func loadOlder() {
        guard let chat, hasOlder, let first = messages.first else { return }
        let older = store.messages(chat: chat.jid, before: first, limit: Self.pageSize)
        hasOlder = older.count == Self.pageSize
        guard !older.isEmpty else { return }

        // The previous first row may gain/lose its sender label now it has a predecessor.
        layouts[first.rowid] = nil
        let clip = scrollView.contentView
        let oldHeight = tableView.bounds.height
        let oldY = clip.bounds.origin.y
        messages.insert(contentsOf: older, at: 0)
        tableView.insertRows(at: IndexSet(0..<older.count), withAnimation: [])
        tableView.noteHeightOfRows(withIndexesChanged: [older.count])
        clip.scroll(to: NSPoint(x: 0, y: oldY + tableView.bounds.height - oldHeight))
        scrollView.reflectScrolledClipView(clip)
    }

    @objc private func scrolled(_ note: Notification) {
        if hasOlder, scrollView.contentView.bounds.minY < 400 { loadOlder() }
    }

    private var isScrolledToBottom: Bool {
        scrollView.contentView.bounds.maxY >= tableView.bounds.height - 24
    }

    private func scrollToBottom() {
        guard !messages.isEmpty else { return }
        tableView.scrollRowToVisible(messages.count - 1)
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: max(0, tableView.bounds.height - clip.bounds.height)))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Sending

    @objc private func send(_ sender: Any?) {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let chat, !text.isEmpty else { return }
        input.stringValue = ""
        Task {
            if !(await Core.shared.sendText(text, to: chat.jid)) {
                input.stringValue = text
            }
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { messages.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        layout(for: row).rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: MessageCell.identifier, owner: nil) as? MessageCell ?? MessageCell()
        cell.configure(messages[row], layout: layout(for: row))
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    private func layout(for row: Int) -> BubbleLayout {
        let m = messages[row]
        if let cached = layouts[m.rowid] { return cached }
        let layout = BubbleLayout(m, showSender: showsSender(row), tableWidth: layoutWidth)
        layouts[m.rowid] = layout
        return layout
    }

    private func showsSender(_ row: Int) -> Bool {
        guard chat?.isGroup == true, !messages[row].fromMe else { return false }
        guard row > 0 else { return true }
        let prev = messages[row - 1]
        return prev.fromMe || prev.sender != messages[row].sender
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Re-measure only when the width crosses a 32pt bucket, not on every resize tick.
        let bucket = (tableView.bounds.width / 32).rounded(.down) * 32
        guard bucket != layoutWidth else { return }
        layoutWidth = bucket
        layouts.removeAll(keepingCapacity: true)
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0..<messages.count))
    }

    // MARK: Layout

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))

        tableView.addTableColumn(NSTableColumn(identifier: .init("msg")))
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        input.placeholderString = "Message"
        input.isEnabled = false
        input.target = self
        input.action = #selector(send(_:))
        input.bezelStyle = .roundedBezel
        input.font = .systemFont(ofSize: 13)
        sendButton.target = self
        sendButton.action = #selector(send(_:))
        sendButton.isEnabled = false

        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = .systemFont(ofSize: 15)

        let composer = NSStackView(views: [input, sendButton])
        for v in [scrollView, composer, placeholder] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            composer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            placeholder.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
        self.view = view
    }
}

// MARK: - Bubble

private enum Metrics {
    nonisolated(unsafe) static let bodyFont = NSFont.systemFont(ofSize: 13)
    nonisolated(unsafe) static let senderFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    nonisolated(unsafe) static let timeFont = NSFont.systemFont(ofSize: 10)
    static let sideMargin: CGFloat = 16
    static let rowMargin: CGFloat = 2
    static let hPad: CGFloat = 10
    static let vPad: CGFloat = 6
    static let gap: CGFloat = 2
    static let senderHeight: CGFloat = 14
    static let timeHeight: CGFloat = 12
}

/// Precomputed geometry for one message. Measuring uses a single shared cell
/// configured exactly like the label that renders the text.
private struct BubbleLayout {
    let showSender: Bool
    let textSize: NSSize
    let bubbleSize: NSSize
    var rowHeight: CGFloat { bubbleSize.height + 2 * Metrics.rowMargin }

    @MainActor private static let sizer: NSTextFieldCell = {
        let cell = NSTextFieldCell(textCell: "")
        cell.font = Metrics.bodyFont
        cell.wraps = true
        cell.lineBreakMode = .byWordWrapping
        cell.isSelectable = true
        return cell
    }()

    @MainActor init(_ m: MessageRow, showSender: Bool, tableWidth: CGFloat) {
        self.showSender = showSender
        let maxBubble = min(max(tableWidth - 2 * Metrics.sideMargin, 120) * 0.75, 620)
        let maxText = maxBubble - 2 * Metrics.hPad

        Self.sizer.stringValue = m.body
        let measured = Self.sizer.cellSize(forBounds: NSRect(x: 0, y: 0, width: maxText, height: .greatestFiniteMagnitude))
        textSize = NSSize(width: min(ceil(measured.width), maxText), height: ceil(measured.height))

        let timeWidth = ceil((MessageCell.timeString(m.ts) as NSString).size(withAttributes: [.font: Metrics.timeFont]).width)
        var contentWidth = max(textSize.width, timeWidth)
        if showSender {
            let senderWidth = ceil((m.senderTitle as NSString).size(withAttributes: [.font: Metrics.senderFont]).width)
            contentWidth = max(contentWidth, min(senderWidth, maxText))
        }
        let height = Metrics.vPad * 2 + textSize.height + Metrics.gap + Metrics.timeHeight
            + (showSender ? Metrics.senderHeight + Metrics.gap : 0)
        bubbleSize = NSSize(width: contentWidth + 2 * Metrics.hPad, height: height)
    }
}

@MainActor private final class MessageCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("MessageCell")

    private static let senderColors: [NSColor] = [
        .systemBlue, .systemPurple, .systemPink, .systemOrange, .systemTeal, .systemIndigo, .systemBrown, .systemGreen,
    ]

    private let bubble = NSView()
    private let sender = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private var fromMe = false
    private var bubbleLayout: BubbleLayout?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 10
        sender.font = Metrics.senderFont
        sender.lineBreakMode = .byTruncatingTail
        body.font = Metrics.bodyFont
        body.isSelectable = true
        time.font = Metrics.timeFont
        time.textColor = .secondaryLabelColor
        time.alignment = .right
        addSubview(bubble)
        [sender, body, time].forEach(bubble.addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func timeString(_ ts: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .omitted, time: .shortened)
    }

    func configure(_ m: MessageRow, layout: BubbleLayout) {
        fromMe = m.fromMe
        bubbleLayout = layout
        sender.isHidden = !layout.showSender
        sender.stringValue = m.senderTitle
        // Stable across launches, unlike hashValue.
        let hash = m.sender.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        sender.textColor = Self.senderColors[abs(hash) % Self.senderColors.count]
        body.stringValue = m.body
        time.stringValue = Self.timeString(m.ts)
        updateColors()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let l = bubbleLayout else { return }
        let x = fromMe ? bounds.width - Metrics.sideMargin - l.bubbleSize.width : Metrics.sideMargin
        bubble.frame = NSRect(origin: NSPoint(x: x, y: Metrics.rowMargin), size: l.bubbleSize)

        // bubble isn't flipped: lay out from the top down.
        var y = l.bubbleSize.height - Metrics.vPad
        let innerWidth = l.bubbleSize.width - 2 * Metrics.hPad
        if l.showSender {
            y -= Metrics.senderHeight
            sender.frame = NSRect(x: Metrics.hPad, y: y, width: innerWidth, height: Metrics.senderHeight)
            y -= Metrics.gap
        }
        y -= l.textSize.height
        body.frame = NSRect(x: Metrics.hPad, y: y, width: l.textSize.width, height: l.textSize.height)
        time.frame = NSRect(x: Metrics.hPad, y: Metrics.vPad, width: innerWidth, height: Metrics.timeHeight)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bubble.layer?.backgroundColor = (fromMe
                ? NSColor.controlAccentColor.withAlphaComponent(0.22)
                : NSColor.unemphasizedSelectedContentBackgroundColor).cgColor
        }
    }
}
