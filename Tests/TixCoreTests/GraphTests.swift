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

    @Test func independentGroupsStayContiguous() throws {
        // IDs interleave a diamond, a standalone ticket, and a smaller chain.
        let tickets = [
            Ticket(id: 1), Ticket(id: 2), Ticket(id: 3),
            Ticket(id: 4, prerequisites: [1]), Ticket(id: 5, prerequisites: [3]),
            Ticket(id: 6, prerequisites: [1]), Ticket(id: 7, prerequisites: [4, 6])
        ]
        let layout = try TicketGraph.lanes(tickets)
        #expect(layout.rows.map(\.id) == [1, 4, 6, 7, 2, 3, 5])
        #expect(try layout == TicketGraph.lanes(tickets.reversed()))
        #expect(layout.width == 2)
        // Nothing from the diamond crosses the standalone row or the next group.
        #expect(layout.rows[4].lane == 0)
        #expect(layout.rows[4].segments.isEmpty)
        #expect(layout.rows[3].segments.allSatisfy { $0.top })
        #expect(layout.rows[5].segments.allSatisfy { !$0.top })
        #expect(layout.rows[5].lane == 0)
        // Grouping is a lane concern; wave membership remains unchanged.
        #expect(try TicketGraph.waves(tickets).map { $0.tickets.map(\.id) } == [[1, 2, 3], [4, 5, 6], [7]])
    }

    @Test func joinedRootsAndCompletedTicketsStayInOneGroup() throws {
        let tickets = [
            Ticket(id: 1, prerequisites: [6]), Ticket(id: 2),
            Ticket(id: 3, prerequisites: [1, 5]), Ticket(id: 4, prerequisites: [2]),
            Ticket(id: 5, status: .done), Ticket(id: 6, status: .done)
        ]
        let layout = try TicketGraph.lanes(tickets)
        #expect(layout.rows.map(\.id) == [5, 6, 1, 3, 2, 4])
        let positions = Dictionary(uniqueKeysWithValues: layout.rows.enumerated().map { ($0.element.id, $0.offset) })
        for ticket in tickets {
            for prerequisite in ticket.prerequisites {
                #expect(positions[prerequisite]! < positions[ticket.id]!)
            }
        }
    }

    @Test func lanesStillRejectCyclesAcrossGroups() {
        #expect(throws: TixError.self) {
            try TicketGraph.lanes([Ticket(id: 1), Ticket(id: 2, prerequisites: [3]), Ticket(id: 3, prerequisites: [2])])
        }
    }
}
