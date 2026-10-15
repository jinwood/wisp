import CWisp
import Foundation

struct Message: Decodable, Sendable {
    let id: String
    let chat: String
    let chatName: String
    let sender: String
    let senderName: String
    let fromMe: Bool
    let isGroup: Bool
    let ts: Int64
    let kind: String
    let text: String

    var chatTitle: String { chatName.isEmpty ? chat : chatName }
}

enum CoreEvent {
    case qr(code: String)
    case paired(jid: String)
    case connected
    case disconnected
    case loggedOut(reason: String)
    case message(Message)
    case historySync(conversations: Int, messages: Int, type: String)
    case error(op: String, message: String)
    /// Rows for these chats changed in messages.db; nil means re-query everything.
    case chatsChanged(Set<String>?)
}

/// Swift face of the Go protocol core. Events arrive on Go threads and are
/// hopped onto the main queue in order before reaching `onEvent`.
@MainActor
final class Core {
    static let shared = Core()

    var onEvent: ((CoreEvent) -> Void)?

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    func start(dataDir: URL) -> Bool {
        wisp_init(dataDir.path, wispCallback) == 0 && wisp_connect() == 0
    }

    func stop() {
        wisp_disconnect()
    }

    var goHeapBytes: Int64 { wisp_go_heap_bytes() }

    nonisolated func sendText(_ text: String, to chat: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard let id = wisp_send_text(chat, text) else { return false }
            wisp_free(id)
            return true
        }.value
    }

    nonisolated func markRead(chat: String) {
        Task.detached(priority: .utility) { _ = wisp_mark_read(chat) }
    }

    nonisolated func logout() async -> Bool {
        await Task.detached { wisp_logout() == 0 }.value
    }

    fileprivate func dispatch(kind: Int32, data: Data) {
        guard let event = decode(kind: kind, data: data) else { return }
        onEvent?(event)
    }

    private func decode(kind: Int32, data: Data) -> CoreEvent? {
        let obj = { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
        switch kind {
        case WISP_EV_QR:
            return .qr(code: obj()["code"] as? String ?? "")
        case WISP_EV_PAIRED:
            return .paired(jid: obj()["jid"] as? String ?? "")
        case WISP_EV_CONNECTED:
            return .connected
        case WISP_EV_DISCONNECTED:
            return .disconnected
        case WISP_EV_LOGGED_OUT:
            return .loggedOut(reason: obj()["reason"] as? String ?? "")
        case WISP_EV_MESSAGE:
            return (try? decoder.decode(Message.self, from: data)).map(CoreEvent.message)
        case WISP_EV_HISTORY_SYNC:
            let o = obj()
            return .historySync(
                conversations: o["conversations"] as? Int ?? 0,
                messages: o["messages"] as? Int ?? 0,
                type: o["type"] as? String ?? "")
        case WISP_EV_CHATS_CHANGED:
            let o = obj()
            if o["all"] as? Bool == true { return .chatsChanged(nil) }
            return .chatsChanged(Set(o["chats"] as? [String] ?? []))
        case WISP_EV_ERROR:
            let o = obj()
            return .error(op: o["op"] as? String ?? "", message: o["error"] as? String ?? "")
        default:
            return nil
        }
    }
}

// Called on Go threads. The payload is only valid during the call, so copy it
// before hopping to main. DispatchQueue.main keeps events in FIFO order.
private let wispCallback: wisp_event_cb = { kind, json, len in
    guard let json else { return }
    let data = Data(bytes: json, count: Int(len))
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            Core.shared.dispatch(kind: kind, data: data)
        }
    }
}
