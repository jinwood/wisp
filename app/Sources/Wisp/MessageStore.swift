import Foundation

struct ChatRow: Equatable {
    let jid: String
    let name: String
    let isGroup: Bool
    let lastTs: Int64
    let preview: String
    let unread: Int
    let isPinned: Bool
    let isMuted: Bool

    var title: String {
        if !name.isEmpty { return name }
        let user = jid.split(separator: "@").first.map(String.init) ?? jid
        return jid.hasSuffix("@s.whatsapp.net") ? "+" + user : user
    }
}

struct MessageRow {
    let rowid: Int64
    let id: String
    let sender: String
    let senderName: String
    let fromMe: Bool
    let ts: Int64
    let kind: String
    let text: String

    /// Text shown in the bubble, with a label for media we don't render yet.
    var body: String {
        let labels = [
            "image": "📷 Photo", "video": "🎥 Video", "audio": "🎤 Voice message", "document": "📄 Document",
            "sticker": "🏷️ Sticker", "location": "📍 Location", "contact": "👤 Contact", "poll": "📊 Poll",
        ]
        guard let label = labels[kind] else { return text }
        return text.isEmpty ? label : "\(label)\n\(text)"
    }

    var senderTitle: String {
        if !senderName.isEmpty { return senderName }
        return sender.split(separator: "@").first.map(String.init) ?? sender
    }
}

/// Read side of messages.db. The Go core is the only writer.
@MainActor
final class MessageStore {
    private let db: Database

    init(path: String) throws {
        db = try Database(path: path)
    }

    func chats() -> [ChatRow] {
        let now = Int64(Date().timeIntervalSince1970)
        return db.query("""
            SELECT jid, name, is_group, last_ts, last_preview, unread, pinned, muted_until
            FROM chats WHERE archived = 0
            ORDER BY pinned DESC, last_ts DESC
            """) { r in
            let mutedUntil = r.int(7)
            return ChatRow(
                jid: r.text(0), name: r.text(1), isGroup: r.bool(2), lastTs: r.int(3),
                preview: r.text(4), unread: Int(r.int(5)), isPinned: r.int(6) > 0,
                isMuted: mutedUntil < 0 || mutedUntil > now)
        }
    }

    /// Up to `limit` messages older than `before` (or the newest, if nil), oldest first.
    func messages(chat: String, before: MessageRow?, limit: Int) -> [MessageRow] {
        let rows = db.query(Self.select + """
            WHERE chat = ?1 AND (ts < ?2 OR (ts = ?2 AND rowid < ?3))
            ORDER BY ts DESC, rowid DESC LIMIT ?4
            """,
            [.text(chat), .int(before?.ts ?? .max), .int(before?.rowid ?? .max), .int(Int64(limit))],
            map: Self.message)
        return rows.reversed()
    }

    /// Messages newer than `after`, oldest first.
    func messages(chat: String, after: MessageRow) -> [MessageRow] {
        db.query(Self.select + """
            WHERE chat = ?1 AND (ts > ?2 OR (ts = ?2 AND rowid > ?3))
            ORDER BY ts, rowid
            """,
            [.text(chat), .int(after.ts), .int(after.rowid)],
            map: Self.message)
    }

    private static let select = "SELECT rowid, msg_id, sender, sender_name, from_me, ts, kind, text FROM messages "

    private static func message(_ r: Database.Row) -> MessageRow {
        MessageRow(
            rowid: r.int(0), id: r.text(1), sender: r.text(2), senderName: r.text(3),
            fromMe: r.bool(4), ts: r.int(5), kind: r.text(6), text: r.text(7))
    }
}
