import AppKit
import SwiftUI
import TixCore

@MainActor final class TicketDraft: ObservableObject {
    @Published var title: String
    @Published var body: String
    @Published var latest: Ticket
    @Published var base: Ticket
    var dirty: Bool { title != base.title || body != base.body }
    var conflicted: Bool { dirty && latest.revision != base.revision }
    init(_ ticket: Ticket) {
        title = ticket.title; body = ticket.body; latest = ticket; base = ticket
    }
    func receive(_ ticket: Ticket) {
        if !dirty { reload(ticket) } else { latest = ticket }
    }
    func reload(_ ticket: Ticket? = nil) {
        let ticket = ticket ?? latest
        base = ticket; latest = ticket; title = ticket.title; body = ticket.body
    }
}

@MainActor final class WorkspaceModel: ObservableObject {
    @Published var tickets: [Ticket] = []
    @Published var selection: Int64?
    @Published var path: String?
    @Published var error: String?
    @Published var recent: [String] = UserDefaults.standard.stringArray(forKey: "recentWorkspaces") ?? []
    @Published var mode = "Waves"
    @Published var newTicketRequest = 0
    @Published var showCompleted = false
    private var store: TicketStore?
    private var version: Int64?
    private var drafts: [Int64: TicketDraft] = [:]
    var hasUnsavedChanges: Bool { drafts.values.contains(where: \.dirty) }
    var title: String { path.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent } ?? "Tix" }
    var selectedDraft: TicketDraft? {
        guard let selection, let ticket = tickets.first(where: { $0.id == selection }) else { return nil }
        if let draft = drafts[selection] { return draft }
        let draft = TicketDraft(ticket); drafts[selection] = draft; return draft
    }
    var lanes: LaneLayout { (try? TicketGraph.lanes(tickets)) ?? LaneLayout(rows: [], width: 1) }
    var displayRows: [DisplayRow] {
        if mode == "Lanes" { return lanes.rows.map { DisplayRow(ticket: $0.ticket, lane: $0) } }
        var rows: [DisplayRow] = []
        for wave in (try? TicketGraph.waves(tickets)) ?? [] {
            rows.append(DisplayRow(heading: "Wave \(wave.id)\(wave.id == 1 ? " · No unfinished prerequisites" : "")"))
            rows += wave.tickets.map { DisplayRow(ticket: $0) }
        }
        if showCompleted {
            let done = tickets.filter { $0.status == .done }
            if !done.isEmpty { rows.append(DisplayRow(heading: "Completed")) }
            rows += done.map { DisplayRow(ticket: $0) }
        }
        return rows
    }
    func restore() {
        if let first = recent.first, FileManager.default.fileExists(atPath: first) { open(first) }
    }
    func confirmDiscard() -> Bool {
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved ticket edits?"
        alert.informativeText = "Some tickets have drafts that have not been saved."
        alert.addButton(withTitle: "Keep Editing"); alert.addButton(withTitle: "Discard Edits")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func open(_ path: String) {
        guard confirmDiscard() else { return }
        do {
            let next = try TicketStore(path: path)
            let initialVersion = try next.dataVersion()
            let initial = try next.list()
            store = next; self.path = next.path; tickets = initial
            selection = nil; drafts = [:]; version = initialVersion
            recent = [next.path] + recent.filter { $0 != next.path }
            recent = Array(recent.prefix(10))
            UserDefaults.standard.set(recent, forKey: "recentWorkspaces")
        } catch { self.error = error.localizedDescription }
    }
    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Open Tix Workspace"; panel.message = "Choose the workspace folder containing tickets.sqlite."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url.appendingPathComponent("tickets.sqlite").path) }
    }
    func createWorkspace() {
        guard confirmDiscard() else { return }
        let panel = NSSavePanel()
        panel.title = "New Tix Workspace"; panel.message = "Choose a name and location outside your source checkout."
        panel.nameFieldStringValue = "My Workspace"; panel.prompt = "Create Workspace"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var ancestor = url.deletingLastPathComponent().resolvingSymlinksInPath()
            while ancestor.path != "/" {
                if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
                    throw TixError.invalid("Choose a location outside a Git checkout, so all worktrees share the same workspace.")
                }
                ancestor.deleteLastPathComponent()
            }
            guard !FileManager.default.fileExists(atPath: url.path) else { throw TixError.invalid("That location already exists. Choose a new workspace name or open the existing workspace.") }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            _ = try TicketStore(path: url.appendingPathComponent("tickets.sqlite").path, create: true)
            // Discard was already approved, and the workspace is now ready to open.
            drafts = [:]
            open(url.appendingPathComponent("tickets.sqlite").path)
        } catch { self.error = error.localizedDescription }
    }
    func refresh(force: Bool = false) {
        guard let store else { return }
        do {
            let nextVersion = try store.dataVersion()
            guard force || nextVersion != version else { return }
            let next = try store.list()
            tickets = next; version = nextVersion
            for ticket in next { drafts[ticket.id]?.receive(ticket) }
        } catch { self.error = error.localizedDescription }
    }
    func createTicket(_ title: String) -> Bool {
        guard let store else { return false }
        do {
            let ticket = try store.create(title: title)
            refresh(force: true); selection = ticket.id
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func save(_ draft: TicketDraft, overwrite: Bool = false) {
        guard let store else { return }
        do {
            let ticket = try store.edit(draft.base.id, title: draft.title, body: draft.body, expectedRevision: overwrite ? nil : draft.base.revision)
            draft.reload(ticket); refresh(force: true)
        } catch TixError.conflict(let current) {
            draft.receive(current)
        } catch { self.error = error.localizedDescription }
    }
    func action(_ id: Int64, _ action: TicketStore.Action) {
        mutate { try $0.transition(id, action) }
    }
    func claim(_ id: Int64, owner: String) { mutate { try $0.claim(id, owner: owner) } }
    func dependency(_ id: Int64, prerequisite: Int64, add: Bool) {
        mutate { store in
            if add { return try store.addDependency(id, prerequisite: prerequisite) }
            return try store.removeDependency(id, prerequisite: prerequisite)
        }
    }
    private func mutate(_ operation: (TicketStore) throws -> Ticket) {
        guard let store else { return }
        do { _ = try operation(store); refresh(force: true) }
        catch { self.error = error.localizedDescription; refresh(force: true) }
    }
}
