import Foundation

/// One remembered sign-in: which Vista server, and as whom.
struct SavedAccount: Codable, Identifiable, Equatable {
    let id: UUID
    var email: String
    var serverAddress: String
    var lastUsed: Date

    /// Just the host, for the second line of a row: `vista.example.com:8800`
    /// rather than the full URL with its scheme.
    var serverLabel: String {
        let normalized = serverAddress.contains("://") ? serverAddress : "http://\(serverAddress)"
        guard let components = URLComponents(string: normalized), let host = components.host else {
            return serverAddress
        }
        return components.port.map { "\(host):\($0)" } ?? host
    }
}

/// Remembers recent sign-ins so moving between Vista backends doesn't mean
/// retyping a server address, an email, and a password every time.
///
/// The list itself lives in UserDefaults; each account's password goes to the
/// Keychain under its id. Signing out deliberately leaves both in place —
/// switching accounts is the whole point.
@MainActor
final class AccountStore {
    static let shared = AccountStore()

    private let accountsKey = "vista.savedAccounts"
    private let currentKey = "vista.currentAccountID"

    /// Most recently used first.
    private(set) var accounts: [SavedAccount] = []

    private init() { load() }

    var currentAccount: SavedAccount? {
        guard let raw = UserDefaults.standard.string(forKey: currentKey),
              let id = UUID(uuidString: raw) else { return nil }
        return accounts.first { $0.id == id }
    }

    /// The account to offer first on a cold start.
    var mostRecent: SavedAccount? { accounts.first }

    func password(for account: SavedAccount) -> String? {
        Keychain.password(forAccountID: account.id.uuidString)
    }

    /// Record a successful sign-in, or refresh one already remembered.
    ///
    /// Accounts are identified by email *and* server, so the same person on
    /// two backends is two entries — which is exactly what makes switching
    /// between them useful.
    @discardableResult
    func record(email: String, serverAddress: String, password: String) -> SavedAccount {
        let account: SavedAccount
        if let index = accounts.firstIndex(where: {
            $0.email.caseInsensitiveCompare(email) == .orderedSame
                && $0.serverAddress == serverAddress
        }) {
            accounts[index].lastUsed = .now
            account = accounts[index]
        } else {
            account = SavedAccount(id: UUID(), email: email,
                                   serverAddress: serverAddress, lastUsed: .now)
            accounts.append(account)
        }

        Keychain.setPassword(password, forAccountID: account.id.uuidString)
        UserDefaults.standard.set(account.id.uuidString, forKey: currentKey)
        sortAndPersist()
        return account
    }

    func forget(_ account: SavedAccount) {
        Keychain.setPassword(nil, forAccountID: account.id.uuidString)
        accounts.removeAll { $0.id == account.id }
        if currentAccount?.id == account.id {
            UserDefaults.standard.removeObject(forKey: currentKey)
        }
        sortAndPersist()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: accountsKey),
              let decoded = try? JSONDecoder().decode([SavedAccount].self, from: data) else { return }
        accounts = decoded.sorted { $0.lastUsed > $1.lastUsed }
    }

    private func sortAndPersist() {
        accounts.sort { $0.lastUsed > $1.lastUsed }
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
        }
    }
}
