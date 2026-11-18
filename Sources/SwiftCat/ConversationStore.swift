import Foundation

/// Persists conversations as a JSON file in Application Support.
/// Chat history can grow to megabytes, which UserDefaults is not meant for.
public enum ConversationStore {
    private static let legacyDefaultsKey = "swiftcat_conversations_v1"
    
    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SwiftCat", isDirectory: true).appendingPathComponent("conversations.json")
    }
    
    public static func load() -> [Conversation] {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Conversation].self, from: data) {
            return saved
        }
        // Earlier versions kept everything in UserDefaults; pick that up once.
        if let data = UserDefaults.standard.data(forKey: legacyDefaultsKey),
           let saved = try? JSONDecoder().decode([Conversation].self, from: data) {
            return saved
        }
        return []
    }
    
    public static func save(_ conversations: [Conversation]) {
        do {
            let data = try JSONEncoder().encode(conversations)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("SwiftCat: failed to save conversations: \(error.localizedDescription)")
        }
    }
}
