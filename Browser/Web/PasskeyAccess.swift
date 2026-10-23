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
        await withCheckedContinuation { continuation in
            ASAuthorizationWebBrowserPublicKeyCredentialManager().requestAuthorizationForPublicKeyCredentials { _ in
                continuation.resume()
            }
        }
        return status
    }
}
