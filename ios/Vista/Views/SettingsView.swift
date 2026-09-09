import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system
    /// While following the system this is the system's own setting, so it can
    /// be named. Under an explicit override it just echoes that override,
    /// which is why it is only shown for `.system`.
    @Environment(\.colorScheme) private var resolvedScheme

    @State private var settings: Settings?
    @State private var arkURL = ""
    @State private var agent = ""
    @State private var token = ""
    @State private var notesDir = ""
    @State private var result: ConnectionResult?
    @State private var busy = false
    @State private var picking: Picking?
    @State private var pendingName: String?
    @State private var pendingPath = ""

    private enum Picking: Identifiable {
        case notes
        case newBriefing
        case briefing(Briefing)

        var id: String {
            switch self {
            case .notes: return "notes"
            case .newBriefing: return "new"
            case let .briefing(b): return "briefing-\(b.id)"
            }
        }
    }

    var body: some View {
        Form {
            appearanceSection
            arkSection
            notesSection
            briefingsSection
            accountSection
        }
        .navigationTitle("Settings")
        .task { await load() }
        .sheet(item: $picking) { target in
            FolderPickerView(startPath: startPath(for: target)) { path in
                Task { await apply(path, to: target) }
            }
            .environment(model)
        }
        .alert("Name this briefing",
               isPresented: Binding(get: { pendingName != nil },
                                    set: { if !$0 { pendingName = nil } })) {
            TextField("Name", text: Binding(get: { pendingName ?? "" },
                                            set: { pendingName = $0 }))
            Button("Cancel", role: .cancel) { pendingName = nil }
            Button("Add") { Task { await addBriefing() } }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Appearance")
        } footer: {
            Text(appearance == .system
                 ? "Following this device, currently \(resolvedScheme == .dark ? "Dark" : "Light"). It will switch automatically when the device does."
                 : "Vista stays \(appearance.label.lowercased()) whatever the device is set to.")
        }
    }

    // MARK: - Ark

    private var arkSection: some View {
        Section {
            LabeledContent("Server") {
                TextField("http://ark:7777", text: $arkURL)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            LabeledContent("Agent") {
                TextField("scribe", text: $agent)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            LabeledContent("Token") {
                SecureField(settings?.ark.tokenSet == true ? "Stored — type to replace" : "Ark auth_secret",
                            text: $token)
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                Button("Test") { Task { await runArk(save: false) } }
                    .disabled(busy || arkURL.isEmpty || agent.isEmpty)
                Spacer()
                Button("Save") { Task { await runArk(save: true) } }
                    .bold()
                    .disabled(busy || arkURL.isEmpty || agent.isEmpty)
            }

            if let result {
                Label(result.detail, systemImage: result.connected ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(result.connected ? .green : .red)
                    .font(.callout)
            }
        } header: {
            Text("Ark server")
        } footer: {
            Text("The token grants full access to the agent's workspace. It is stored encrypted on the Vista server and is never sent back to this device.")
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        Section {
            HStack {
                TextField("notes", text: $notesDir)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Browse") { picking = .notes }
                    .buttonStyle(.borderless)
            }
            Button("Save notes folder") { Task { await saveNotes() } }
                .disabled(busy || notesDir.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Notes folder")
        } footer: {
            Text("Where notes are read and written, relative to the workspace root. Changing it points Vista at a different set of notes; no files are moved.")
        }
    }

    // MARK: - Briefings

    private var briefingsSection: some View {
        Section {
            ForEach(settings?.briefings ?? []) { briefing in
                VStack(alignment: .leading, spacing: 2) {
                    Text(briefing.name)
                    Text(briefing.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { picking = .briefing(briefing) }
            }
            .onDelete { offsets in Task { await removeBriefings(offsets) } }
            .onMove { source, destination in Task { await move(source, to: destination) } }

            Button("Add brief location", systemImage: "plus") { picking = .newBriefing }
        } header: {
            Text("Brief locations")
        } footer: {
            Text("Each becomes its own screen. Tap one to re-point it, swipe to remove. Removing only unconfigures it — no files are deleted.")
        }
    }

    private var accountSection: some View {
        Section {
            Button("Clear cached briefs") { BriefCache.clear() }
            Button("Sign out", role: .destructive) { model.signOut() }
        } footer: {
            Text(model.user.map { "Signed in as \($0.email) · \(model.serverAddress)" } ?? "")
        }
    }

    // MARK: - Actions

    private func load() async {
        do {
            let loaded = try await model.client.settings()
            settings = loaded
            arkURL = loaded.ark.baseURL
            agent = loaded.ark.agent
            notesDir = loaded.notesDir
        } catch {
            model.report(error)
        }
    }

    private func runArk(save: Bool) async {
        busy = true
        defer { busy = false }
        // An empty field means "keep the stored token" — the server never
        // sends it back, so there is nothing to resubmit.
        let submitted = token.isEmpty ? nil : token
        do {
            result = save
                ? try await model.client.saveArk(baseURL: arkURL, agent: agent, token: submitted)
                : try await model.client.testArk(baseURL: arkURL, agent: agent, token: submitted)
            if save {
                token = ""
                await load()
                await model.refreshUser()
            }
        } catch {
            model.report(error)
        }
    }

    private func saveNotes() async {
        busy = true
        defer { busy = false }
        do {
            try await model.client.saveNotesDir(notesDir)
            await load()
            await model.refreshUser()
        } catch {
            model.report(error)
        }
    }

    private func startPath(for target: Picking) -> String {
        switch target {
        case .notes: return notesDir
        case .newBriefing: return ""
        case let .briefing(b): return b.path
        }
    }

    private func apply(_ path: String, to target: Picking) async {
        do {
            switch target {
            case .notes:
                notesDir = path
                try await model.client.saveNotesDir(path)
            case let .briefing(briefing):
                _ = try await model.client.updateBriefing(id: briefing.id, name: briefing.name,
                                                          path: path)
            case .newBriefing:
                // Ask for a name before creating, defaulting to one derived
                // from the folder.
                pendingPath = path
                pendingName = suggestBriefingName(for: path)
                return
            }
            await load()
            await model.refreshUser()
        } catch {
            model.report(error)
        }
    }

    private func addBriefing() async {
        guard let name = pendingName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        let path = pendingPath
        pendingName = nil
        do {
            _ = try await model.client.addBriefing(name: name, path: path)
            await load()
            await model.refreshUser()
        } catch {
            model.report(error)
        }
    }

    private func removeBriefings(_ offsets: IndexSet) async {
        guard let current = settings?.briefings else { return }
        do {
            for index in offsets {
                try await model.client.removeBriefing(id: current[index].id)
            }
            await load()
            await model.refreshUser()
        } catch {
            model.report(error)
        }
    }

    private func move(_ source: IndexSet, to destination: Int) async {
        guard var order = settings?.briefings else { return }
        order.move(fromOffsets: source, toOffset: destination)
        do {
            _ = try await model.client.reorderBriefings(ids: order.map(\.id))
            await load()
            await model.refreshUser()
        } catch {
            model.report(error)
        }
    }
}
