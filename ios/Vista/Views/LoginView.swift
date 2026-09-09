import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var password = ""
    @State private var error = ""
    @State private var busy = false
    @State private var accounts: [SavedAccount] = []
    @State private var selectedAccountID: UUID?
    /// Set while `select` writes the form, so its own field changes aren't
    /// mistaken for the user editing them.
    @State private var applyingSelection = false
    @FocusState private var focus: Field?

    private enum Field { case server, email, password }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    TextField("vista.example.com:8800", text: $model.serverAddress)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .server)
                        .onChange(of: model.serverAddress) { _, _ in clearSelectionIfEdited() }
                } header: {
                    Text("Vista server")
                } footer: {
                    // Unlike the web client, an installed app has no build-time
                    // configuration to inherit.
                    Text("The address of your Vista server. http:// is assumed if you leave off a scheme.")
                }

                Section("Account") {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .onChange(of: email) { _, _ in clearSelectionIfEdited() }

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .onSubmit { Task { await signIn() } }
                }

                if !error.isEmpty {
                    Text(error).foregroundStyle(.red).font(.callout)
                }

                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("Sign in").bold() }
                            Spacer()
                        }
                    }
                    .disabled(busy || !canSubmit)
                }

                if !accounts.isEmpty {
                    recentSection
                }
            }
            .navigationTitle("Vista")
        }
        .task { restoreRecent() }
    }

    // MARK: - Recent sign-ins

    private var recentSection: some View {
        Section {
            ForEach(accounts) { account in
                HStack(spacing: 12) {
                    Button {
                        select(account)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedAccountID == account.id
                                  ? "checkmark.circle.fill" : "person.circle")
                                .foregroundStyle(selectedAccountID == account.id
                                                 ? Color.accentColor : Color.secondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.email)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(account.serverLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        forget(account)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Forget \(account.email)")
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Recent")
        } footer: {
            Text("Tap to fill in a previous sign-in, then Sign in. Passwords are stored in the Keychain on this device.")
        }
    }

    // MARK: - Actions

    private var canSubmit: Bool {
        model.serverURL != nil && !email.isEmpty && !password.isEmpty
    }

    /// Offer the last sign-in on a cold start so the common case — signing
    /// back into the server you were just using — is one tap.
    private func restoreRecent() {
        accounts = AccountStore.shared.accounts
        guard email.isEmpty, let recent = AccountStore.shared.currentAccount
                ?? AccountStore.shared.mostRecent else { return }
        select(recent)
    }

    private func select(_ account: SavedAccount) {
        // Email and server are written one after the other. Without this flag
        // the intermediate state — new email, old server — could be read as an
        // edit and drop the selection, depending on how SwiftUI batches the
        // two change callbacks.
        applyingSelection = true
        defer { applyingSelection = false }

        selectedAccountID = account.id
        email = account.email
        model.serverAddress = account.serverAddress
        password = AccountStore.shared.password(for: account) ?? ""
        error = ""
        // A remembered account with no stored password still needs one typed.
        if password.isEmpty { focus = .password }
    }

    /// Editing the server or email means this is no longer the account that
    /// was picked, so drop the checkmark rather than leaving it lying.
    private func clearSelectionIfEdited() {
        guard !applyingSelection,
              let id = selectedAccountID,
              let account = accounts.first(where: { $0.id == id }) else { return }
        if account.email != email || account.serverAddress != model.serverAddress {
            selectedAccountID = nil
        }
    }

    private func forget(_ account: SavedAccount) {
        AccountStore.shared.forget(account)
        accounts = AccountStore.shared.accounts
        if selectedAccountID == account.id { selectedAccountID = nil }
    }

    private func signIn() async {
        guard canSubmit else { return }
        busy = true
        error = ""
        do {
            try await model.signIn(email: email, password: password)
        } catch {
            self.error = error.localizedDescription
            accounts = AccountStore.shared.accounts
        }
        busy = false
    }
}
