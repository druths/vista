import Foundation
import SwiftUI

/// App-wide state: which Vista server, who is signed in, and the last error
/// worth showing.
@MainActor
@Observable
final class AppModel {
    enum Phase {
        case loading
        case signedOut
        case signedIn(User)
    }

    private(set) var phase: Phase = .loading
    var errorMessage: String?

    let client = VistaClient()

    /// The Vista server address. A web build can bake this in at compile time;
    /// an installed app has to be told, so it is asked for at sign-in and kept
    /// for next launch.
    var serverAddress: String {
        didSet { UserDefaults.standard.set(serverAddress, forKey: Self.serverKey) }
    }

    private static let serverKey = "vista.server"
    private static let tokenAccount = "session"

    var user: User? {
        if case let .signedIn(user) = phase { return user }
        return nil
    }

    init() {
        serverAddress = UserDefaults.standard.string(forKey: Self.serverKey) ?? ""
    }

    var serverURL: URL? {
        let trimmed = serverAddress.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Accept "10.0.0.5:8800" as well as a full URL — typing a scheme on a
        // phone keyboard is a nuisance.
        let normalized = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        return URL(string: normalized)
    }

    /// Restore a stored session, if there is one, on launch.
    func restore() async {
        guard let url = serverURL, let token = Keychain.get(Self.tokenAccount) else {
            phase = .signedOut
            return
        }
        await client.configure(baseURL: url, token: token)
        do {
            phase = .signedIn(try await client.me())
        } catch {
            // An expired or rejected session just means "sign in again"; it is
            // not worth an error banner on a cold launch.
            Keychain.set(nil, for: Self.tokenAccount)
            await client.setToken(nil)
            phase = .signedOut
        }
    }

    func signIn(email: String, password: String) async throws {
        guard let url = serverURL else { throw VistaError.notConfigured }
        let (token, _) = try await client.login(baseURL: url, email: email, password: password)
        Keychain.set(token, for: Self.tokenAccount)
        // Remember the sign-in only once it has actually worked, so a typo
        // never lands in the history.
        AccountStore.shared.record(email: email,
                                   serverAddress: serverAddress.trimmingCharacters(in: .whitespaces),
                                   password: password)
        phase = .signedIn(try await client.me())
    }

    /// Ends the session but keeps the saved-account list: signing out is how
    /// you get back to the picker to switch backends. Cached briefs go,
    /// because the next server's briefs are not these.
    func signOut() {
        Keychain.set(nil, for: Self.tokenAccount)
        Task { await client.setToken(nil) }
        BriefCache.clear()
        phase = .signedOut
    }

    /// Reload the user after settings change the nav or the Ark connection.
    func refreshUser() async {
        guard case .signedIn = phase else { return }
        do {
            phase = .signedIn(try await client.me())
        } catch {
            report(error)
        }
    }

    func report(_ error: Error) {
        if case VistaError.unauthorized = error {
            signOut()
            errorMessage = "Your session has expired. Sign in again."
            return
        }
        errorMessage = error.localizedDescription
    }
}
