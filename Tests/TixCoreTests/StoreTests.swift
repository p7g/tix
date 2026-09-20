import Foundation
import Testing
@testable import TixCore

struct StoreTests {
    private func workspace() throws -> (TicketStore, String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tix-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try TicketStore(path: folder.appendingPathComponent("tickets.sqlite").path, create: true), folder.path)
    }
    @Test func lifecycleAndDependencies() throws {
        let (store, folder) = try workspace(); defer { try? FileManager.default.removeItem(atPath: folder) }
        let a = try store.create(title: " A ", body: "**Done means** passing tests")
        let b = try store.create(title: "B")
        #expect(a.title == "A")
        #expect(a.ready)
        try store.addDependency(b.id, prerequisite: a.id)
        #expect(try store.get(b.id).blockers == [a.id])
        #expect(try store.get(a.id).dependents == [b.id])
        #expect(throws: TixError.self) { try store.claim(b.id, owner: "agent") }
        try store.claim(a.id, owner: "alice")
        #expect(try store.transition(a.id, .complete).owner == "alice")
        #expect(try store.list(ready: true).map(\.id) == [b.id])
        try store.claim(b.id, owner: "bob")
        try store.transition(a.id, .reopen)
        #expect(try store.get(b.id).status == .active)
        #expect(try store.get(b.id).blockers == [a.id])
        #expect(try store.transition(b.id, .release).owner == nil)
        try store.removeDependency(b.id, prerequisite: a.id)
        #expect(try store.get(b.id).ready)
    }
    @Test func rejectedEdgesRollback() throws {
        let (store, folder) = try workspace(); defer { try? FileManager.default.removeItem(atPath: folder) }
        let a = try store.create(title: "A"); let b = try store.create(title: "B"); let c = try store.create(title: "C")
        try store.addDependency(b.id, prerequisite: a.id); try store.addDependency(c.id, prerequisite: b.id)
        let before = try store.list()
        for (id, prerequisite) in [(a.id, c.id), (a.id, a.id), (b.id, a.id), (c.id, 999)] {
            #expect(throws: TixError.self) { try store.addDependency(id, prerequisite: prerequisite) }
            #expect(try store.list() == before)
        }
        #expect(throws: TixError.self) { try store.create(title: " \n ") }
        #expect(throws: TixError.self) { try store.claim(a.id, owner: " ") }
    }
    @Test func staleEditAndDataVersion() throws {
        let (store, folder) = try workspace(); defer { try? FileManager.default.removeItem(atPath: folder) }
        let other = try TicketStore(path: store.path)
        let ticket = try store.create(title: "Original")
        let version = try store.dataVersion()
        try other.edit(ticket.id, body: "Agent update")
        #expect(try store.dataVersion() != version)
        #expect(throws: TixError.self) { try store.edit(ticket.id, title: "Human draft", expectedRevision: ticket.revision) }
        #expect(try store.get(ticket.id).body == "Agent update")
        let overwritten = try store.edit(ticket.id, title: "Human draft", body: "Explicit overwrite")
        #expect(overwritten.revision == ticket.revision + 2)
    }
    @Test func competingClaims() async throws {
        let (store, folder) = try workspace(); defer { try? FileManager.default.removeItem(atPath: folder) }
        let other = try TicketStore(path: store.path)
        let ticket = try store.create(title: "One owner")
        let successes = await withTaskGroup(of: Bool.self) { group in
            for (connection, owner) in [(store, "alice"), (other, "bob")] {
                group.addTask { (try? connection.claim(ticket.id, owner: owner)) != nil }
            }
            var count = 0; for await success in group { if success { count += 1 } }; return count
        }
        #expect(successes == 1)
        #expect(try store.get(ticket.id).status == .active)
    }
    @Test func competingEdgesCannotCreateCycle() async throws {
        let (store, folder) = try workspace(); defer { try? FileManager.default.removeItem(atPath: folder) }
        let other = try TicketStore(path: store.path)
        let a = try store.create(title: "A"); let b = try store.create(title: "B")
        let successes = await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? store.addDependency(a.id, prerequisite: b.id)) != nil }
            group.addTask { (try? other.addDependency(b.id, prerequisite: a.id)) != nil }
            var count = 0; for await success in group { if success { count += 1 } }; return count
        }
        #expect(successes == 1)
        #expect(try TicketGraph.ordered(store.list()).count == 2)
    }
    @Test func priorityPersistsAndRecalculatesAcrossConnections() throws {
        let (store, folder) = try workspace(); defer { try? FileManager.default.removeItem(atPath: folder) }
        let other = try TicketStore(path: store.path)
        let normal = try store.create(title: "Default")
        #expect(normal.priority == .normal)
        let root = try store.create(title: "Root", priority: .low)
        let middle = try store.create(title: "Middle")
        let leaf = try store.create(title: "Urgent", priority: .urgent)
        try store.addDependency(middle.id, prerequisite: root.id)
        try store.addDependency(leaf.id, prerequisite: middle.id)
        #expect(try other.list(ready: true).map(\.id) == [root.id, normal.id])
        #expect(try other.get(root.id).effectivePriority == .urgent)
        try other.edit(leaf.id, priority: .high)
        #expect(try store.get(root.id).effectivePriority == .high)
        #expect(throws: TixError.self) {
            try store.edit(leaf.id, priority: .low, expectedRevision: leaf.revision)
        }
        try store.transition(leaf.id, .complete)
        #expect(try other.get(root.id).effectivePriority == .normal)
        try store.transition(leaf.id, .reopen)
        #expect(try other.get(root.id).effectivePriority == .high)
        try store.removeDependency(middle.id, prerequisite: root.id)
        #expect(try other.get(root.id).effectivePriority == .low)
        #expect(try other.get(leaf.id).priority == .high)
    }

    @Test func missingWorkspaceDoesNotCreateFile() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).sqlite").path
        #expect(throws: TixError.self) { try TicketStore(path: path) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
