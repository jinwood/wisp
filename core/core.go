// Package main is built with -buildmode=c-archive into libwisp.a and linked
// into the Swift app. See app/Sources/CWisp/include/wisp.h for the ABI.
package main

/*
#cgo CFLAGS: -I${SRCDIR}/../app/Sources/CWisp/include -DWISP_CGO
#include <stdlib.h>
#include "wisp.h"

static inline void wisp_emit(wisp_event_cb cb, int32_t kind, const char *data, int32_t len) {
	if (cb) cb(kind, data, len);
}
*/
import "C"

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"sync"
	"time"
	"unsafe"

	_ "github.com/mattn/go-sqlite3"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	waStore "go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
)

// Soft cap for the Go heap. The GC works harder as we approach it rather than
// letting the heap balloon during history sync.
const goMemoryLimit = 48 << 20

var (
	mu        sync.Mutex
	container *sqlstore.Container
	client    *whatsmeow.Client
	db        *store
	cb        C.wisp_event_cb
)

func current() (*whatsmeow.Client, *store) {
	mu.Lock()
	defer mu.Unlock()
	return client, db
}

func main() {}

func emit(kind C.int32_t, payload any) {
	data, err := json.Marshal(payload)
	if err != nil {
		return
	}
	cstr := C.CBytes(data)
	defer C.free(cstr)
	C.wisp_emit(cb, kind, (*C.char)(cstr), C.int32_t(len(data)))
}

func emitError(op string, err error) {
	emit(C.WISP_EV_ERROR, map[string]string{"op": op, "error": err.Error()})
}

//export wisp_init
func wisp_init(dataDir *C.char, callback C.wisp_event_cb) C.int32_t {
	mu.Lock()
	defer mu.Unlock()
	if client != nil {
		return 0
	}
	debug.SetMemoryLimit(goMemoryLimit)
	debug.SetGCPercent(50)
	cb = callback

	dir := C.GoString(dataDir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		emitError("init", err)
		return 1
	}
	ctx := context.Background()
	dsn := "file:" + filepath.Join(dir, "session.db") + "?_foreign_keys=on&_journal_mode=WAL&_busy_timeout=5000"
	var err error
	container, err = sqlstore.New(ctx, "sqlite3", dsn, waLog.Stdout("Store", "WARN", false))
	if err != nil {
		emitError("init", err)
		return 1
	}
	device, err := container.GetFirstDevice(ctx)
	if err != nil {
		emitError("init", err)
		return 1
	}
	if db, err = openStore(filepath.Join(dir, "messages.db")); err != nil {
		emitError("init", err)
		return 1
	}
	client = newClient(device)
	return 0
}

func newClient(device *waStore.Device) *whatsmeow.Client {
	cli := whatsmeow.NewClient(device, waLog.Stdout("Client", "WARN", false))
	cli.AddEventHandler(handleEvent)
	return cli
}

// resetAfterLogout wipes local messages and starts pairing a fresh device.
func resetAfterLogout() {
	mu.Lock()
	db.wipe()
	client = newClient(container.NewDevice())
	cli := client
	mu.Unlock()
	connect(cli)
}

//export wisp_connect
func wisp_connect() C.int32_t {
	cli, _ := current()
	if cli == nil {
		return 1
	}
	connect(cli)
	return 0
}

func connect(cli *whatsmeow.Client) {
	go func() {
		if cli.Store.ID != nil {
			if err := cli.Connect(); err != nil {
				emitError("connect", err)
			}
			return
		}
		qrChan, err := cli.GetQRChannel(context.Background())
		if err != nil {
			emitError("connect", err)
			return
		}
		if err := cli.Connect(); err != nil {
			emitError("connect", err)
			return
		}
		for item := range qrChan {
			switch item.Event {
			case whatsmeow.QRChannelEventCode:
				emit(C.WISP_EV_QR, map[string]any{"code": item.Code, "timeout_s": int(item.Timeout.Seconds())})
			case whatsmeow.QRChannelEventError:
				emitError("pair", item.Error)
			case "timeout":
				emitError("pair", fmt.Errorf("QR code timed out"))
			}
		}
	}()
}

//export wisp_disconnect
func wisp_disconnect() {
	mu.Lock()
	defer mu.Unlock()
	if client != nil {
		client.Disconnect()
	}
}

//export wisp_logout
func wisp_logout() C.int32_t {
	cli, _ := current()
	if cli == nil {
		return 1
	}
	if err := cli.Logout(context.Background()); err != nil {
		emitError("logout", err)
		return 1
	}
	emit(C.WISP_EV_LOGGED_OUT, map[string]string{"reason": "logged out from Wisp"})
	resetAfterLogout()
	return 0
}

//export wisp_send_text
func wisp_send_text(chatJID *C.char, text *C.char) *C.char {
	cli, db := current()
	if cli == nil {
		return nil
	}
	jid, err := types.ParseJID(C.GoString(chatJID))
	if err != nil {
		emitError("send", err)
		return nil
	}
	body := C.GoString(text)
	resp, err := cli.SendMessage(context.Background(), jid, &waE2E.Message{Conversation: proto.String(body)})
	if err != nil {
		emitError("send", err)
		return nil
	}
	// whatsmeow doesn't echo our own sends back as events, so store it here.
	db.storeLiveMessage(messageEvent{
		ID:        resp.ID,
		Chat:      jid.String(),
		Sender:    cli.Store.ID.ToNonAD().String(),
		FromMe:    true,
		IsGroup:   jid.Server == types.GroupServer,
		Timestamp: resp.Timestamp.Unix(),
		Kind:      "text",
		Text:      body,
	})
	return C.CString(resp.ID)
}

//export wisp_mark_read
func wisp_mark_read(chatJID *C.char) C.int32_t {
	cli, st := current()
	if cli == nil {
		return 1
	}
	chat := C.GoString(chatJID)
	jid, err := types.ParseJID(chat)
	if err != nil {
		return 1
	}
	bySender, newest, err := st.unreadIncoming(chat)
	if err != nil {
		emitError("mark_read", err)
		return 1
	}
	if len(bySender) == 0 {
		return 0
	}
	for sender, ids := range bySender {
		// Receipts only name the sender in groups.
		senderJID := types.EmptyJID
		if jid.Server == types.GroupServer {
			senderJID, _ = types.ParseJID(sender)
		}
		if err := cli.MarkRead(context.Background(), ids, time.Unix(newest, 0), jid, senderJID); err != nil {
			emitError("mark_read", err)
		}
	}
	st.setChatField(jid, "unread", 0)
	return 0
}

//export wisp_free
func wisp_free(p unsafe.Pointer) {
	C.free(p)
}

//export wisp_go_heap_bytes
func wisp_go_heap_bytes() C.int64_t {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	return C.int64_t(ms.HeapAlloc)
}
