import Testing
@testable import TixCore

struct GraphTests {
    @Test func wavesAndStableOrdering() throws {
        let tickets = [Ticket(id: 5), Ticket(id: 4, prerequisites: [2, 3]), Ticket(id: 3, prerequisites: [1]), Ticket(id: 2, prerequisites: [1]), Ticket(id: 1)]
        #expect(try TicketGraph.ordered(tickets).map(\.id) == [1, 2, 3, 4, 5])
        #expect(try TicketGraph.waves(tickets).map { $0.tickets.map(\.id) } == [[1, 5], [2, 3], [4]])
        var done = tickets
        done[4].status = .done; done[3].status = .active
        #expect(try TicketGraph.waves(done).map { $0.tickets.map(\.id) } == [[2, 3, 5], [4]])
    }
    @Test func completedPrerequisiteCutsDepth() throws {
        let tickets = [Ticket(id: 1), Ticket(id: 2, status: .done, prerequisites: [1]), Ticket(id: 3, prerequisites: [2])]
        #expect(try TicketGraph.waves(tickets).map { $0.tickets.map(\.id) } == [[1, 3]])
    }
    @Test func detectsCycle() {
        #expect(throws: TixError.self) { try TicketGraph.ordered([Ticket(id: 1, prerequisites: [2]), Ticket(id: 2, prerequisites: [1])]) }
    }
    @Test func laneReuseBranchesAndJoins() throws {
        let tickets = [Ticket(id: 1), Ticket(id: 2, prerequisites: [1]), Ticket(id: 3, prerequisites: [1]), Ticket(id: 4, prerequisites: [2, 3]), Ticket(id: 5)]
        let layout = try TicketGraph.lanes(tickets)
        #expect(try layout == TicketGraph.lanes(tickets.reversed()))
        #expect(layout.rows.map(\.lane) == [0, 1, 0, 0, 0])
        #expect(layout.width == 2)
        #expect(layout.rows[1].segments.contains { $0.from == 0 && $0.to == 0 && $0.top && !$0.joinsNode })
        #expect(layout.rows[3].segments.filter { $0.top && $0.joinsNode }.count == 2)
        // Every bottom boundary track has a matching top boundary in the next row.
        for (a, b) in zip(layout.rows, layout.rows.dropFirst()) {
            #expect(Set(a.segments.filter { !$0.top }.map(\.to)) == Set(b.segments.filter(\.top).map(\.from)))
        }
    }
    @Test func crossingDoesNotJoinIntermediateTrack() throws {
        let layout = try TicketGraph.lanes([Ticket(id: 1), Ticket(id: 2), Ticket(id: 3), Ticket(id: 4, prerequisites: [1, 3]), Ticket(id: 5, prerequisites: [1, 2])])
        let row = layout.rows[3]
        #expect(row.segments.contains { $0.top && $0.joinsNode && $0.from == 0 && $0.to == 2 })
        #expect(row.segments.contains { $0.top && !$0.joinsNode && $0.from == 1 && $0.to == 1 })
    }
}
