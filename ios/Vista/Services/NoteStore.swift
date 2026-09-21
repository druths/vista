import CryptoKit
import Foundation
import Network
import Observation

/// Offline-capable store for notes.
///
/// Every note is kept on disk, so the list and the editor open without a
/// network. Edits and renames are applied locally first and pushed when the
/// server is reachable; until then they sit in the cache as pending work.
///
/// Writes carry the version the edit was based on. If the server has moved on
/// it refuses the write, and rather than picking a winner the local copy is
/// filed as a separate note marked as a conflict — nothing typed is ever
/// discarded to resolve one.
@MainActor
@Observable
final class NoteStore {
    struct Entry: Codable, Identifiable {
        /// Filename as this device knows it.
        var localName: String
        /// Filename the server knows. `nil` means it has never been synced,
        /// so syncing means creating it.
        var remoteName: String?
        var content: String
        /// Version the content was based on, quoted back on write.
        var baseVersion: String?
        var modified: Date
        /// Content differs from what the server last confirmed.
        var dirty: Bool
        /// Deleted here, not yet on the server. Kept in the cache rather than
        /// removed so the delete survives until it can be pushed.
        var deleted: Bool = false
        /// Pinned to the top of the list. Synced with the account, so it
        /// follows you to the web client and survives a reinstall.
        var starred: Bool = false
        /// Fingerprints of content this device has sent to the server, most
        /// recent last. Lets a refused write be recognised as our own work
        /// rather than someone else's edit.
        var sentVersions: [String] = []

        var id: String { localName }
        var title: String { (localName as NSString).deletingPathExtension }
        /// Renamed locally but the server still has the old name.
        var pendingRename: Bool { remoteName != nil && remoteName != localName }
        var pending: Bool { dirty || pendingRename || deleted || remoteName == nil }

        init(localName: String, remoteName: String?, content: String,
             baseVersion: String?, modified: Date, dirty: Bool,
             deleted: Bool = false, starred: Bool = false,
             sentVersions: [String] = []) {
            self.starred = starred
            self.sentVersions = sentVersions
            self.localName = localName
            self.remoteName = remoteName
            self.content = content
            self.baseVersion = baseVersion
            self.modified = modified
            self.dirty = dirty
            self.deleted = deleted
        }

        /// Hand-written so a cache file written before `deleted` existed still
        /// decodes; the synthesised version would reject it and silently wipe
        /// everything pending.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            localName = try container.decode(String.self, forKey: .localName)
            remoteName = try container.decodeIfPresent(String.self, forKey: .remoteName)
            content = try container.decode(String.self, forKey: .content)
            baseVersion = try container.decodeIfPresent(String.self, forKey: .baseVersion)
            modified = try container.decode(Date.self, forKey: .modified)
            dirty = try container.decode(Bool.self, forKey: .dirty)
            deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
            starred = try container.decodeIfPresent(Bool.self, forKey: .starred) ?? false
            sentVersions = try container.decodeIfPresent([String].self, forKey: .sentVersions) ?? []
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var syncing = false
    /// Set when a sync attempt failed, or when a conflict copy was filed.
    /// Settable so the view can clear it once it has been shown.
    var lastError: String?

    var pendingCount: Int { entries.filter(\.pending).count }

    private let client: VistaClient
    private var fileURL: URL?
    private var monitor: NWPathMonitor?
    /// Stars changed here and not yet pushed. Tracked as one flag rather than
    /// per note because the set is sent wholesale.
    private var starredDirty = false
    private var retry: Task<Void, Never>?
    private var retryAttempt = 0
    /// Set by a push that got somewhere, so sync knows to go round again for
    /// work that appeared while it was busy.
    private var madeProgress = false
    /// How many times in a row a note's refusal has been recognised as our own
    /// write. Bounded so a pathological case can't ping-pong forever.
    private var adoptions: [String: Int] = [:]

    /// Fingerprint of a note's content, matching the server's `version_of`:
    /// SHA-256, hex, first sixteen characters. Pinned by a golden test there,
    /// since the two have to agree or every write looks like a conflict.
    static func fingerprint(_ content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    init(client: VistaClient) {
        self.client = client
    }

    // MARK: - Lifecycle

    /// Point the store at one account's cache. Caches are per account so
    /// switching servers never shows the previous account's notes.
    func open(accountKey: String) {
        let digest = String(accountKey.hashValue.magnitude, radix: 36)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vista", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("notes-\(digest).json")
        entries = readCache()
        startWatchingConnectivity()
    }

    /// Stop using the cache, leaving it on disk — pending edits outlive a sign
    /// out, and the next sign in to the same account picks them up.
    func close() {
        retry?.cancel()
        retry = nil
        monitor?.cancel()
        monitor = nil
        fileURL = nil
        entries = []
    }

    private func startWatchingConnectivity() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                guard let self, self.pendingCount > 0 else { return }
                await self.sync()
            }
        }
        monitor.start(queue: .global(qos: .utility))
        self.monitor = monitor
    }

    // MARK: - Reading

    func entry(named name: String) -> Entry? {
        entries.first { $0.localName == name }
    }

    /// Refresh from the server, then push anything pending.
    ///
    /// Remote state is only adopted for notes with no local edit waiting; a
    /// pending edit always wins over what the list says, or typing offline
    /// would be undone by the next refresh.
    func refresh() async {
        guard fileURL != nil else { return }
        do {
            let listed = try await client.notes(sort: SortOption()).notes
            // Server stars win, unless stars changed here and haven't been
            // pushed yet — local intent outranks a stale listing.
            let adoptStars = !starredDirty
            var byRemote: [String: Entry] = [:]
            for entry in entries where entry.remoteName != nil {
                byRemote[entry.remoteName!] = entry
            }

            var merged: [Entry] = []
            for note in listed {
                if let existing = byRemote[note.name] {
                    var updated = existing
                    if adoptStars { updated.starred = note.isStarred }
                    if !existing.pending {
                        updated.modified = note.modified  // local work outranks the server
                    }
                    merged.append(updated)
                } else {
                    merged.append(Entry(localName: note.name, remoteName: note.name,
                                        content: "", baseVersion: nil,
                                        modified: note.modified, dirty: false,
                                        starred: adoptStars && note.isStarred))
                }
            }
            // Notes that exist only here — created or renamed offline.
            for entry in entries where entry.remoteName == nil || byRemote[entry.remoteName!] == nil {
                if entry.pending { merged.append(entry) }
            }

            entries = merged.sorted { $0.modified > $1.modified }
            writeCache()
            lastError = nil

            // Pull down the text of anything not held yet, so every note reads
            // offline — and so a delete queued later has a version to quote.
            await hydrate()
        } catch {
            // Offline is the expected case, not a failure worth surfacing.
            if !AppModel.isCancellation(error) { lastError = error.localizedDescription }
        }
        await sync()
    }

    /// Fetch content for cached notes that don't have it yet.
    ///
    /// Bounded concurrency: a few at a time keeps a large notes directory from
    /// opening dozens of connections at once.
    private func hydrate(limit: Int = 200, batchSize: Int = 6) async {
        let wanted = entries
            .filter { !$0.pending && $0.content.isEmpty && $0.remoteName != nil }
            .prefix(limit)
            .compactMap(\.remoteName)
        guard !wanted.isEmpty else { return }

        var index = 0
        while index < wanted.count {
            let batch = Array(wanted[index..<min(index + batchSize, wanted.count)])
            index += batchSize

            let fetched = await withTaskGroup(of: (String, NoteContent?).self) { group in
                for name in batch {
                    group.addTask { [client] in (name, try? await client.note(named: name)) }
                }
                var results: [(String, NoteContent?)] = []
                for await result in group { results.append(result) }
                return results
            }

            for (name, note) in fetched {
                guard let note,
                      var existing = entries.first(where: { $0.remoteName == name }),
                      !existing.pending else { continue }
                existing.content = note.content
                existing.baseVersion = note.version
                upsert(existing)
            }
        }
    }

    /// Content for a note, from cache when it's there, otherwise fetched.
    func content(for name: String) async -> String {
        guard var cached = entry(named: name) else { return "" }
        // A pending edit is the truth; never go to the server behind it.
        if cached.dirty { return cached.content }
        if cached.content.isEmpty, let remote = cached.remoteName {
            do {
                let note = try await client.note(named: remote)
                cached.content = note.content
                cached.baseVersion = note.version
                upsert(cached)
            } catch {
                // Leave whatever is cached; offline reads shouldn't error.
            }
        }
        return entry(named: name)?.content ?? cached.content
    }

    // MARK: - Writing

    /// Record an edit locally and try to push it. Always succeeds locally.
    func save(name: String, content: String) async {
        guard var target = entry(named: name) else { return }
        // Nothing to do: the editor fires a save when it closes as well as on
        // its timer, and writing identical text just churns.
        guard target.content != content || target.dirty else { return }
        target.content = content
        target.dirty = true
        target.modified = .now
        upsert(target)
        await sync()
    }

    func rename(name: String, to title: String) async -> String {
        guard var entry = entry(named: name) else { return name }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return name }
        entry.localName = trimmed.hasSuffix(".md") ? trimmed : "\(trimmed).md"
        entry.modified = .now
        // Replace under the new key.
        entries.removeAll { $0.localName == name }
        upsert(entry)
        await sync()
        return entry.localName
    }

    func create(title: String, content: String) async -> String {
        let stem = title.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Note \(Self.stamp(.now))"
            : title.trimmingCharacters(in: .whitespaces)
        var name = stem.hasSuffix(".md") ? stem : "\(stem).md"
        var suffix = 2
        while entry(named: name) != nil {
            name = "\(stem)-\(suffix).md"
            suffix += 1
        }
        upsert(Entry(localName: name, remoteName: nil, content: content,
                     baseVersion: nil, modified: .now, dirty: true))
        await sync()
        return name
    }

    /// Star or unstar. Applied locally at once and pushed with the next sync,
    /// so it works offline like every other change.
    func toggleStar(name: String) async {
        guard var target = entry(named: name) else { return }
        target.starred.toggle()
        upsert(target)
        starredDirty = true
        await sync()
    }

    /// Mark a note deleted locally and push when possible. The note leaves the
    /// list straight away; the server is told when it can be reached.
    func delete(name: String) async {
        guard var target = entry(named: name) else { return }
        guard target.remoteName != nil else {
            // Created offline and never pushed — nothing to tell the server.
            entries.removeAll { $0.localName == name }
            writeCache()
            return
        }
        target.deleted = true
        target.modified = .now
        upsert(target)
        await sync()
    }

    // MARK: - Syncing

    /// Push every pending entry. Safe to call often; it no-ops when idle.
    func sync() async {
        guard fileURL != nil, !syncing else { return }
        guard starredDirty || entries.contains(where: \.pending) else { return }

        syncing = true
        defer { syncing = false }

        // Work appears while a push is in flight — a keystroke landing during
        // a save. Go round again so it leaves now rather than waiting on the
        // failure backoff, but bound the rounds so a persistent refusal can't
        // spin here.
        var rounds = 0
        repeat {
            rounds += 1
            madeProgress = false

            if starredDirty {
                let names = entries
                    .filter { $0.starred && !$0.deleted }
                    .map { $0.remoteName ?? $0.localName }
                do {
                    try await client.setStarred(names: names)
                    starredDirty = false
                    madeProgress = true
                } catch {
                    if !AppModel.isCancellation(error) { lastError = error.localizedDescription }
                }
            }

            for entry in entries.filter(\.pending) {
                await push(entry)
            }
            writeCache()
        } while madeProgress && (starredDirty || pendingCount > 0) && rounds < 4

        // Anything still waiting means this attempt didn't get through.
        if starredDirty || pendingCount > 0 { scheduleRetry() } else { clearRetry() }
    }

    /// Retry a failed push on a backing-off schedule — roughly 10s, 20s, 40s,
    /// and so on to a five-minute ceiling. A server that is down shouldn't be
    /// hammered, but an edit shouldn't sit unsaved waiting to be noticed
    /// either. Connectivity returning short-circuits the wait.
    private func scheduleRetry() {
        retry?.cancel()
        retryAttempt = min(retryAttempt + 1, 6)
        let delay = min(pow(2.0, Double(retryAttempt)) * 5, 300)
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    private func clearRetry() {
        retry?.cancel()
        retry = nil
        retryAttempt = 0
        // Deliberately not clearing lastError: a conflict message lives there
        // and has to survive a successful sync to be read.
    }

    private func push(_ entry: Entry) async {
        var working = entry

        // A queued delete supersedes any edit or rename also pending on it.
        if working.deleted {
            await pushDelete(working)
            return
        }

        // A rename has to land before the content write, or the write would
        // target a name the server no longer has.
        if working.pendingRename, let remote = working.remoteName {
            do {
                let renamed = try await client.renameNote(name: remote, title: working.title)
                working.remoteName = renamed.name
                // The server may have suffixed to avoid a collision; adopt the
                // name it actually used so the two sides agree.
                working.localName = renamed.name
                replace(entry.localName, with: working)
            } catch let error as VistaError {
                if case .server(404, _) = error {
                    // Renamed or deleted elsewhere: keep our copy as a conflict.
                    await fileConflictCopy(working, reason: "renamed elsewhere")
                    entries.removeAll { $0.localName == entry.localName }
                }
                return                                   // offline or refused; try again later
            } catch {
                return
            }
        }

        guard working.remoteName != nil else {
            await pushCreate(working)
            return
        }
        guard working.dirty else { return }

        // Record what we're about to send, before sending it. If the reply
        // never arrives, this is the only evidence the write ever happened.
        let sent = Self.fingerprint(working.content)
        working.sentVersions = Array((working.sentVersions + [sent]).suffix(8))
        upsert(working)

        do {
            let outcome = try await client.saveNote(name: working.remoteName!,
                                                    content: working.content,
                                                    ifVersion: working.baseVersion)
            switch outcome {
            case let .saved(version):
                confirm(working.localName, version: version, wrote: working.content)
                adoptions[working.localName] = 0
                madeProgress = true
                lastError = nil
            case let .conflict(conflict):
                await handleRefusal(conflict, for: working)
            }
        } catch {
            if !AppModel.isCancellation(error) { lastError = error.localizedDescription }
        }
    }

    /// Record a successful write without throwing away anything typed while it
    /// was in flight.
    private func confirm(_ name: String, version: String?, wrote content: String) {
        guard var live = entry(named: name) else { return }
        live.baseVersion = version
        // Only clean if nothing newer arrived meanwhile; otherwise it stays
        // pending so the newer text goes out on the next round.
        if live.content == content { live.dirty = false }
        upsert(live)
    }

    /// A refused write.
    ///
    /// If the server is holding something this device sent, that's our own
    /// earlier save which we never heard back about — take its version and let
    /// the pending text go out again. Only content we've never sent is someone
    /// else's edit, and only that deserves a conflict copy.
    private func handleRefusal(_ conflict: NoteConflict, for entry: Entry) async {
        let name = entry.localName
        let ours = entry.sentVersions.contains(conflict.version)
        let attempts = adoptions[name] ?? 0

        if ours, attempts < 3 {
            adoptions[name] = attempts + 1
            if var live = self.entry(named: name) {
                live.baseVersion = conflict.version
                upsert(live)                     // still dirty: resent next round
            }
            madeProgress = true
            return
        }

        adoptions[name] = 0
        await resolve(entry, against: conflict)
    }

    private func pushDelete(_ entry: Entry) async {
        guard let remote = entry.remoteName else {
            entries.removeAll { $0.localName == entry.localName }
            return
        }
        do {
            switch try await client.deleteNote(name: remote, ifVersion: entry.baseVersion) {
            case .deleted:
                entries.removeAll { $0.localName == entry.localName }
                madeProgress = true
                lastError = nil
            case let .conflict(conflict):
                // Edited elsewhere while the delete sat queued, so the edit
                // wins: the note comes back holding what the server has.
                var restored = entry
                restored.deleted = false
                restored.dirty = false
                restored.content = conflict.content ?? restored.content
                restored.baseVersion = conflict.version
                restored.modified = .now
                replace(entry.localName, with: restored)
                lastError = "“\(entry.title)” was edited elsewhere, so it wasn't deleted."
            }
        } catch {
            if !AppModel.isCancellation(error) { lastError = error.localizedDescription }
        }
    }

    private func pushCreate(_ entry: Entry) async {
        do {
            let created = try await client.createNote(title: entry.title, content: entry.content)
            var working = entry
            working.remoteName = created.name
            working.localName = created.name
            working.baseVersion = created.version
            working.dirty = false
            replace(entry.localName, with: working)
            madeProgress = true
            lastError = nil
        } catch {
            if !AppModel.isCancellation(error) { lastError = error.localizedDescription }
        }
    }

    /// The server refused the write because the note changed while we were
    /// away. Keep theirs, and file ours alongside it rather than choosing.
    private func resolve(_ entry: Entry, against conflict: NoteConflict) async {
        await fileConflictCopy(entry, reason: "edited elsewhere")

        var working = entry
        if let remote = conflict.content {
            working.content = remote
            working.baseVersion = conflict.version
            working.dirty = false
            replace(entry.localName, with: working)
        } else {
            // The note is gone entirely; our copy now lives on as the conflict
            // note, so drop the original.
            entries.removeAll { $0.localName == entry.localName }
        }
        writeCache()
    }

    private func fileConflictCopy(_ entry: Entry, reason: String) async {
        let title = "\(entry.title) (conflict \(Self.stamp(entry.modified)))"
        do {
            let created = try await client.createNote(title: title, content: entry.content)
            upsert(Entry(localName: created.name, remoteName: created.name,
                         content: entry.content, baseVersion: created.version,
                         modified: .now, dirty: false))
            lastError = "“\(entry.title)” was \(reason); your version was saved as “\(created.name)”."
        } catch {
            // Couldn't file it remotely — keep it pending locally so the edit
            // survives for the next attempt.
            lastError = error.localizedDescription
        }
    }

    // MARK: - Cache

    private func upsert(_ entry: Entry) {
        if let index = entries.firstIndex(where: { $0.localName == entry.localName }) {
            entries[index] = entry
        } else {
            entries.insert(entry, at: 0)
        }
        writeCache()
    }

    private func replace(_ name: String, with entry: Entry) {
        entries.removeAll { $0.localName == name && $0.localName != entry.localName }
        upsert(entry)
    }

    private func readCache() -> [Entry] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func writeCache() {
        guard let fileURL else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return formatter.string(from: date)
    }
}
