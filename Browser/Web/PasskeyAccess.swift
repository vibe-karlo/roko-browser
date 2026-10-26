import AuthenticationServices

/// WebKit answers a site's passkey request on its own, but only once Apple has
/// granted the browser entitlements and the person has allowed this app to use
/// their passkeys. This covers the second half: checking and asking.
enum PasskeyAccess {
    enum Status {
        case allowed, denied, notAsked
    }

    static var status: Status {
        switch ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials {
        case .authorized: .allowed
        case .denied: .denied
        default: .notAsked
        }
    }

    static func request() async -> Status {
        await ask()
        return status
    }

    /// Off the main actor: iOS answers on a queue of its own, and a reply
    /// handler made on the main actor stops the app when it's called there.
    nonisolated private static func ask() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ASAuthorizationWebBrowserPublicKeyCredentialManager().requestAuthorizationForPublicKeyCredentials { @Sendable _ in
                continuation.resume()
            }
        }
    }
}
