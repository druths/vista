import Foundation

// Wire types mirroring the Vista API. Field names use the server's snake_case
// via CodingKeys rather than a global key strategy, so each mapping is visible
// at the point it matters.

struct Briefing: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let path: String
}

struct User: Codable {
    let id: Int
    let email: String
    let displayName: String
    let configured: Bool
    let arkAgent: String?
    let notesDir: String
    let briefings: [Briefing]

    enum CodingKeys: String, CodingKey {
        case id, email, configured, briefings
        case displayName = "display_name"
        case arkAgent = "ark_agent"
        case notesDir = "notes_dir"
    }
}

struct LoginResponse: Codable {
    let token: String
    let user: User
}

/// One briefing document. The server has already collapsed the PDF, its
/// markdown source, and any markup sidecar into this single entry.
struct Brief: Codable, Identifiable, Hashable {
    let key: String
    let title: String
    let folder: String
    let date: Date
    let dateSource: String
    let modified: Date
    let size: Int
    let annotated: Bool
    let pdfPath: String?
    let textPath: String?
    let annotatedPath: String?
    let primaryPath: String?
    let primaryKind: String

    var id: String { key }

    /// True when the date was inferred from the file's mtime rather than read
    /// from its name — worth showing as approximate.
    var dateIsApproximate: Bool { dateSource == "mtime" }

    var isPDF: Bool { primaryKind == "pdf" }

    enum CodingKeys: String, CodingKey {
        case key, title, folder, date, modified, size, annotated
        case dateSource = "date_source"
        case pdfPath = "pdf_path"
        case textPath = "text_path"
        case annotatedPath = "annotated_path"
        case primaryPath = "primary_path"
        case primaryKind = "primary_kind"
    }
}

struct BriefsResponse: Codable {
    let briefing: Briefing
    let briefs: [Brief]
}

struct Note: Codable, Identifiable, Hashable {
    let name: String
    let title: String
    let path: String
    let size: Int
    let modified: Date
    let preview: String

    var id: String { name }
}

struct NotesResponse: Codable {
    let notesDir: String
    let notes: [Note]

    enum CodingKeys: String, CodingKey {
        case notes
        case notesDir = "notes_dir"
    }
}

struct NoteContent: Codable {
    let name: String
    let title: String
    let content: String
}

struct CreatedNote: Codable {
    let name: String
    let title: String
}

// MARK: - Settings

struct ArkSettings: Codable {
    let baseURL: String
    let agent: String
    /// The token itself is never sent to a client — only whether one is stored.
    let tokenSet: Bool

    enum CodingKeys: String, CodingKey {
        case agent
        case baseURL = "base_url"
        case tokenSet = "token_set"
    }
}

struct Settings: Codable {
    let ark: ArkSettings
    let notesDir: String
    let briefings: [Briefing]

    enum CodingKeys: String, CodingKey {
        case ark, briefings
        case notesDir = "notes_dir"
    }
}

struct ConnectionResult: Codable {
    let connected: Bool
    let detail: String
}

struct WorkspaceEntry: Codable, Identifiable, Hashable {
    let name: String
    let path: String

    var id: String { path }
}

struct WorkspaceListing: Codable {
    let path: String
    let parent: String?
    let directories: [WorkspaceEntry]
    let fileCount: Int
    let pdfCount: Int

    enum CodingKeys: String, CodingKey {
        case path, parent, directories
        case fileCount = "file_count"
        case pdfCount = "pdf_count"
    }
}

struct SortOption {
    enum Field: String, CaseIterable, Identifiable {
        case date, name
        var id: String { rawValue }
        var label: String { self == .date ? "Date" : "Name" }
    }

    var field: Field = .date
    var ascending: Bool = false

    var order: String { ascending ? "asc" : "desc" }
}
