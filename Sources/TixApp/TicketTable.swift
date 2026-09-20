import AppKit
import SwiftUI
import TixCore

struct DisplayRow: Equatable {
    var heading: String?
    var ticket: Ticket?
    var lane: LaneRow?
}

/// NSTableView owns row sizing, selection, and scrolling.
struct TicketTable: NSViewRepresentable {
    var rows: [DisplayRow]
    var laneWidth: Int
    var showsLanes: Bool
    @Binding var selection: Int64?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle =
            .reverseSequentialColumnAutoresizingStyle
        for (name, title) in [
            ("graph", ""), ("id", "ID"), ("title", "Title"),
            ("priority", "Priority"),
        ] {
            let column = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(name)
            )
            column.title = title
            column.resizingMask = name == "title"
                ? [.userResizingMask, .autoresizingMask] : []
            if name == "title" {
                column.minWidth = 200
                column.width = 400
            } else if name == "priority" {
                column.width = 85
            } else if name == "id" {
                column.width = 100
            }
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        context.coordinator.table = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let shouldRevealSelection =
            coordinator.parent.selection != selection
            || coordinator.parent.showsLanes != showsLanes
        let changed =
            coordinator.parent.rows != rows
            || coordinator.parent.showsLanes != showsLanes
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        coordinator.updating = true
        // Reload before unhiding the graph column: unhiding makes AppKit synchronously
        // populate that column's cells using its current (stale) row bookkeeping, which
        // can pass row indexes beyond rows.count when the table just shrank.
        if changed || table.numberOfRows != rows.count { table.reloadData() }
        let graph = table.tableColumns[0]
        graph.isHidden = !showsLanes
        graph.width = CGFloat(max(1, laneWidth) * 20 + 16)
        if let selection,
            let index = rows.firstIndex(where: { $0.ticket?.id == selection })
        {
            if table.selectedRow != index {
                table.selectRowIndexes(
                    IndexSet(integer: index),
                    byExtendingSelection: false
                )
            }
            if shouldRevealSelection { table.scrollRowToVisible(index) }
        } else {
            table.deselectAll(nil)
        }
        coordinator.updating = false
    }
    
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource,
        NSTableViewDelegate
    {
        var parent: TicketTable
        weak var table: NSTableView?
        var updating = false
        
        init(_ parent: TicketTable) { self.parent = parent }
        
        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.rows.count
        }
        
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int)
            -> Bool
        { parent.rows[row].ticket != nil }
        
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table, table.selectedRow >= 0 else { return }
            parent.selection = parent.rows[table.selectedRow].ticket?.id
        }
        
        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            let item = parent.rows[row]
            let key = tableColumn?.identifier.rawValue ?? ""
            if key == "graph" {
                let view = LaneCell()
                view.row = item.lane
                view.setAccessibilityLabel(
                    item.ticket.map {
                        "Dependencies for \($0.displayID): \($0.prerequisites.map { "TIX-\($0)" }.joined(separator: ", "))"
                    } ?? ""
                )
                return view
            }
            let cell = NSTableCellView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            text.font =
                key == "id"
                ? .monospacedSystemFont(ofSize: 11, weight: .regular)
                : .systemFont(ofSize: 12)
            if let heading = item.heading {
                text.stringValue = key == "title" ? heading : ""
                text.font = .systemFont(ofSize: 12, weight: .semibold)
                text.textColor = .secondaryLabelColor
            } else if let ticket = item.ticket {
                switch key {
                case "id":
                    let label = NSMutableAttributedString(
                        string: "● " + ticket.displayID,
                        attributes: [.foregroundColor: NSColor.secondaryLabelColor]
                    )
                    label.addAttribute(
                        .foregroundColor,
                        value: ticket.statusColor,
                        range: NSRange(location: 0, length: 1)
                    )
                    text.attributedStringValue = label
                    cell.toolTip = ticket.statusLabel
                case "title": text.stringValue = ticket.title
                case "priority":
                    let inherited = ticket.effectivePriority != ticket.priority
                    text.stringValue = ticket.effectivePriority.label + (inherited ? " ↑" : "")
                    text.textColor = ticket.effectivePriority == .urgent ? .systemRed
                        : ticket.effectivePriority == .high ? .systemOrange : .secondaryLabelColor
                    cell.toolTip = inherited
                        ? "Assigned: \(ticket.priority.label). Raised by unfinished dependent tickets."
                        : ticket.priority.label
                default: break
                }
                cell.setAccessibilityLabel(
                    "\(ticket.displayID) \(key): \(text.stringValue)" + (key == "id" ? ", \(ticket.statusLabel)" : "")
                )
            }
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(
                    equalTo: cell.leadingAnchor,
                    constant: 8
                ),
                text.trailingAnchor.constraint(
                    equalTo: cell.trailingAnchor,
                    constant: -8
                ), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }
}

final class LaneCell: NSView {
    var row: LaneRow?
    override var isFlipped: Bool { true }
    
    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let middle = bounds.height / 2
        func x(_ lane: Int) -> CGFloat { CGFloat(lane * 20 + 16) }
        // Straight tracks first; crossing branches are drawn with a small bridge gap.
        for segment in row.segments.sorted(by: { !$0.joinsNode && $1.joinsNode }
        ) {
            let path = NSBezierPath()
            if segment.top {
                path.move(to: NSPoint(x: x(segment.from), y: 0))
                path.line(to: NSPoint(x: x(segment.from), y: middle - 5))
                if segment.from != segment.to {
                    let direction: CGFloat = segment.to > segment.from ? 1 : -1
                    path.curve(
                        to: NSPoint(
                            x: x(segment.from) + direction * 5,
                            y: middle
                        ),
                        controlPoint1: NSPoint(x: x(segment.from), y: middle),
                        controlPoint2: NSPoint(
                            x: x(segment.from) + direction * 5,
                            y: middle
                        )
                    )
                }
                path.line(to: NSPoint(x: x(segment.to), y: middle))
            } else {
                path.move(to: NSPoint(x: x(segment.from), y: middle))
                path.line(to: NSPoint(x: x(segment.to), y: bounds.height))
            }
            if segment.from != segment.to {
                NSColor.controlBackgroundColor.setStroke()
                path.lineWidth = 5
                path.stroke()
            }
            NSColor.secondaryLabelColor.withAlphaComponent(0.65).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
        row.ticket.statusColor.setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: x(row.lane) - 4,
                y: middle - 4,
                width: 8,
                height: 8
            )
        ).fill()
    }
}

extension Ticket {
    var statusColor: NSColor {
        status == .done ? .secondaryLabelColor
            : ready ? .systemGreen
            : status == .active ? .systemOrange : .controlAccentColor
    }

    var statusLabel: String {
        status == .done ? "Done"
            : ready ? "Ready"
            : status == .active ? (blockers.isEmpty ? "Active" : "Active · blocked")
            : "Blocked"
    }
}
