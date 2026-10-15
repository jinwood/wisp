# Wisp

A native macOS WhatsApp client built to be fast and use as little memory as possible.

The official desktop client can easily use 1 GB of RAM. Wisp aims for under 120 MB with a large account loaded, and currently sits around 70 MB.

> **Unofficial.** Wisp uses a reverse-engineered implementation of the WhatsApp multi-device protocol ([whatsmeow](https://github.com/tulir/whatsmeow)). Using it breaks WhatsApp's Terms of Service, and your account could be banned. It's a personal project, not affiliated with WhatsApp or Meta. Use a secondary number if you're cautious.

## Status

Early, but usable for text:

- [x] QR pairing, auto-reconnect, logout
- [x] History sync and live messages saved to a local SQLite database
- [x] Chat list (pinned, unread, muted, archived hidden), paged message timeline, sending text, read receipts
- [ ] Polished timeline: read ticks, typing indicators, multi-line composer
- [ ] Media: images, voice notes, documents, stickers
- [ ] Reactions, replies, edits and deletes, search, notifications
- [ ] Menu bar mode, auto-update

Voice and video calls are out of scope.

## Architecture

```
┌──────────────────────────────────────────────┐
│  AppKit UI (Swift)                           │
│  NSTableView chat list + message timeline    │
└──────────────┬───────────────────────────────┘
               │ read-only SQL        ▲ "chats changed" events
┌──────────────▼───────────────────────────────┐
│  messages.db (SQLite, WAL)                   │
└──────────────▲───────────────────────────────┘
               │ sole writer, batched transactions
┌──────────────┴───────────────────────────────┐
│  Go core: whatsmeow built as a static         │
│  c-archive, linked into the app binary        │
└──────────────────────────────────────────────┘
```

Choices made for performance:

- **One process, no web view.** The Go protocol core is linked into the app as a static library and called through a small C interface ([`wisp.h`](app/Sources/CWisp/include/wisp.h)). There's no Electron, no WebKit and no IPC between processes.
- **SQLite is the source of truth, not memory.** Go writes every message to `messages.db`, batching writes that arrive within 30 ms into one transaction, and tells Swift which chats changed. Swift re-queries only what's on screen.
- **Bounded memory.** The Go heap is soft-capped at 48 MB. The timeline holds one page of messages at a time and frees it when you switch chats. Each message's height is measured once and cached, so scrolling never re-measures text.
- **One SQLite library.** Both sides link the system `libsqlite3`, so the process never runs two copies of SQLite against the same files.
- **AppKit over SwiftUI** for the long, scrolling lists, where it matters most.

The window's subtitle shows the app's live physical memory footprint. That's the same number Activity Monitor shows, and it's the one the budgets are measured against.

## Building

Requirements: macOS 14 or later, Xcode Command Line Tools (Swift 6), and Go 1.27 or later (`brew install go`). Full Xcode isn't needed.

```sh
scripts/build.sh          # release build → build/Wisp.app
scripts/build.sh debug
open build/Wisp.app
```

The script builds the Go core into `core/build/libwisp.a`, builds the Swift package, and assembles and ad-hoc signs the `.app` bundle.

```sh
scripts/measure.sh        # current and peak physical footprint of a running Wisp
cd core && go test -tags "libsqlite3 sqlite_omit_load_extension" ./...
```

On first launch, scan the QR code from your phone: **WhatsApp → Settings → Linked devices → Link a device**. Data is stored in `~/Library/Application Support/Wisp/`:

- `session.db`: encryption keys and session state (whatsmeow)
- `messages.db`: chats and messages

## Layout

```
core/                     Go protocol core (package main, built with -buildmode=c-archive)
  core.go                 exported C functions
  events.go               whatsmeow events → storage and app events
  store.go                messages.db schema and the batched writer
app/
  Sources/CWisp/          C module exposing wisp.h, which links libwisp.a
  Sources/Wisp/           AppKit app
scripts/                  build and measurement
```
