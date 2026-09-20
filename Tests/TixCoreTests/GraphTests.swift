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
        // Every root feeds every leaf, so row ordering cannot remove the crossings.
        let layout = try TicketGraph.lanes([Ticket(id: 1), Ticket(id: 2), Ticket(id: 3), Ticket(id: 4, prerequisites: [1, 2, 3]), Ticket(id: 5, prerequisites: [1, 2, 3]), Ticket(id: 6, prerequisites: [1, 2, 3])])
        let row = layout.rows[3]
        #expect(row.segments.contains { $0.top && $0.joinsNode && $0.from == 0 && $0.to == 3 })
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

    @Test func shortLeavesFinishBeforeOpeningLongBranches() throws {
        let tickets = [
            Ticket(id: 1), Ticket(id: 2, prerequisites: [1]), Ticket(id: 3, prerequisites: [2]),
            Ticket(id: 4, prerequisites: [1]), Ticket(id: 5, prerequisites: [1]), Ticket(id: 6),
            Ticket(id: 7, prerequisites: [6]), Ticket(id: 8, prerequisites: [3, 7]),
            Ticket(id: 9, prerequisites: [3]), Ticket(id: 10, prerequisites: [9])
        ]
        let layout = try TicketGraph.lanes(tickets)
        // The old ID ordering used three tracks and left the two short leaves
        // hanging while the long branch was processed.
        #expect(layout.width == 2)
        #expect(layout.rows.prefix(4).map(\.id) == [1, 4, 5, 2])
        checkConnections(tickets, layout)
    }

    @Test func longLivedBranchTracksAreReduced() throws {
        // Shape from a real 22-ticket group with late-numbered prerequisites,
        // several roots, leaf branches, and joins. ID ordering used 6 lanes and
        // 68 occupied track-row boundaries.
        let prerequisites: [Int64: [Int64]] = [
            14: [38], 15: [37], 16: [15, 38], 17: [], 18: [17], 19: [17],
            20: [18], 21: [19], 22: [21], 23: [15, 19], 24: [], 25: [24],
            26: [24], 29: [23], 30: [25, 29], 31: [23], 32: [23],
            35: [], 36: [35], 37: [36], 38: [37], 39: [18]
        ]
        let tickets = prerequisites.map { Ticket(id: $0.key, prerequisites: $0.value) }.sorted { $0.id < $1.id }
        let layout = try TicketGraph.lanes(tickets)
        #expect(layout.width == 3)
        let occupied = layout.rows.reduce(0) { $0 + Set($1.segments.filter(\.top).map(\.from)).count }
        #expect(occupied == 41)
        #expect(try layout == TicketGraph.lanes(tickets.reversed()))
        checkConnections(tickets, layout)
    }

    @Test func transitivePriorityAndAgeOrdering() throws {
        let tickets = [
            Ticket(id: 1, priority: .low),
            Ticket(id: 2, prerequisites: [1]),
            Ticket(id: 3, priority: .urgent, prerequisites: [2]),
            Ticket(id: 4, priority: .high),
            Ticket(id: 5, createdAt: 20), Ticket(id: 6, createdAt: 10)
        ]
        let prioritized = try TicketGraph.prioritized(tickets)
        #expect(prioritized.map(\.id) == [1, 2, 3, 4, 6, 5])
        #expect(prioritized.prefix(3).allSatisfy { $0.effectivePriority == .urgent })
        #expect(prioritized[0].priority == .low)
        #expect(try TicketGraph.waves(tickets)[0].tickets.map(\.id) == [1, 4, 6, 5])
        #expect(try TicketGraph.lanes(tickets).rows.prefix(3).map(\.id) == [1, 2, 3])
    }

    @Test func completedTicketsCutPriorityInheritance() throws {
        let tickets = [
            Ticket(id: 1, priority: .low),
            Ticket(id: 2, status: .done, priority: .high, prerequisites: [1]),
            Ticket(id: 3, priority: .urgent, prerequisites: [2])
        ]
        let result = try TicketGraph.prioritized(tickets)
        #expect(result.first { $0.id == 1 }?.effectivePriority == .low)
        #expect(result.first { $0.id == 2 }?.effectivePriority == .high)
    }

    @Test func branchesUseMaximumRatherThanSum() throws {
        let tickets = [Ticket(id: 1, priority: .low), Ticket(id: 2, priority: .high)]
            + (3...20).map { Ticket(id: Int64($0), priority: .low, prerequisites: [1]) }
        #expect(try TicketGraph.prioritized(tickets).first?.id == 2)
        #expect(try TicketGraph.lanes(tickets).rows.first?.id == 2)
    }

    private func checkConnections(_ tickets: [Ticket], _ layout: LaneLayout) {
        #expect(Set(layout.rows.map(\.id)) == Set(tickets.map(\.id)))
        var tracks: [Int: Int64] = [:]
        for row in layout.rows {
            let top = row.segments.filter(\.top)
            #expect(Set(top.map(\.from)) == Set(tracks.keys))
            let incoming = top.filter(\.joinsNode)
            #expect(Set(incoming.compactMap { tracks[$0.from] }) == Set(row.ticket.prerequisites))
            #expect(incoming.allSatisfy { $0.to == row.lane })
            var next: [Int: Int64] = [:]
            for segment in row.segments where !segment.top {
                next[segment.to] = segment.joinsNode ? row.id : tracks[segment.from]
            }
            tracks = next
        }
        #expect(tracks.isEmpty)
    }
}
