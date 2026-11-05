import Foundation

extension Ticket {
    /// Returns whether every whitespace-separated term occurs in the ID, title, or
    /// description, ignoring case and diacritics. Literal substring matching supports
    /// partial words without query syntax. Folds the ticket's text on every call; use
    /// `TicketSearchIndex` to match many queries against the same tickets.
    public func matches(_ query: String) -> Bool {
        TicketSearchIndex.Entry(self).contains(all: TicketSearchIndex.terms(query))
    }
}

/// An immutable, folded copy of each ticket's searchable text. Building the index costs
/// O(total text length); each query then costs one byte search per term and ticket.
public struct TicketSearchIndex: Sendable {
    struct Entry: Sendable {
        var ticket: Ticket
        /// UTF-8 of the folded ID, title, and description, separated by newlines.
        var text: [UInt8]

        init(_ ticket: Ticket) {
            self.ticket = ticket
            // Fold once here, so queries can compare raw bytes. Calling
            // `range(of:options: [.caseInsensitive, .diacriticInsensitive])` per
            // query instead folds every description again on every keystroke.
            // Because terms never contain whitespace, the newline separators keep a
            // term from matching across two fields.
            text = Array(
                TicketSearchIndex.fold("\(ticket.displayID)\n\(ticket.title)\n\(ticket.body)").utf8
            )
        }

        func contains(all terms: [[UInt8]]) -> Bool {
            text.withUnsafeBytes { haystack in
                terms.allSatisfy { term in
                    term.withUnsafeBytes { needle in
                        memmem(haystack.baseAddress, haystack.count, needle.baseAddress, needle.count) != nil
                    }
                }
            }
        }
    }

    private let entries: [Entry]

    /// Returns an index over `tickets`, preserving their order.
    public init(_ tickets: [Ticket]) {
        entries = tickets.map(Entry.init)
    }

    /// Returns the indexed tickets that match `query`, in index order, with the same
    /// semantics as `Ticket.matches(_:)`. Throws `CancellationError` if the current task
    /// is cancelled before the search finishes.
    public func tickets(matching query: String) throws -> [Ticket] {
        let terms = Self.terms(query)
        var result: [Ticket] = []
        for (offset, entry) in entries.enumerated() {
            if offset % 64 == 0 { try Task.checkCancellation() }
            if entry.contains(all: terms) { result.append(entry.ticket) }
        }
        return result
    }

    static func terms(_ query: String) -> [[UInt8]] {
        query.split(whereSeparator: \.isWhitespace).map { Array(fold(String($0)).utf8) }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
