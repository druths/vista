import SwiftUI

/// Top-level navigation.
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

/// Tabs, each owning its own navigation stack.
///
/// This was a `NavigationSplitView` whose detail column held one long-lived
/// `NavigationStack` with its root swapped by a `switch` on the selection.
/// That combination misbehaved once anything had been pushed and popped: a
/// later selection change never rebuilt the detail, so the destination's view
/// never appeared, never ran its `.task`, and never loaded — the screen sat
/// empty with no request made at all.
///
/// Tabs remove the whole class of problem. Each tab is a separate stack that
/// owns its own state, nothing swaps a stack's root, and there is no collapsed
/// / expanded split-view behaviour to reason about. Briefings become a list
/// inside the Briefs tab rather than sidebar entries.
private struct SignedInView: View {
    let user: User
    @Environment(AppModel.self) private var model

    private enum Tabs: Hashable { case briefs, notes, settings }

    @State private var tab: Tabs = .briefs

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                BriefingsListView(user: user)
            }
            .tabItem { Label("Briefs", systemImage: "doc.richtext") }
            .tag(Tabs.briefs)

            NavigationStack {
                NotesView()
            }
            .tabItem { Label("Notes", systemImage: "note.text") }
            .tag(Tabs.notes)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(Tabs.settings)
        }
        .onAppear {
            // A brand-new account has nothing configured; Settings is the only
            // useful place to land.
            if !user.configured { tab = .settings }
        }
    }
}

/// The Briefs tab: pick a briefing, then read its briefs.
private struct BriefingsListView: View {
    let user: User
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if user.briefings.isEmpty {
                // Rendered inline rather than as an overlay so the list's own
                // empty state doesn't fight it.
                ContentUnavailableView {
                    Label("No brief locations", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(user.configured
                         ? "Add one in Settings to start reading briefs."
                         : "Connect an Ark server in Settings first.")
                }
                .listRowSeparator(.hidden)
            } else {
                ForEach(user.briefings) { briefing in
                    NavigationLink(value: briefing) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(briefing.name)
                            Text(briefing.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Briefs")
        .navigationDestination(for: Briefing.self) { briefing in
            BriefsView(briefing: briefing)
        }
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
    }
}
