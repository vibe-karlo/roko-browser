import AlarmKit

/// A timer from Cook Mode, for its countdown on the Lock Screen and in the
/// Dynamic Island. Shared by the app (which starts it) and the widget extension
/// (which draws it).
nonisolated struct CookTimerMetadata: AlarmMetadata {
    /// "Easy pancakes"
    var recipe: String
    /// The step it was started from, counting from 1.
    var step: Int
}
