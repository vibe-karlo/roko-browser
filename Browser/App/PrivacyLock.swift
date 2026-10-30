import LocalAuthentication
import UIKit

/// Settings → Privacy → Lock Private Tabs and History: private tabs and the
/// pages you've visited show only after Face ID (or the passcode). Unlocked
/// once, they stay open until roko leaves the screen.
@MainActor
@Observable
final class PrivacyLock {
    static let shared = PrivacyLock()
    static let key = "lock.private"

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.key)
            if !isEnabled { isUnlocked = false }
        }
    }
    private(set) var isUnlocked = false
    /// Face ID asked and not answered yet.
    private(set) var isAsking = false

    /// Whether what it guards is hidden right now.
    var isLocked: Bool { isEnabled && !isUnlocked }

    /// Private tabs opened since it last locked: yours already, so they show.
    private var openedSinceLock = Set<UUID>()

    func opened(_ tab: UUID) {
        if isLocked { openedSinceLock.insert(tab) }
    }

    /// Whether this private tab is hidden right now.
    func hides(_ tab: UUID) -> Bool {
        isLocked && !openedSinceLock.contains(tab)
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.key)
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                PrivacyLock.shared.isUnlocked = false
                PrivacyLock.shared.openedSinceLock = []
            }
        }
    }

    /// What this iPhone unlocks with, for Settings: "Face ID", "Touch ID", "Passcode".
    static var method: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    /// Whether this iPhone can lock at all (it has a passcode).
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Asks for Face ID, falling back to the passcode. True once unlocked.
    @discardableResult
    func unlock(_ reason: String = "Show your private tabs and history") async -> Bool {
        guard isLocked else { return true }
        guard !isAsking else { return false }
        isAsking = true
        defer { isAsking = false }
        let context = LAContext()
        context.localizedCancelTitle = "Not Now"
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        if ok { isUnlocked = true }
        return ok
    }

    /// Turning it on asks once, so it can't be switched on by someone who
    /// can't unlock the iPhone, and Face ID's permission is asked for now.
    func turnOn() async -> Bool {
        let context = LAContext()
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                 localizedReason: "Lock your private tabs and history")) == true else { return false }
        isEnabled = true
        isUnlocked = true
        return true
    }
}
