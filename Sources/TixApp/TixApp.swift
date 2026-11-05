import AppKit
import SwiftUI
import TixCore

@main struct TixApp: App {
    @StateObject private var model = WorkspaceModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("Tix", id: "main") {
            WorkspaceView(model: model)
                .frame(minWidth: 1100, minHeight: 650)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1280, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Ticket") { model.newTicketRequest += 1 }
                    .keyboardShortcut("n").disabled(model.path == nil)
                Divider()
                Button("New Workspace…", action: model.createWorkspace)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open Workspace…", action: model.chooseWorkspace)
                    .keyboardShortcut("o")
            }
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: WorkspaceModel?
    func applicationShouldTerminate(_ sender: NSApplication)
        -> NSApplication.TerminateReply
    {
        model?.confirmDiscard() == false ? .terminateCancel : .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool { true }
}

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var showingNewTicket = false
    @Environment(\.scenePhase) private var scenePhase
    private let timer = Timer.publish(every: 1, on: .main, in: .common)
        .autoconnect()
    var body: some View {
        VStack(spacing: 0) {
            if model.path == nil {
                welcome
            } else {
                TicketSearchBar(model: model)
                Divider()
                HSplitView {
                    VStack(spacing: 0) {
                        TicketTable(
                            rows: model.displayRows,
                            laneWidth: model.mode == "Lanes" && !model.isSearching ? model.lanes.width : 1,
                            showsLanes: model.mode == "Lanes" && !model.isSearching,
                            selection: $model.selection
                        )
                        .overlay {
                            if model.isSearching && model.displayRows.isEmpty {
                                ContentUnavailableView.search(text: model.searchQuery)
                            }
                        }
                        Divider()
                        HStack {
                            Text(
                                model.isSearching ? "\(model.displayRows.count) matches" : "\(model.tickets.count) tickets"
                            )
                            Spacer()
                            let counts = Dictionary(
                                grouping: model.tickets, by: \.statusCategory
                            ).mapValues(\.count)
                            ForEach(StatusCategory.allCases, id: \.self) {
                                statusLegend($0, count: counts[$0] ?? 0)
                            }
                        }.font(.caption).foregroundStyle(.secondary).padding(10)
                    }.frame(minWidth: 630)
                    if let draft = model.selectedDraft {
                        TicketDetail(model: model, draft: draft).id(
                            draft.base.id
                        ).frame(minWidth: 340, idealWidth: 370, maxWidth: 500)
                    } else {
                        ContentUnavailableView(
                            "Select a ticket",
                            systemImage: "ticket",
                            description: Text(
                                "Inspect its details and dependencies."
                            )
                        )
                        .frame(
                            minWidth: 340,
                            idealWidth: 370,
                            maxWidth: 500,
                            maxHeight: .infinity
                        )
                    }
                }
            }
        }
        .navigationTitle(model.title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Button("New Workspace…", action: model.createWorkspace)
                    Button("Open Workspace…", action: model.chooseWorkspace)
                    if !model.recent.isEmpty {
                        Divider()
                        ForEach(model.recent, id: \.self) { path in
                            Button(
                                URL(fileURLWithPath: path)
                                    .deletingLastPathComponent()
                                    .lastPathComponent
                            ) { model.open(path) }.help(path)
                        }
                    }
                } label: {
                    Label("Workspace", systemImage: "folder")
                }
            }
            ToolbarItem {
                Button { showingNewTicket = true } label: {
                    Label("New Ticket", systemImage: "plus")
                }
                .help("New Ticket (⌘N)")
                .disabled(model.path == nil)
            }
            ToolbarItem {
                if model.path != nil {
                    Toggle("Show done", isOn: $model.showCompleted)
                        .toggleStyle(.checkbox)
                }
            }
            ToolbarItem {
                if model.path != nil {
                    Picker("View", selection: $model.mode) {
                        Text("Waves").tag("Waves")
                        Text("Lanes").tag("Lanes")
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isSearching)
                }
            }
        }
        .sheet(isPresented: $showingNewTicket) {
            NewTicketSheet(model: model)
        }
        .onAppear { if model.path == nil { model.restore() } }
        .onChange(of: model.newTicketRequest) { _, _ in
            if model.path != nil { showingNewTicket = true }
        }
        .onReceive(timer) { _ in
            if NSApp.windows.contains(where: {
                $0.isVisible && !$0.isMiniaturized
            }) {
                model.refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh(force: true) }
        }
        .alert(
            "Couldn't complete operation",
            isPresented: Binding(
                get: { model.error != nil },
                set: { if !$0 { model.error = nil } }
            )
        ) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }
    private func statusLegend(_ category: StatusCategory, count: Int) -> some View {
        HStack(spacing: 4) {
            Circle().fill(Color(nsColor: category.color)).frame(width: 6, height: 6)
            Text("\(count) \(category.title)").monospacedDigit()
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "ticket").font(.system(size: 44)).foregroundStyle(
                .tint
            )
            Text("Work, connected.").font(.largeTitle.bold())
            Text("A local workspace for you and your coding agents.")
                .foregroundStyle(.secondary)
            HStack {
                Button("New Workspace…", action: model.createWorkspace)
                    .buttonStyle(.borderedProminent)
                Button("Open Workspace…", action: model.chooseWorkspace)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Keep keystrokes local so the workspace and AppKit table only update after a pause.
struct TicketSearchBar: View {
    @ObservedObject var model: WorkspaceModel
    @State private var text = ""

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search tickets by title, ID, or description", text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search tickets")
                .onSubmit { model.searchQuery = text }
            if !text.isEmpty {
                Button {
                    text = ""
                    model.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }.buttonStyle(.plain).help("Clear search")
            }
        }
        .padding(12)
        .onAppear { text = model.searchQuery }
        .onChange(of: model.searchRevision) { _, _ in
            // Also cancel pending text when navigation or creation resets the search,
            // including when the committed query was already empty.
            text = model.searchQuery
        }
        .task(id: text) {
            guard text != model.searchQuery else { return }
            let query = text
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            model.searchQuery = query
        }
    }
}

struct NewTicketSheet: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var creationError: String?
    @FocusState private var titleFocused: Bool

    private var validTitle: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Ticket").font(.title2.bold())
            TextField("Ticket title", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
                .onSubmit(createTicket)
            if let creationError {
                Text(creationError).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Ticket", action: createTicket)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validTitle)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { titleFocused = true }
    }

    private func createTicket() {
        guard validTitle else { return }
        if model.createTicket(title) {
            dismiss()
        } else {
            creationError = model.error
            model.error = nil
        }
    }
}

struct TicketDetail: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var draft: TicketDraft
    @State private var owner = NSUserName()
    @State private var prerequisite: Int64?
    @State private var preview = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(draft.latest.displayID).font(
                        .system(.headline, design: .monospaced)
                    )
                    Spacer()
                    Text(draft.latest.status.rawValue.capitalized)
                        .foregroundStyle(.secondary)
                }
                TextField("Title", text: $draft.title).font(
                    .title3.weight(.semibold)
                ).textFieldStyle(.roundedBorder)
                Picker("Priority", selection: $draft.priority) {
                    ForEach(TicketPriority.allCases, id: \.self) { priority in
                        Text(priority.label).tag(priority)
                    }
                }
                HStack {
                    Text("Description").font(.headline)
                    Spacer()
                    Toggle("Preview", isOn: $preview).toggleStyle(.checkbox)
                }
                if preview {
                    Text(
                        (try? AttributedString(
                            markdown: draft.body,
                            options: .init(
                                interpretedSyntax:
                                    .inlineOnlyPreservingWhitespace
                            )
                        )) ?? AttributedString(draft.body)
                    )
                    .textSelection(.enabled).frame(
                        maxWidth: .infinity,
                        minHeight: 180,
                        alignment: .topLeading
                    )
                } else {
                    TextEditor(text: $draft.body).font(.body).frame(
                        minHeight: 180
                    ).border(.quaternary).accessibilityLabel(
                        "Ticket description"
                    )
                }
                if draft.conflicted {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "This ticket changed elsewhere.",
                            systemImage: "exclamationmark.triangle"
                        ).font(.headline)
                        Text(
                            "Your draft is preserved. Reload the current ticket or explicitly overwrite its title, description, and priority."
                        ).font(.caption)
                        HStack {
                            Button("Reload") { draft.reload() }
                            Button("Overwrite") {
                                model.save(draft, overwrite: true)
                            }
                        }
                    }.padding(10).background(
                        .orange.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
                HStack {
                    Button("Save") { model.save(draft) }.keyboardShortcut("s")
                        .disabled(!draft.dirty || draft.conflicted)
                    if draft.dirty && !draft.conflicted {
                        Button("Discard Edits") { draft.reload() }
                    }
                    Spacer()
                    if draft.dirty {
                        Text("Unsaved").font(.caption).foregroundStyle(
                            .secondary
                        )
                    }
                }
                Divider()
                if draft.latest.status == .open {
                    HStack {
                        TextField("Owner", text: $owner).textFieldStyle(
                            .roundedBorder
                        )
                        Button("Claim") {
                            model.claim(draft.latest.id, owner: owner)
                        }.disabled(
                            !draft.latest.ready
                                || owner.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty
                        )
                    }
                } else if let owner = draft.latest.owner {
                    Label(owner, systemImage: "person")
                }
                HStack {
                    if draft.latest.status == .active {
                        Button("Release") {
                            model.action(draft.latest.id, .release)
                        }
                    }
                    if draft.latest.status != .done {
                        Button("Complete") {
                            model.action(draft.latest.id, .complete)
                        }
                    } else {
                        Button("Reopen") {
                            model.action(draft.latest.id, .reopen)
                        }
                    }
                }
                if !draft.latest.blockers.isEmpty {
                    Text(
                        "Waiting on \(draft.latest.blockers.map { "TIX-\($0)" }.joined(separator: ", "))"
                    ).font(.caption).foregroundStyle(.orange)
                }
                Divider()
                Text("Prerequisites").font(.headline)
                if draft.latest.prerequisites.isEmpty {
                    Text("No prerequisites").foregroundStyle(.secondary)
                }
                ForEach(draft.latest.prerequisites, id: \.self) { id in
                    HStack {
                        ticketLink(id)
                        Spacer()
                        Button {
                            model.dependency(
                                draft.latest.id,
                                prerequisite: id,
                                add: false
                            )
                        } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.borderless).help("Remove prerequisite")
                    }
                }
                HStack {
                    Picker("Add prerequisite", selection: $prerequisite) {
                        Text("Choose ticket…").tag(nil as Int64?)
                        ForEach(
                            model.tickets.filter {
                                $0.id != draft.latest.id
                                    && !draft.latest.prerequisites.contains(
                                        $0.id
                                    )
                            }
                        ) { ticket in
                            Text("\(ticket.displayID) · \(ticket.title)").tag(
                                Optional(ticket.id)
                            )
                        }
                    }.labelsHidden()
                    Button("Add") {
                        if let prerequisite {
                            model.dependency(
                                draft.latest.id,
                                prerequisite: prerequisite,
                                add: true
                            )
                            self.prerequisite = nil
                        }
                    }.disabled(prerequisite == nil)
                }
                if !draft.latest.dependents.isEmpty {
                    Text("Unblocks").font(.headline)
                    ForEach(draft.latest.dependents, id: \.self) {
                        ticketLink($0)
                    }
                }
            }.padding(18)
        }
    }
    private func ticketLink(_ id: Int64) -> some View {
        Button {
            if model.tickets.first(where: { $0.id == id })?.status == .done {
                model.showCompleted = true
            }
            model.searchQuery = ""
            model.selection = id
        } label: {
            Text(
                "TIX-\(id) · \(model.tickets.first(where: { $0.id == id })?.title ?? "")"
            ).lineLimit(2).multilineTextAlignment(.leading)
        }.buttonStyle(.link)
    }
}
