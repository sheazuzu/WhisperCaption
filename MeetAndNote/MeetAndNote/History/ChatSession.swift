import Foundation

/// A persisted chat = one session of the live-caption feed. Sessions are
/// identified by a human-readable timestamp string ("2026-05-12-14-30-22")
/// which doubles as the on-disk folder name, so the user can browse the
/// `~/Library/Application Support/MeetAndNote/Chats/` folder with Finder
/// and recognise each session by its creation time.
struct ChatSession: Codable, Identifiable, Sendable, Hashable {

    /// Stable identifier: timestamp formatted as `yyyy-MM-dd-HH-mm-ss`.
    /// Doubles as the on-disk folder name. If two sessions are created in
    /// the same wall-clock second `ChatHistoryStore` resolves the collision
    /// by appending `-N`.
    let id: String

    /// The moment the user pressed "New chat" (or app launched with no
    /// prior session). Immutable for the life of the session — the
    /// display name in the picker derives from this.
    let createdAt: Date

    /// Last time any caption was added or updated. Used for the "modified"
    /// column in the history editor and to break ties in the picker when
    /// `createdAt` is equal.
    var updatedAt: Date

    /// User-editable chat name. `nil` (or empty after trim) means the UI
    /// falls back to the timestamp `id`. Optional so existing on-disk
    /// JSON that pre-dates this field decodes without migration.
    var title: String?

    /// The same timeline `CaptionStream.captions` exposes. Screenshot
    /// payloads referenced by `Caption.imageFilename` live in a sibling
    /// `images/` folder on disk and are loaded via `ChatImageStore`.
    var captions: [Caption]

    init(id: String, createdAt: Date = Date(), title: String? = nil, captions: [Caption] = []) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.title = title
        self.captions = captions
    }

    /// `yyyy-MM-dd-HH-mm-ss` formatter, POSIX locale so it's stable
    /// regardless of the user's regional settings.
    static let idFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        f.timeZone = TimeZone.current
        return f
    }()

    /// String the picker / sidebar display: user-provided `title` if
    /// present (after trimming whitespace), otherwise the timestamp id.
    var displayName: String {
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        return id
    }

    /// True when the user hasn't yet given this chat a custom name — the
    /// picker uses this to render the fallback timestamp with a muted /
    /// monospaced style.
    var hasCustomTitle: Bool {
        guard let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !t.isEmpty
    }
}
