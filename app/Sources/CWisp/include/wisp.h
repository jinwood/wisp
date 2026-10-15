// The C ABI between the Swift app and the Go protocol core (libwisp.a).
//
// Threading: every function may be called from any thread. Functions that hit
// the network block, so call them off the main thread. Events are delivered on
// arbitrary Go-owned threads; the payload pointer is only valid for the
// duration of the callback.
#ifndef WISP_H
#define WISP_H

#include <stdint.h>

#define WISP_EV_QR            1  // {"code": string, "timeout_s": int}
#define WISP_EV_PAIRED        2  // {"jid": string}
#define WISP_EV_CONNECTED     3  // {}
#define WISP_EV_DISCONNECTED  4  // {}
#define WISP_EV_LOGGED_OUT    5  // {"reason": string}
#define WISP_EV_MESSAGE       6  // see messageEvent in core/events.go
#define WISP_EV_HISTORY_SYNC  7  // {"conversations": int, "messages": int, "type": string}
#define WISP_EV_ERROR         8  // {"op": string, "error": string}
#define WISP_EV_CHATS_CHANGED 9  // {"chats": [jid]} or {"all": true}; re-query messages.db

typedef void (*wisp_event_cb)(int32_t kind, const char *json, int32_t len);

// cgo can't export const-qualified parameters, so Go sees its own (ABI
// identical) prototypes and Swift sees these.
#ifndef WISP_CGO

// Opens (or creates) session.db and messages.db in data_dir. Returns 0 on
// success. messages.db is written only by the core; open it read-only.
int32_t wisp_init(const char *data_dir, wisp_event_cb cb);

// Connects asynchronously. If the device isn't paired yet, WISP_EV_QR events follow.
int32_t wisp_connect(void);
void wisp_disconnect(void);

// Unlinks this device from the account. Blocks.
int32_t wisp_logout(void);

// Sends a text message. Blocks. Returns the message ID (free with wisp_free) or NULL on error.
char *wisp_send_text(const char *chat_jid, const char *text);

// Sends read receipts for a chat's unread messages and zeroes its unread count. Blocks.
int32_t wisp_mark_read(const char *chat_jid);

void wisp_free(void *p);

// Bytes of live Go heap, for the memory HUD.
int64_t wisp_go_heap_bytes(void);

#endif
#endif
