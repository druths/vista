import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var password = ""
    @State private var error = ""
    @State private var busy = false
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
            }
            .navigationTitle("Vista")
        }
    }

    private var canSubmit: Bool {
        model.serverURL != nil && !email.isEmpty && !password.isEmpty
    }

    private func signIn() async {
        guard canSubmit else { return }
        busy = true
        error = ""
        do {
            try await model.signIn(email: email, password: password)
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}
