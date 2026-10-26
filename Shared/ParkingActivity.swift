import ActivityKit
import Foundation

/// Paid parking running down, on the Lock Screen and in the Dynamic Island.
/// Shared by the app (which starts, extends and ends it) and the widget
/// extension (which draws it).
nonisolated struct ParkingActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        /// When the paid time runs out.
        var endsAt: Date
        /// Whether another text can still extend it (a zone's daily limit).
        var canExtend: Bool
    }

    /// "Zona 0"
    var zone: String
    /// "Osijek"
    var city: String
    /// "OS123AB"
    var plate: String
}
