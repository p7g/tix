import Foundation

extension Ticket {
    /// Every whitespace-separated term must occur in the ID, title, or description.
    /// Literal substring matching supports partial words without query syntax.
    public func matches(_ query: String) -> Bool {
        let fields = [displayID, title, body]
        return query.split(whereSeparator: { $0.isWhitespace }).allSatisfy { term in
            fields.contains {
                $0.range(of: String(term), options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}
