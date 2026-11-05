import Observation
import TixCore

/// Tickets matching a search query, along with that query.
struct SearchResults: Equatable {
    var query: String
    var tickets: [Ticket]
}

/// Stores the search field's text and the tickets that match it. Indexes and matches off
/// the main actor, so typing never waits for a search.
@Observable @MainActor final class SearchModel {
    /// Stores the search field's text. Each change cancels the running search and
    /// starts a new one.
    var text = "" {
        didSet { if text != oldValue { start() } }
    }
    /// Stores the results of the latest finished search, or nil when the query is blank.
    /// Lags `text` until the search for it finishes.
    private(set) var results: SearchResults? {
        didSet {
            // Assign only on change, because the toolbar observes `isActive` and
            // every assignment would invalidate it.
            if isActive != (results != nil) { isActive = results != nil }
        }
    }
    /// Stores whether `results` is non-nil, changing only when a search starts or ends.
    private(set) var isActive = false

    // Keep the index as a task, so rebuilding it after a refresh never blocks the main
    // actor; a search awaits whichever index was current when it started.
    @ObservationIgnored private var index = Task { TicketSearchIndex([]) }
    @ObservationIgnored private var search: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// Rebuilds the index from `tickets` and reruns the current query against it.
    func update(_ tickets: [Ticket]) {
        index = Task.detached(priority: .userInitiated) { TicketSearchIndex(tickets) }
        start()
    }

    /// Clears the text and results immediately.
    func clear() {
        text = ""
        results = nil
    }

    private func start() {
        search?.cancel()
        generation += 1
        let query = text
        guard query.contains(where: { !$0.isWhitespace }) else {
            results = nil
            return
        }
        let current = generation
        let index = index
        search = Task {
            guard let tickets = try? await Self.match(query, in: index) else { return }
            // Drop results that arrive after a newer search started, because tasks can
            // finish out of order.
            guard current == generation else { return }
            results = SearchResults(query: query, tickets: tickets)
        }
    }

    @concurrent
    private nonisolated static func match(
        _ query: String,
        in index: Task<TicketSearchIndex, Never>
    ) async throws -> [Ticket] {
        try await index.value.tickets(matching: query)
    }
}
