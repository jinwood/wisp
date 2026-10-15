package main

// #include "wisp.h"
import "C"

import (
	"context"
	"database/sql"
	"slices"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/types"
)

// messages.db is the app's source of truth. Go is its only writer; Swift opens
// it read-only and re-queries when told which chats changed.
const schema = `
CREATE TABLE IF NOT EXISTS chats (
	jid          TEXT PRIMARY KEY,
	name         TEXT NOT NULL DEFAULT '',
	is_group     INTEGER NOT NULL DEFAULT 0,
	last_ts      INTEGER NOT NULL DEFAULT 0,
	last_preview TEXT NOT NULL DEFAULT '',
	unread       INTEGER NOT NULL DEFAULT 0,
	archived     INTEGER NOT NULL DEFAULT 0,
	pinned       INTEGER NOT NULL DEFAULT 0, -- pin timestamp, 0 = not pinned
	muted_until  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS chats_by_recent ON chats(archived, pinned DESC, last_ts DESC);

-- A rowid table (not WITHOUT ROWID) so phase 5 can hang an external-content FTS5 index off it.
CREATE TABLE IF NOT EXISTS messages (
	chat        TEXT NOT NULL,
	msg_id      TEXT NOT NULL,
	sender      TEXT NOT NULL,
	sender_name TEXT NOT NULL DEFAULT '',
	from_me     INTEGER NOT NULL,
	ts          INTEGER NOT NULL,
	kind        TEXT NOT NULL,
	text        TEXT NOT NULL DEFAULT '',
	UNIQUE (chat, msg_id)
);
CREATE INDEX IF NOT EXISTS messages_by_time ON messages(chat, ts);
`

const (
	maxBatch    = 2000
	batchWindow = 30 * time.Millisecond
	// Beyond this many changed chats, tell Swift to reload everything rather than
	// shipping a long list across the bridge.
	maxChangedList = 64
	// Key in the changed set meaning "everything changed".
	allChats = "*"
)

// writeOp runs inside the writer's transaction and records the chats it touched.
type writeOp func(tx *sql.Tx, changed map[string]struct{}) error

type store struct {
	db *sql.DB
	in chan writeOp
}

func openStore(path string) (*store, error) {
	db, err := sql.Open("sqlite3", "file:"+path+"?_journal_mode=WAL&_synchronous=NORMAL&_busy_timeout=5000")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, err
	}
	s := &store{db: db, in: make(chan writeOp, 256)}
	go s.writer()
	return s, nil
}

func (s *store) enqueue(op writeOp) { s.in <- op }

// writer coalesces ops arriving within batchWindow into one transaction, then
// emits a single change notification for the whole batch.
func (s *store) writer() {
	for first := range s.in {
		batch := []writeOp{first}
		timer := time.NewTimer(batchWindow)
	collect:
		for len(batch) < maxBatch {
			select {
			case op := <-s.in:
				batch = append(batch, op)
			case <-timer.C:
				break collect
			}
		}
		timer.Stop()

		changed := map[string]struct{}{}
		tx, err := s.db.Begin()
		if err != nil {
			emitError("store", err)
			continue
		}
		for _, op := range batch {
			if err := op(tx, changed); err != nil {
				emitError("store", err)
			}
		}
		if err := tx.Commit(); err != nil {
			emitError("store", err)
			continue
		}
		if len(changed) > 0 {
			emitChanged(changed)
		}
	}
}

func emitChanged(changed map[string]struct{}) {
	if _, all := changed[allChats]; all || len(changed) > maxChangedList {
		emit(C.WISP_EV_CHATS_CHANGED, map[string]any{"all": true})
		return
	}
	chats := make([]string, 0, len(changed))
	for jid := range changed {
		chats = append(chats, jid)
	}
	emit(C.WISP_EV_CHATS_CHANGED, map[string]any{"chats": chats})
}

// MARK: Messages

func insertMessage(tx *sql.Tx, m messageEvent) (bool, error) {
	res, err := tx.Exec(`INSERT INTO messages (chat, msg_id, sender, sender_name, from_me, ts, kind, text)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (chat, msg_id) DO NOTHING`,
		m.Chat, m.ID, m.Sender, m.SenderName, m.FromMe, m.Timestamp, m.Kind, m.Text)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// bumpChat moves a chat's last-message preview forward (never backwards, since
// history can arrive after live messages) and adds to its unread count.
func bumpChat(tx *sql.Tx, m messageEvent, unreadDelta int) error {
	_, err := tx.Exec(`INSERT INTO chats (jid, name, is_group, last_ts, last_preview, unread)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT (jid) DO UPDATE SET
			name         = CASE WHEN excluded.name <> '' THEN excluded.name ELSE chats.name END,
			last_preview = CASE WHEN excluded.last_ts >= chats.last_ts THEN excluded.last_preview ELSE chats.last_preview END,
			last_ts      = max(chats.last_ts, excluded.last_ts),
			unread       = chats.unread + excluded.unread`,
		m.Chat, m.ChatName, m.IsGroup, m.Timestamp, preview(m), unreadDelta)
	return err
}

// storeLiveMessage persists a message received (or sent) while connected.
func (s *store) storeLiveMessage(m messageEvent) {
	s.enqueue(func(tx *sql.Tx, changed map[string]struct{}) error {
		inserted, err := insertMessage(tx, m)
		if err != nil || !inserted {
			return err
		}
		unread := 0
		if !m.FromMe {
			unread = 1
		}
		changed[m.Chat] = struct{}{}
		return bumpChat(tx, m, unread)
	})
}

// storeHistory writes one history sync blob. Conversation metadata (name,
// unread, archive, pin, mute) comes from the phone and overwrites ours.
func (s *store) storeHistory(cli *whatsmeow.Client, data *waHistorySync.HistorySync) {
	s.enqueue(func(tx *sql.Tx, changed map[string]struct{}) error {
		for _, conv := range data.GetConversations() {
			chat, err := types.ParseJID(conv.GetID())
			if err != nil || chat.Server == types.BroadcastServer {
				continue
			}
			name := conv.GetName()
			if name == "" {
				name = conv.GetDisplayName()
			}
			if name == "" {
				name = displayName(cli, chat)
			}
			for _, hm := range conv.GetMessages() {
				evt, err := cli.ParseWebMessage(chat, hm.GetMessage())
				if err != nil {
					continue
				}
				m, ok := toMessageEvent(cli, evt)
				if !ok {
					continue
				}
				m.ChatName = name
				if _, err := insertMessage(tx, m); err != nil {
					return err
				}
				if err := bumpChat(tx, m, 0); err != nil {
					return err
				}
			}
			_, err = tx.Exec(`INSERT INTO chats (jid, name, is_group, last_ts, unread, archived, pinned, muted_until)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?)
				ON CONFLICT (jid) DO UPDATE SET
					name        = CASE WHEN excluded.name <> '' THEN excluded.name ELSE chats.name END,
					last_ts     = max(chats.last_ts, excluded.last_ts),
					unread      = excluded.unread,
					archived    = excluded.archived,
					pinned      = excluded.pinned,
					muted_until = excluded.muted_until`,
				chat.String(), name, chat.Server == types.GroupServer, int64(conv.GetConversationTimestamp()),
				conv.GetUnreadCount(), conv.GetArchived(), conv.GetPinned(), int64(conv.GetMuteEndTime()))
			if err != nil {
				return err
			}
			changed[chat.String()] = struct{}{}
		}
		return nil
	})
}

// wipe deletes all local messages, e.g. after logging out.
func (s *store) wipe() {
	s.enqueue(func(tx *sql.Tx, changed map[string]struct{}) error {
		changed[allChats] = struct{}{}
		_, err := tx.Exec(`DELETE FROM messages; DELETE FROM chats;`)
		return err
	})
}

// MARK: Chat metadata

func (s *store) setChatField(jid types.JID, column string, value any) {
	if !slices.Contains([]string{"name", "unread", "archived", "pinned", "muted_until"}, column) {
		return
	}
	s.enqueue(func(tx *sql.Tx, changed map[string]struct{}) error {
		res, err := tx.Exec(`UPDATE chats SET `+column+` = ? WHERE jid = ?`, value, jid.String())
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n > 0 {
			changed[jid.String()] = struct{}{}
		}
		return nil
	})
}

// fillMissingNames resolves names for 1:1 chats created before contacts synced.
func (s *store) fillMissingNames(cli *whatsmeow.Client) {
	s.enqueue(func(tx *sql.Tx, changed map[string]struct{}) error {
		rows, err := tx.Query(`SELECT jid FROM chats WHERE name = '' AND is_group = 0`)
		if err != nil {
			return err
		}
		var jids []string
		for rows.Next() {
			var j string
			if rows.Scan(&j) == nil {
				jids = append(jids, j)
			}
		}
		rows.Close()
		for _, j := range jids {
			jid, err := types.ParseJID(j)
			if err != nil {
				continue
			}
			if name := displayName(cli, jid); name != "" {
				if _, err := tx.Exec(`UPDATE chats SET name = ? WHERE jid = ?`, name, j); err != nil {
					return err
				}
				changed[j] = struct{}{}
			}
		}
		return nil
	})
}

// unreadIncoming returns the newest unread incoming messages in a chat, grouped
// by sender, for sending read receipts.
func (s *store) unreadIncoming(chat string) (map[string][]string, int64, error) {
	var unread int
	if err := s.db.QueryRow(`SELECT unread FROM chats WHERE jid = ?`, chat).Scan(&unread); err != nil || unread == 0 {
		return nil, 0, err
	}
	rows, err := s.db.QueryContext(context.Background(),
		`SELECT msg_id, sender, ts FROM messages WHERE chat = ? AND from_me = 0 ORDER BY ts DESC LIMIT ?`,
		chat, min(unread, 200))
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	bySender := map[string][]string{}
	var newest int64
	for rows.Next() {
		var id, sender string
		var ts int64
		if rows.Scan(&id, &sender, &ts) == nil {
			bySender[sender] = append(bySender[sender], id)
			newest = max(newest, ts)
		}
	}
	return bySender, newest, rows.Err()
}

var previewLabels = map[string]struct{ icon, fallback string }{
	"image": {"📷", "Photo"}, "video": {"🎥", "Video"}, "audio": {"🎤", "Voice message"},
	"document": {"📄", "Document"}, "sticker": {"🏷️", "Sticker"}, "location": {"📍", "Location"},
	"contact": {"👤", "Contact"}, "poll": {"📊", "Poll"},
}

func preview(m messageEvent) string {
	label, ok := previewLabels[m.Kind]
	switch {
	case !ok:
		return m.Text
	case m.Text == "":
		return label.icon + " " + label.fallback
	default:
		return label.icon + " " + m.Text
	}
}
