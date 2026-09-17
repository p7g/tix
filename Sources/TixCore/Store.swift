import Foundation
import GRDB

/// One persistent connection per surface; data_version comparisons use this connection.
public final class TicketStore: Sendable {
    private let queue: DatabaseQueue
    public let path: String

    public init(path: String, create: Bool = false) throws {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        if !create && !FileManager.default.fileExists(atPath: self.path) {
            throw TixError.invalid(
                "Workspace database does not exist: \(self.path). Create it in Tix first."
            )
        }
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.foreignKeysEnabled = true
        queue = try DatabaseQueue(path: self.path, configuration: configuration)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(
                sql: """
                    CREATE TABLE tickets (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                        body TEXT NOT NULL DEFAULT '',
                        status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','active','done')),
                        owner TEXT,
                        createdAt REAL NOT NULL,
                        updatedAt REAL NOT NULL,
                        revision INTEGER NOT NULL DEFAULT 1
                    );
                    CREATE TABLE dependencies (
                        ticket INTEGER NOT NULL REFERENCES tickets(id),
                        prerequisite INTEGER NOT NULL REFERENCES tickets(id),
                        PRIMARY KEY(ticket, prerequisite),
                        CHECK(ticket != prerequisite)
                    );
                    CREATE INDEX dependencies_by_prerequisite ON dependencies(prerequisite);
                    """
            )
        }
        try migrator.migrate(queue)
    }

    public func dataVersion() throws -> Int64 {
        try queue.read { db in
            try Int64.fetchOne(db, sql: "PRAGMA data_version")!
        }
    }

    public func list(status: TicketStatus? = nil, ready: Bool? = nil) throws
        -> [Ticket]
    {
        try queue.read { db in
            try Self.all(db).filter { ticket in
                (status == nil || ticket.status == status)
                    && (ready == nil || ticket.ready == ready)
            }
        }
    }

    public func get(_ id: Int64) throws -> Ticket {
        try queue.read { try Self.ticket($0, id) }
    }

    @discardableResult public func create(title: String, body: String = "")
        throws -> Ticket
    {
        let title = try Self.validText(title, field: "Title")
        return try queue.write { db in
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql:
                    "INSERT INTO tickets(title, body, createdAt, updatedAt) VALUES (?, ?, ?, ?)",
                arguments: [title, body, now, now]
            )
            return try Self.ticket(db, db.lastInsertedRowID)
        }
    }

    /// expectedRevision provides optimistic concurrency. Explicit overwrite omits it.
    @discardableResult public func edit(
        _ id: Int64,
        title: String? = nil,
        body: String? = nil,
        expectedRevision: Int64? = nil
    ) throws -> Ticket {
        let cleanTitle = try title.map {
            try Self.validText($0, field: "Title")
        }
        return try queue.write { db in
            let current = try Self.ticket(db, id)
            if let expectedRevision, current.revision != expectedRevision {
                throw TixError.conflict(current)
            }
            try db.execute(
                sql:
                    "UPDATE tickets SET title = ?, body = ?, updatedAt = ?, revision = revision + 1 WHERE id = ?",
                arguments: [
                    cleanTitle ?? current.title, body ?? current.body,
                    Date().timeIntervalSince1970, id,
                ]
            )
            return try Self.ticket(db, id)
        }
    }

    @discardableResult public func addDependency(
        _ id: Int64,
        prerequisite: Int64
    ) throws -> Ticket {
        try queue.write { db in
            _ = try Self.ticket(db, id)
            _ = try Self.ticket(db, prerequisite)
            guard id != prerequisite else {
                throw TixError.invalid("A ticket cannot depend on itself.")
            }
            if try Bool.fetchOne(
                db,
                sql:
                    "SELECT EXISTS(SELECT 1 FROM dependencies WHERE ticket = ? AND prerequisite = ?)",
                arguments: [id, prerequisite]
            ) == true {
                throw TixError.invalid(
                    "TIX-\(id) already depends on TIX-\(prerequisite)."
                )
            }
            let cycle = try Bool.fetchOne(
                db,
                sql: """
                    WITH RECURSIVE ancestors(id) AS (
                        SELECT ? UNION SELECT prerequisite FROM dependencies JOIN ancestors ON ticket = ancestors.id
                    ) SELECT EXISTS(SELECT 1 FROM ancestors WHERE id = ?)
                    """,
                arguments: [prerequisite, id]
            )!
            guard !cycle else {
                throw TixError.invalid("That dependency would create a cycle.")
            }
            try db.execute(
                sql:
                    "INSERT INTO dependencies(ticket, prerequisite) VALUES (?, ?)",
                arguments: [id, prerequisite]
            )
            try Self.touch(db, id)
            try Self.touch(db, prerequisite)
            return try Self.ticket(db, id)
        }
    }

    @discardableResult public func removeDependency(
        _ id: Int64,
        prerequisite: Int64
    ) throws -> Ticket {
        try queue.write { db in
            _ = try Self.ticket(db, id)
            _ = try Self.ticket(db, prerequisite)
            try db.execute(
                sql:
                    "DELETE FROM dependencies WHERE ticket = ? AND prerequisite = ?",
                arguments: [id, prerequisite]
            )
            guard db.changesCount > 0 else {
                throw TixError.invalid("That dependency does not exist.")
            }
            try Self.touch(db, id)
            try Self.touch(db, prerequisite)
            return try Self.ticket(db, id)
        }
    }

    @discardableResult public func claim(_ id: Int64, owner: String) throws
        -> Ticket
    {
        let owner = try Self.validText(owner, field: "Owner")
        return try queue.write { db in
            let ticket = try Self.ticket(db, id)
            guard ticket.ready else { throw TixError.conflict(ticket) }
            try db.execute(
                sql:
                    "UPDATE tickets SET status = 'active', owner = ? WHERE id = ?",
                arguments: [owner, id]
            )
            try Self.touch(db, id)
            return try Self.ticket(db, id)
        }
    }

    public enum Action: String, Sendable { case release, complete, reopen }
    @discardableResult public func transition(_ id: Int64, _ action: Action)
        throws -> Ticket
    {
        try queue.write { db in
            let current = try Self.ticket(db, id)
            let status: TicketStatus
            let owner: String?
            switch action {
            case .release:
                guard current.status == .active else {
                    throw TixError.invalid(
                        "Only active tickets can be released."
                    )
                }
                status = .open
                owner = nil
            case .complete:
                guard current.status != .done else {
                    throw TixError.invalid("Ticket is already done.")
                }
                status = .done
                owner = current.owner
            case .reopen:
                guard current.status == .done else {
                    throw TixError.invalid(
                        "Only completed tickets can be reopened."
                    )
                }
                status = .open
                owner = nil
            }
            try db.execute(
                sql: "UPDATE tickets SET status = ?, owner = ? WHERE id = ?",
                arguments: [status.rawValue, owner, id]
            )
            try Self.touch(db, id)
            return try Self.ticket(db, id)
        }
    }

    private static func validText(_ value: String, field: String) throws
        -> String
    {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            throw TixError.invalid("\(field) must not be empty.")
        }
        return result
    }
    private static func touch(_ db: Database, _ id: Int64) throws {
        try db.execute(
            sql:
                "UPDATE tickets SET updatedAt = ?, revision = revision + 1 WHERE id = ?",
            arguments: [Date().timeIntervalSince1970, id]
        )
    }
    private static func ticket(_ db: Database, _ id: Int64) throws -> Ticket {
        guard let ticket = try all(db).first(where: { $0.id == id }) else {
            throw TixError.invalid("TIX-\(id) does not exist.")
        }
        return ticket
    }
    private static func all(_ db: Database) throws -> [Ticket] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM tickets ORDER BY id"
        )
        let edges = try Row.fetchAll(
            db,
            sql:
                "SELECT ticket, prerequisite FROM dependencies ORDER BY ticket, prerequisite"
        )
        var prerequisites: [Int64: [Int64]] = [:]
        var dependents: [Int64: [Int64]] = [:]
        let completed = Set(
            rows.filter { ($0["status"] as String) == "done" }.map {
                $0["id"] as Int64
            }
        )
        for edge in edges {
            let ticket: Int64 = edge["ticket"]
            let prerequisite: Int64 = edge["prerequisite"]
            prerequisites[ticket, default: []].append(prerequisite)
            dependents[prerequisite, default: []].append(ticket)
        }
        return rows.map { row in
            let id: Int64 = row["id"]
            let deps = prerequisites[id] ?? []
            return Ticket(
                id: id,
                title: row["title"],
                body: row["body"],
                status: TicketStatus(rawValue: row["status"])!,
                owner: row["owner"],
                createdAt: row["createdAt"],
                updatedAt: row["updatedAt"],
                revision: row["revision"],
                prerequisites: deps,
                dependents: dependents[id] ?? [],
                blockers: deps.filter { !completed.contains($0) }
            )
        }
    }
}
