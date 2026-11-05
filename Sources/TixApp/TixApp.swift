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
                TicketSearchBar(search: model.search)
                Divider()
                HSplitView {
                    TicketListPane(model: model, search: model.search)
                        .frame(minWidth: 630)
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
                    .disabled(model.search.isActive)
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

/// Shows the ticket table and its footer. Reads search results here rather than in
/// `WorkspaceView`, so a finished search re-renders only this pane, not the detail pane.
struct TicketListPane: View {
    @ObservedObject var model: WorkspaceModel
    var search: SearchModel

    var body: some View {
        let results = search.results
        let rows = model.displayRows(for: results)
        let showsLanes = model.mode == "Lanes" && results == nil
        VStack(spacing: 0) {
            TicketTable(
                rows: rows,
                laneWidth: showsLanes ? model.laneWidth : 1,
                showsLanes: showsLanes,
                selection: $model.selection
            )
            .overlay {
                if let results, rows.isEmpty {
                    ContentUnavailableView.search(text: results.query)
                }
            }
            Divider()
            HStack {
                Text(
                    results != nil ? "\(rows.count) matches" : "\(model.tickets.count) tickets · \(model.tickets.filter(\.ready).count) ready"
                )
                Spacer()
                statusLegend("Ready", color: .green)
                statusLegend("Active", color: .orange)
                statusLegend("Blocked", color: .accentColor)
                statusLegend("Done", color: Color(nsColor: .secondaryLabelColor))
            }.font(.caption).foregroundStyle(.secondary).padding(10)
        }
    }

    private func statusLegend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
        }
    }
}

/// Binds the field to `SearchModel.text`, which only this view reads, so a keystroke
/// re-renders nothing else. Results arrive separately once each search finishes.
struct TicketSearchBar: View {
    @Bindable var search: SearchModel

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search tickets by title, ID, or description", text: $search.text)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search tickets")
            if !search.text.isEmpty {
                Button { search.clear() } label: {
                    Image(systemName: "xmark.circle.fill")
                }.buttonStyle(.plain).help("Clear search")
            }
        }
        .padding(12)
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

/// Offers every other ticket as a new prerequisite of `ticketID`. Re-renders only when
/// `tickets`, `ticketID`, or `prerequisites` change.
struct PrerequisitePicker: View, Equatable {
    // Hold the model without observing it. Observing would re-render the picker on
    // every model change, and the detail pane would re-render it on every draft
    // keystroke; rebuilding one menu item per ticket costs tens of milliseconds.
    let model: WorkspaceModel
    let tickets: [Ticket]
    let ticketID: Int64
    let prerequisites: [Int64]
    @State private var prerequisite: Int64?

    // Compare only the inputs that `body` displays. `model` is the same object for the
    // picker's whole lifetime.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.ticketID == rhs.ticketID && lhs.prerequisites == rhs.prerequisites
            && lhs.tickets == rhs.tickets
    }

    var body: some View {
        HStack {
            Picker("Add prerequisite", selection: $prerequisite) {
                Text("Choose ticket…").tag(nil as Int64?)
                ForEach(
                    tickets.filter {
                        $0.id != ticketID && !prerequisites.contains($0.id)
                    }
                ) { ticket in
                    Text("\(ticket.displayID) · \(ticket.title)").tag(
                        Optional(ticket.id)
                    )
                }
            }.labelsHidden()
            Button("Add") {
                if let prerequisite {
                    model.dependency(ticketID, prerequisite: prerequisite, add: true)
                    self.prerequisite = nil
                }
            }.disabled(prerequisite == nil)
        }
    }
}

struct TicketDetail: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var draft: TicketDraft
    @State private var owner = NSUserName()
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
                PrerequisitePicker(
                    model: model,
                    tickets: model.tickets,
                    ticketID: draft.latest.id,
                    prerequisites: draft.latest.prerequisites
                ).equatable()
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
            model.search.clear()
            model.selection = id
        } label: {
            Text(
                "TIX-\(id) · \(model.tickets.first(where: { $0.id == id })?.title ?? "")"
            ).lineLimit(2).multilineTextAlignment(.leading)
        }.buttonStyle(.link)
    }
}
