import AppKit
import CoreImage.CIFilterBuiltins

/// Owns the window and swaps between the pairing screen and the split view.
/// The title shows the open chat; the subtitle shows connection state and the
/// process footprint, so memory is always in view while we build.
@MainActor
final class MainWindowController: NSWindowController {
    private let split = NSSplitViewController()
    private let chatList: ChatListViewController
    private let timeline: TimelineViewController
    private let pairing = PairingViewController()
    private var status = "Connecting…"
    private var memoryTimer: Timer?

    init(store: MessageStore) {
        chatList = ChatListViewController(store: store)
        timeline = TimelineViewController(store: store)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Wisp"
        window.toolbar = NSToolbar(identifier: "main")
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 640, height: 420)
        super.init(window: window)

        let sidebar = NSSplitViewItem(sidebarWithViewController: chatList)
        sidebar.minimumThickness = 240
        sidebar.maximumThickness = 420
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(NSSplitViewItem(viewController: timeline))
        split.splitView.autosaveName = "MainSplit"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 980, height: 680))
        window.setFrameAutosaveName("Main")
        if !window.setFrameUsingName("Main") { window.center() }

        chatList.onSelect = { [weak self] chat in
            self?.timeline.show(chat)
            self?.window?.title = chat.title
        }
        chatList.reload()
        startMemoryHUD()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func handle(_ event: CoreEvent) {
        switch event {
        case .qr(let code):
            chatList.reset()
            timeline.reset()
            window?.title = "Wisp"
            pairing.show(code: code)
            setContent(pairing)
            setStatus("Waiting for pairing")
        case .paired:
            setContent(split)
            setStatus("Paired — syncing history…")
        case .connected:
            setContent(split)
            setStatus("Connected")
        case .disconnected:
            setStatus("Reconnecting…")
        case .loggedOut:
            setStatus("Logged out")
        case .historySync(let convs, let msgs, _):
            setStatus("Synced \(msgs) messages in \(convs) chats")
        case .chatsChanged(let jids):
            chatList.reload()
            timeline.chatsChanged(jids)
        case .error(let op, let message):
            setStatus("\(op) failed: \(message)")
        case .message:
            break // Notifications land in phase 5.
        }
    }

    func setStatus(_ text: String) {
        status = text
        updateSubtitle()
    }

    private func setContent(_ vc: NSViewController) {
        guard let window, window.contentViewController !== vc else { return }
        let frame = window.frame
        window.contentViewController = vc
        window.setFrame(frame, display: true)
    }

    private func startMemoryHUD() {
        updateSubtitle()
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSubtitle() }
        }
    }

    private func updateSubtitle() {
        window?.subtitle = "\(status) · \(formatMB(physFootprint()))"
    }
}

@MainActor
final class PairingViewController: NSViewController {
    private let imageView = NSImageView()

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 980, height: 680))
        imageView.imageScaling = .scaleNone
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.white.cgColor
        imageView.layer?.cornerRadius = 12

        let label = NSTextField(labelWithString: "On your phone: WhatsApp → Settings → Linked devices → Link a device")
        label.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [imageView, label])
        stack.orientation = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 320),
            imageView.heightAnchor.constraint(equalToConstant: 320),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        self.view = view
    }

    func show(code: String) {
        loadViewIfNeeded()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(code.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return }
        let scale = floor(280 / output.extent.width)
        let rep = NSCIImageRep(ciImage: output.transformed(by: .init(scaleX: scale, y: scale)))
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        imageView.image = image
    }
}
