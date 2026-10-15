import SQLite3

/// A minimal read-only SQLite connection with a prepared-statement cache.
/// Links the same system libsqlite3 the Go core uses, so there's one SQLite in
/// the process. Queries here are small, indexed and run on the main thread.
@MainActor
final class Database {
    enum Value {
        case int(Int64)
        case text(String)
    }

    struct Row {
        fileprivate let stmt: OpaquePointer
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func bool(_ i: Int32) -> Bool { sqlite3_column_int64(stmt, i) != 0 }
        func text(_ i: Int32) -> String {
            guard let p = sqlite3_column_text(stmt, i) else { return "" }
            return String(cString: p)
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init(path: String) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw Failure(description: message)
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    func query<T>(_ sql: String, _ args: [Value] = [], map: (Row) -> T) -> [T] {
        guard let stmt = statement(sql) else { return [] }
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, sqliteTransient)
            }
        }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(map(Row(stmt: stmt)))
        }
        return out
    }

    private func statement(_ sql: String) -> OpaquePointer? {
        if let cached = statements[sql] { return cached }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil) == SQLITE_OK else {
            print("sqlite prepare failed: \(String(cString: sqlite3_errmsg(handle))) — \(sql)")
            return nil
        }
        statements[sql] = stmt
        return stmt
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
