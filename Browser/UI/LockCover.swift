import SwiftUI

/// Over a private tab while it's locked (Settings → Lock private tabs and
/// history), and over it in the app switcher. Asks for Face ID as it shows.
struct LockCover: View {
    @Environment(\.scenePhase) private var scenePhase
    private var lock: PrivacyLock { .shared }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Glyph(.lock, size: 44)
                .foregroundStyle(Theme.ink)
                .padding(.bottom, 26)
            Text("Private tab locked")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text("Only you can open it.")
                .font(.system(size: 16))
                .foregroundStyle(Theme.secondaryInk)
                .padding(.top, 6)
            Button("Unlock with \(PrivacyLock.method)") { ask() }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accentText)
                .frame(minHeight: 44)
                .contentShape(.rect)
                .padding(.top, 18)
                .opacity(lock.isLocked ? 1 : 0)
            Spacer()
            Spacer().frame(height: Theme.barHeight + 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .background(Theme.canvas)
        .task(id: scenePhase) {
            // Face ID won't show while roko is still coming to the front.
            guard scenePhase == .active else { return }
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { ask() }
        }
    }

    private func ask() {
        guard lock.isLocked, !lock.isAsking else { return }
        Task { await lock.unlock("Show your private tab") }
    }
}
