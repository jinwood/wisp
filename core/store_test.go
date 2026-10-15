package main

import (
	"database/sql"
	"path/filepath"
	"testing"
	"time"
)

// flush waits for the writer to drain everything queued so far.
func flush(t *testing.T, s *store) {
	t.Helper()
	done := make(chan struct{})
	s.enqueue(func(*sql.Tx, map[string]struct{}) error { close(done); return nil })
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("writer stalled")
	}
}

func TestStoreLiveMessages(t *testing.T) {
	s, err := openStore(filepath.Join(t.TempDir(), "messages.db"))
	if err != nil {
		t.Fatal(err)
	}
	chat := "123@s.whatsapp.net"
	newer := messageEvent{ID: "b", Chat: chat, Sender: chat, Timestamp: 200, Kind: "text", Text: "newer"}
	older := messageEvent{ID: "a", Chat: chat, Sender: chat, Timestamp: 100, Kind: "image"}
	mine := messageEvent{ID: "c", Chat: chat, Sender: "me@s.whatsapp.net", FromMe: true, Timestamp: 150, Kind: "text", Text: "mine"}

	s.storeLiveMessage(newer)
	s.storeLiveMessage(newer) // duplicate delivery must not double-count
	s.storeLiveMessage(older) // arrives late; must not regress the preview
	s.storeLiveMessage(mine)  // own messages don't count as unread
	flush(t, s)

	var count, unread int
	var preview string
	var lastTs int64
	if err := s.db.QueryRow(`SELECT count(*) FROM messages`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if err := s.db.QueryRow(`SELECT unread, last_preview, last_ts FROM chats WHERE jid = ?`, chat).Scan(&unread, &preview, &lastTs); err != nil {
		t.Fatal(err)
	}
	if count != 3 || unread != 2 || preview != "newer" || lastTs != 200 {
		t.Fatalf("got count=%d unread=%d preview=%q last_ts=%d", count, unread, preview, lastTs)
	}

	s.wipe()
	flush(t, s)
	if err := s.db.QueryRow(`SELECT (SELECT count(*) FROM messages) + (SELECT count(*) FROM chats)`).Scan(&count); err != nil || count != 0 {
		t.Fatalf("wipe left %d rows (err %v)", count, err)
	}
}

func TestPreview(t *testing.T) {
	cases := map[messageEvent]string{
		{Kind: "text", Text: "hi"}:          "hi",
		{Kind: "image"}:                     "📷 Photo",
		{Kind: "image", Text: "beach"}:      "📷 beach",
		{Kind: "document", Text: "cv.pdf"}:  "📄 cv.pdf",
		{Kind: "unknown", Text: "fallback"}: "fallback",
	}
	for m, want := range cases {
		if got := preview(m); got != want {
			t.Errorf("preview(%s, %q) = %q, want %q", m.Kind, m.Text, got, want)
		}
	}
}
