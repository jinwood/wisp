package main

// #include "wisp.h"
import "C"

import (
	"context"
	"database/sql"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

type messageEvent struct {
	ID         string `json:"id"`
	Chat       string `json:"chat"`
	ChatName   string `json:"chat_name"`
	Sender     string `json:"sender"`
	SenderName string `json:"sender_name"`
	FromMe     bool   `json:"from_me"`
	IsGroup    bool   `json:"is_group"`
	Timestamp  int64  `json:"ts"`
	Kind       string `json:"kind"`
	Text       string `json:"text"`
}

func handleEvent(evt any) {
	cli, st := current()
	switch v := evt.(type) {
	case *events.Message:
		m, ok := toMessageEvent(cli, v)
		if !ok {
			return
		}
		m.ChatName = displayName(cli, v.Info.Chat)
		st.storeLiveMessage(m)
		// Swift doesn't need this to render (it reads the DB); it's for notifications.
		emit(C.WISP_EV_MESSAGE, m)
	case *events.HistorySync:
		st.storeHistory(cli, v.Data)
		convs := v.Data.GetConversations()
		msgs := 0
		for _, c := range convs {
			msgs += len(c.GetMessages())
		}
		emit(C.WISP_EV_HISTORY_SYNC, map[string]any{
			"conversations": len(convs),
			"messages":      msgs,
			"type":          v.Data.GetSyncType().String(),
		})
	case *events.Archive:
		st.setChatField(v.JID, "archived", v.Action.GetArchived())
	case *events.Pin:
		var pinned int64
		if v.Action.GetPinned() {
			pinned = v.Timestamp.Unix()
		}
		st.setChatField(v.JID, "pinned", pinned)
	case *events.Mute:
		var until int64
		if v.Action.GetMuted() {
			until = v.Action.GetMuteEndTimestamp()
			if until > 1e12 { // ms → s
				until /= 1000
			}
			if until <= 0 {
				until = -1 // muted forever
			}
		}
		st.setChatField(v.JID, "muted_until", until)
	case *events.MarkChatAsRead:
		unread := 0
		if !v.Action.GetRead() {
			unread = 1
		}
		st.setChatField(v.JID, "unread", unread)
	case *events.GroupInfo:
		if v.Name != nil {
			st.setChatField(v.JID, "name", v.Name.Name)
		}
	case *events.PushName:
		name := v.NewPushName
		jid := v.JID.ToNonAD().String()
		st.enqueue(func(tx *sql.Tx, changed map[string]struct{}) error {
			res, err := tx.Exec(`UPDATE chats SET name = ? WHERE jid = ? AND name = ''`, name, jid)
			if err != nil {
				return err
			}
			if n, _ := res.RowsAffected(); n > 0 {
				changed[jid] = struct{}{}
			}
			return nil
		})
	case *events.AppStateSyncComplete:
		st.fillMissingNames(cli)
	case *events.PairSuccess:
		emit(C.WISP_EV_PAIRED, map[string]string{"jid": v.ID.String()})
	case *events.Connected:
		emit(C.WISP_EV_CONNECTED, struct{}{})
	case *events.Disconnected:
		emit(C.WISP_EV_DISCONNECTED, struct{}{})
	case *events.LoggedOut:
		// Unlinked from the phone. Reset off the event goroutine of the dead client.
		emit(C.WISP_EV_LOGGED_OUT, map[string]string{"reason": v.Reason.String()})
		go resetAfterLogout()
	}
}

// toMessageEvent flattens a message into what we store. ok is false for
// messages that aren't shown as timeline rows (receipts, key distribution,
// protocol messages, and reactions until phase 5).
func toMessageEvent(cli *whatsmeow.Client, v *events.Message) (m messageEvent, ok bool) {
	kind, text := describe(v.Message)
	if kind == "" || kind == "reaction" || v.Info.Chat.Server == types.BroadcastServer {
		return m, false
	}
	return messageEvent{
		ID:         v.Info.ID,
		Chat:       v.Info.Chat.ToNonAD().String(),
		Sender:     v.Info.Sender.ToNonAD().String(),
		SenderName: v.Info.PushName,
		FromMe:     v.Info.IsFromMe,
		IsGroup:    v.Info.IsGroup,
		Timestamp:  v.Info.Timestamp.Unix(),
		Kind:       kind,
		Text:       text,
	}, true
}

// describe returns a short kind tag and display text, or "" for messages that
// aren't user-visible.
func describe(m *waE2E.Message) (kind, text string) {
	switch {
	case m == nil:
		return "", ""
	case m.Conversation != nil:
		return "text", m.GetConversation()
	case m.ExtendedTextMessage != nil:
		return "text", m.GetExtendedTextMessage().GetText()
	case m.ImageMessage != nil:
		return "image", m.GetImageMessage().GetCaption()
	case m.VideoMessage != nil:
		return "video", m.GetVideoMessage().GetCaption()
	case m.AudioMessage != nil:
		return "audio", ""
	case m.DocumentMessage != nil:
		return "document", m.GetDocumentMessage().GetFileName()
	case m.StickerMessage != nil:
		return "sticker", ""
	case m.ReactionMessage != nil:
		return "reaction", m.GetReactionMessage().GetText()
	case m.LocationMessage != nil:
		return "location", m.GetLocationMessage().GetName()
	case m.ContactMessage != nil:
		return "contact", m.GetContactMessage().GetDisplayName()
	case m.PollCreationMessage != nil:
		return "poll", m.GetPollCreationMessage().GetName()
	}
	return "", ""
}

// displayName resolves a 1:1 chat to a contact name, following LID → phone
// number mappings. Groups get their names from history sync and GroupInfo.
func displayName(cli *whatsmeow.Client, jid types.JID) string {
	if cli == nil || jid.Server == types.GroupServer {
		return ""
	}
	ctx := context.Background()
	jid = jid.ToNonAD()
	if name := contactName(ctx, cli, jid); name != "" {
		return name
	}
	if jid.Server == types.HiddenUserServer {
		if pn, err := cli.Store.LIDs.GetPNForLID(ctx, jid); err == nil && !pn.IsEmpty() {
			return contactName(ctx, cli, pn)
		}
	}
	return ""
}

func contactName(ctx context.Context, cli *whatsmeow.Client, jid types.JID) string {
	info, err := cli.Store.Contacts.GetContact(ctx, jid)
	if err != nil || !info.Found {
		return ""
	}
	for _, n := range []string{info.FullName, info.FirstName, info.PushName, info.BusinessName} {
		if n != "" {
			return n
		}
	}
	return ""
}
