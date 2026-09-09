import Foundation
import CryptoKit

/// On-disk cache of downloaded briefs.
///
/// Briefs are immutable once published, so a brief already fetched can be
/// reopened instantly — and read on a plane. The cache key includes the file
/// size so a republished brief of a different length is refetched rather than
/// served stale.
enum BriefCache {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Briefs", isDirectory: true)
    }

    static func location(briefingID: Int, path: String, size: Int) -> URL {
        let digest = SHA256.hash(data: Data("\(briefingID)|\(path)|\(size)".utf8))
        let name = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(32)
        // Keep the real extension so QuickLook and PDFKit can identify the type.
        let ext = (path as NSString).pathExtension.isEmpty ? "pdf" : (path as NSString).pathExtension
        return directory.appendingPathComponent("\(name).\(ext)")
    }

    static func isCached(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
