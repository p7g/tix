import Foundation

public enum TicketStatus: String, Codable, CaseIterable, Sendable { case open, active, done }

public struct Ticket: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64
    public var title: String
    public var body: String
    public var status: TicketStatus
    public var owner: String?
    public var createdAt: Double
    public var updatedAt: Double
    public var revision: Int64
    public var prerequisites: [Int64]
    public var dependents: [Int64]
    public var blockers: [Int64]
    public var displayID: String { "TIX-\(id)" }
    public var ready: Bool { status == .open && blockers.isEmpty }

    public init(id: Int64, title: String = "", body: String = "", status: TicketStatus = .open, owner: String? = nil, createdAt: Double = 0, updatedAt: Double = 0, revision: Int64 = 1, prerequisites: [Int64] = [], dependents: [Int64] = [], blockers: [Int64] = []) {
        self.id = id; self.title = title; self.body = body; self.status = status; self.owner = owner
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.revision = revision
        self.prerequisites = prerequisites; self.dependents = dependents; self.blockers = blockers
    }
}

public struct Wave: Identifiable, Equatable, Sendable {
    public var id: Int
    public var tickets: [Ticket]
}
public struct LaneSegment: Equatable, Sendable {
    public var from: Int
    public var to: Int
    /// Top half: boundary -> node level. Bottom half: node level -> boundary.
    public var top: Bool
    public var joinsNode: Bool
}
public struct LaneRow: Identifiable, Equatable, Sendable {
    public var ticket: Ticket
    public var lane: Int
    public var segments: [LaneSegment]
    public var id: Int64 { ticket.id }
}
public struct LaneLayout: Equatable, Sendable {
    public var rows: [LaneRow]
    public var width: Int
    public init(rows: [LaneRow], width: Int) { self.rows = rows; self.width = width }
}

public enum TicketGraph {
    public static func ordered(_ tickets: [Ticket]) throws -> [Ticket] {
        let ids = Set(tickets.map(\.id))
        var remaining = tickets.sorted { $0.id < $1.id }
        var emitted = Set<Int64>(); var result: [Ticket] = []
        while !remaining.isEmpty {
            guard let index = remaining.firstIndex(where: { Set($0.prerequisites).intersection(ids).isSubset(of: emitted) }) else {
                throw TixError.invalid("Dependencies contain a cycle.")
            }
            let ticket = remaining.remove(at: index)
            emitted.insert(ticket.id); result.append(ticket)
        }
        return result
    }

    public static func waves(_ tickets: [Ticket]) throws -> [Wave] {
        let unfinished = tickets.filter { $0.status != .done }
        var depths: [Int64: Int] = [:]
        for ticket in try ordered(unfinished) {
            depths[ticket.id] = 1 + (ticket.prerequisites.compactMap { depths[$0] }.max() ?? 0)
        }
        return Set(depths.values).sorted().map { depth in
            Wave(id: depth, tickets: unfinished.filter { depths[$0.id] == depth }.sorted { $0.id < $1.id })
        }
    }

    public static func lanes(_ tickets: [Ticket]) throws -> LaneLayout {
        let layouts = try connectedGroups(tickets).map { group in
            let baseline = makeLanes(try ordered(group))
            // Favoring narrower branches helps some joins but can leave a root
            // waiting on others. Try both tie-breaks, retaining the ID baseline
            // whenever it uses fewer lanes, shorter tracks, or less travel.
            return try [false, true].reduce(baseline) { best, preferFewerBranches in
                let compact = makeLanes(try compactOrder(group, preferFewerBranches: preferFewerBranches))
                return layoutCost(compact) < layoutCost(best) ? compact : best
            }
        }
        return LaneLayout(rows: layouts.flatMap(\.rows), width: layouts.map(\.width).max() ?? 1)
    }

    private static func layoutCost(_ layout: LaneLayout) -> (Int, Int, Int) {
        let vertical = layout.rows.reduce(0) { $0 + Set($1.segments.filter(\.top).map(\.from)).count }
        let horizontal = layout.rows.reduce(0) { $0 + $1.segments.reduce(0) { $0 + abs($1.to - $1.from) } }
        return (layout.width, vertical, horizontal)
    }

    /// Among eligible tickets, prefer closing open tracks and continuing nearby
    /// branches. Optionally favor less branching tickets before the final ID tie-break.
    private static func compactOrder(_ tickets: [Ticket], preferFewerBranches: Bool) throws -> [Ticket] {
        let ids = Set(tickets.map(\.id))
        let parents = Dictionary(uniqueKeysWithValues: tickets.map { ($0.id, Set($0.prerequisites).intersection(ids)) })
        var children: [Int64: Set<Int64>] = [:]
        for ticket in tickets {
            for parent in parents[ticket.id]! { children[parent, default: []].insert(ticket.id) }
        }
        var outstanding = children.mapValues(\.count)
        var positions: [Int64: Int] = [:]
        var remaining = tickets
        var result: [Ticket] = []
        while !remaining.isEmpty {
            func score(_ ticket: Ticket) -> (Int, Int, Int, Int, Int64) {
                let prerequisites = parents[ticket.id]!
                let closing = prerequisites.filter { outstanding[$0] == 1 }.count
                let branching = children[ticket.id]?.count ?? 0
                let nearest = prerequisites.compactMap { positions[$0] }.max() ?? -1
                return ((branching > 0 ? 1 : 0) - closing, -closing, -nearest, preferFewerBranches ? branching : 0, ticket.id)
            }
            let ready = remaining.indices.filter { index in parents[remaining[index].id]!.allSatisfy { positions[$0] != nil } }
            guard let index = ready.min(by: { score(remaining[$0]) < score(remaining[$1]) }) else {
                throw TixError.invalid("Dependencies contain a cycle.")
            }
            let ticket = remaining.remove(at: index)
            positions[ticket.id] = result.count
            result.append(ticket)
            for parent in parents[ticket.id]! { outstanding[parent]! -= 1 }
        }
        return result
    }

    private static func makeLanes(_ ordered: [Ticket]) -> LaneLayout {
        // Tracks carry a prerequisite until its last dependent has been emitted.
        var tracks: [Int64?] = []
        var remaining: [Int64: Set<Int64>] = [:]
        for ticket in ordered {
            for prerequisite in ticket.prerequisites { remaining[prerequisite, default: []].insert(ticket.id) }
        }
        var rows: [LaneRow] = []; var width = 1
        for ticket in ordered {
            let incoming = tracks.indices.filter { tracks[$0].map(ticket.prerequisites.contains) ?? false }
            let before = tracks
            for index in incoming {
                let prerequisite = tracks[index]!
                remaining[prerequisite]?.remove(ticket.id)
                if remaining[prerequisite]?.isEmpty == true { tracks[index] = nil }
            }
            let lane = incoming.first(where: { tracks[$0] == nil }) ?? tracks.firstIndex(where: { $0 == nil }) ?? tracks.count
            if lane == tracks.count { tracks.append(nil) }
            var segments: [LaneSegment] = []
            for index in before.indices where before[index] != nil {
                segments.append(LaneSegment(from: index, to: incoming.contains(index) ? lane : index, top: true, joinsNode: incoming.contains(index)))
                if tracks.indices.contains(index), tracks[index] != nil {
                    if incoming.contains(index) && index != lane {
                        segments.append(LaneSegment(from: index, to: index, top: true, joinsNode: false))
                    }
                    segments.append(LaneSegment(from: index, to: index, top: false, joinsNode: false))
                }
            }
            if !(remaining[ticket.id] ?? []).isEmpty {
                tracks[lane] = ticket.id
                segments.append(LaneSegment(from: lane, to: lane, top: false, joinsNode: true))
            }
            width = max(width, tracks.count)
            rows.append(LaneRow(ticket: ticket, lane: lane, segments: segments))
        }
        return LaneLayout(rows: rows, width: width)
    }

    /// Keep independent graphs contiguous. Both edge directions matter: two roots
    /// that eventually join belong to the same group. IDs stabilize group order.
    private static func connectedGroups(_ tickets: [Ticket]) -> [[Ticket]] {
        let byID = Dictionary(uniqueKeysWithValues: tickets.map { ($0.id, $0) })
        var neighbors: [Int64: Set<Int64>] = [:]
        for ticket in tickets {
            for prerequisite in ticket.prerequisites where byID[prerequisite] != nil {
                neighbors[ticket.id, default: []].insert(prerequisite)
                neighbors[prerequisite, default: []].insert(ticket.id)
            }
        }
        var visited = Set<Int64>()
        var groups: [[Ticket]] = []
        for id in byID.keys.sorted() where visited.insert(id).inserted {
            var pending = [id]
            var group: [Ticket] = []
            while let next = pending.popLast() {
                group.append(byID[next]!)
                for neighbor in neighbors[next] ?? [] where visited.insert(neighbor).inserted {
                    pending.append(neighbor)
                }
            }
            groups.append(group)
        }
        return groups
    }
}

public enum TixError: Error, LocalizedError, Sendable {
    case invalid(String)
    case conflict(Ticket)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .conflict(let ticket): "\(ticket.displayID) changed or cannot be claimed (status: \(ticket.status.rawValue), owner: \(ticket.owner ?? "none")). Reload its current state."
        }
    }
}
