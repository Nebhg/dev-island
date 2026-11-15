import Foundation

/// How far back a history panel shows.
///
/// A **view filter, not a retention policy**: picking `24h` hides older rows and
/// deletes nothing. Deleting on toggle would be a trap — choose 24h once and the
/// month is gone, with no undo — and for the terminal panel there is nothing to
/// delete anyway, because that history belongs to zsh, not to this app.
enum HistoryWindow: String, CaseIterable, Identifiable {
    case day
    case week
    case month
    case all

    var id: String { rawValue }

    /// Compact enough that four fit in a panel header row.
    var label: String {
        switch self {
        case .day: "24h"
        case .week: "7d"
        case .month: "30d"
        case .all: "All"
        }
    }

    var title: String {
        switch self {
        case .day: "Last 24 hours"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .all: "Everything"
        }
    }

    /// How much time the window covers, for prose ("Nothing in the last 24 hours").
    var span: String {
        switch self {
        case .day: "24 hours"
        case .week: "7 days"
        case .month: "30 days"
        case .all: "everything"
        }
    }

    /// `nil` means no cutoff.
    func cutoff(from now: Date = Date()) -> Date? {
        switch self {
        case .day: now.addingTimeInterval(-86_400)
        case .week: now.addingTimeInterval(-7 * 86_400)
        case .month: now.addingTimeInterval(-30 * 86_400)
        case .all: nil
        }
    }

    /// An item with no timestamp belongs to no window but "All".
    ///
    /// That is the terminal's situation for every command recorded before
    /// `EXTENDED_HISTORY` was switched on: zsh stored bare command lines, so there
    /// is no time to compare against. Showing them under a 24h filter would be a
    /// guess; hiding them from "All" would lose them.
    func includes(_ date: Date?, now: Date = Date()) -> Bool {
        guard let cutoff = cutoff(from: now) else { return true }
        guard let date else { return false }
        return date >= cutoff
    }
}
