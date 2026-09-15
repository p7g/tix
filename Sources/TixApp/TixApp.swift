import SwiftUI
import TixCore

@main struct TixApp: App {
    var body: some Scene {
        WindowGroup {
            PrototypeView().frame(minWidth: 1000, minHeight: 600)
        }
    }
}
private struct PrototypeView: View {
    @State private var selection: Int64?
    private let layout = try! TicketGraph.lanes([
        Ticket(id: 1, title: "Define configuration rules", status: .done),
        Ticket(id: 2, title: "Settings page skeleton", status: .done),
        Ticket(id: 3, title: "Rule storage and CRUD API", prerequisites: [1]),
        Ticket(id: 4, title: "Rule editor UI", prerequisites: [1, 2]),
        Ticket(id: 5, title: "Configuration resolver", prerequisites: [3]),
        Ticket(id: 6, title: "Integrate configuration", prerequisites: [3, 4, 5])
    ])
    var body: some View {
        TicketTable(rows: layout.rows.map { DisplayRow(ticket: $0.ticket, lane: $0) }, laneWidth: layout.width, showsLanes: true, selection: $selection)
    }
}
