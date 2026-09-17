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
    @State private var newTitle = ""
    @FocusState private var creating: Bool
    @Environment(\.scenePhase) private var scenePhase
    private let timer = Timer.publish(every: 1, on: .main, in: .common)
        .autoconnect()
    var body: some View {
        VStack(spacing: 0) {
            if model.path == nil {
                welcome
            } else {
                HStack {
                    TextField("New ticket title", text: $newTitle)
                        .textFieldStyle(.roundedBorder).focused($creating)
                        .onSubmit(createTicket)
                    Button("Add Ticket", action: createTicket).disabled(
                        newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                    )
                }.padding(12)
                Divider()
                HSplitView {
                    VStack(spacing: 0) {
                        TicketTable(
                            rows: model.displayRows,
                            laneWidth: model.lanes.width,
                            showsLanes: model.mode == "Lanes",
                            selection: $model.selection
                        )
                        Divider()
                        HStack {
                            Text(
                                "\(model.tickets.count) tickets · \(model.tickets.filter(\.ready).count) ready"
                            )
                            Spacer()
                            if model.mode == "Waves" {
                                Toggle(
                                    "Completed (\(model.tickets.filter { $0.status == .done }.count))",
                                    isOn: $model.showCompleted
                                ).toggleStyle(.checkbox)
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
                if model.path != nil {
                    Picker("View", selection: $model.mode) {
                        Text("Waves").tag("Waves")
                        Text("Lanes").tag("Lanes")
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .onAppear { if model.path == nil { model.restore() } }
        .onChange(of: model.newTicketRequest) { _, _ in creating = true }
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
    private func createTicket() {
        if model.createTicket(newTitle) {
            newTitle = ""
            creating = true
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
                            "Your draft is preserved. Reload the current ticket or explicitly overwrite its title and description."
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
            model.selection = id
        } label: {
            Text(
                "TIX-\(id) · \(model.tickets.first(where: { $0.id == id })?.title ?? "")"
            ).lineLimit(2).multilineTextAlignment(.leading)
        }.buttonStyle(.link)
    }
}
