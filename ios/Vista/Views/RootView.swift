import SwiftUI

/// Top-level navigation.
///
/// `NavigationSplitView` gives the sidebar-and-detail layout that suits an
/// iPad and collapses to a push-navigation stack on iPhone, so one structure
/// serves both without branching on size class.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system

    var body: some View {
        @Bindable var model = model

        Group {
            switch model.phase {
            case .loading:
                ProgressView()
            case .signedOut:
                LoginView()
            case let .signedIn(user):
                SignedInView(user: user)
            }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        // nil for .system, which leaves the device in charge.
        .preferredColorScheme(appearance.colorScheme)
    }
}

private struct SignedInView: View {
    let user: User
    @Environment(AppModel.self) private var model

    enum Destination: Hashable {
        case briefing(Briefing)
        case notes
        case settings
    }

    @State private var selection: Destination?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if !user.briefings.isEmpty {
                    Section("Briefs") {
                        ForEach(user.briefings) { briefing in
                            NavigationLink(value: Destination.briefing(briefing)) {
                                Label(briefing.name, systemImage: "doc.richtext")
                            }
                        }
                    }
                }

                Section {
                    NavigationLink(value: Destination.notes) {
                        Label("Notes", systemImage: "note.text")
                    }
                    NavigationLink(value: Destination.settings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("Vista")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Text(user.email)
                        Button("Sign out", role: .destructive) { model.signOut() }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
        } detail: {
            NavigationStack {
                switch selection {
                case let .briefing(briefing):
                    BriefsView(briefing: briefing)
                case .notes:
                    NotesView()
                case .settings:
                    SettingsView()
                case nil:
                    placeholder
                }
            }
        }
        .onAppear {
            // A brand-new account has nothing configured; Settings is the only
            // useful place to land.
            if selection == nil {
                selection = user.configured
                    ? user.briefings.first.map(Destination.briefing) ?? .notes
                    : .settings
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if !user.configured {
            ContentUnavailableView {
                Label("Not connected", systemImage: "link.badge.plus")
            } description: {
                Text("Add your Ark server URL, agent, and token in Settings.")
            } actions: {
                Button("Open Settings") { selection = .settings }
            }
        } else {
            ContentUnavailableView("Nothing selected", systemImage: "sidebar.left",
                                   description: Text("Pick a briefing or your notes."))
        }
    }
}
