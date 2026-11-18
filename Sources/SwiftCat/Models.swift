import Foundation

public enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

public struct FileActionProposal: Identifiable, Codable, Equatable {
    public var id: UUID
    public var path: String
    public var content: String
    public var isApplied: Bool
    
    public init(id: UUID = UUID(), path: String, content: String, isApplied: Bool = false) {
        self.id = id
        self.path = path
        self.content = content
        self.isApplied = isApplied
    }
}

public struct ChatMessage: Identifiable, Codable, Equatable {
    public var id: UUID
    public var role: MessageRole
    public var content: String
    public var timestamp: Date
    public var modelName: String?
    public var reasoning: String?
    public var reasoningDuration: TimeInterval?
    public var fileProposals: [FileActionProposal]?
    
    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        modelName: String? = nil,
        reasoning: String? = nil,
        reasoningDuration: TimeInterval? = nil,
        fileProposals: [FileActionProposal]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.modelName = modelName
        self.reasoning = reasoning
        self.reasoningDuration = reasoningDuration
        self.fileProposals = fileProposals
    }
}

public struct Conversation: Identifiable, Codable, Equatable {
    public var id: UUID
    public var title: String
    public var messages: [ChatMessage]
    public var createdAt: Date
    public var updatedAt: Date
    public var workspacePath: String?
    
    public init(
        id: UUID = UUID(),
        title: String = "New Conversation",
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        workspacePath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.workspacePath = workspacePath
    }
    
    public var previewSnippet: String {
        if let last = messages.last {
            // Rows show one line; trimming a whole long reply on every render is wasted work.
            return String(last.content.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "No messages yet"
    }
}

public struct ConfiguredModel: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var slug: String
    public var isLocal: Bool
    public var iconName: String
    public var customEndpoint: String?
    
    public init(
        id: UUID = UUID(),
        name: String,
        slug: String,
        isLocal: Bool = false,
        iconName: String = "sparkles",
        customEndpoint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.isLocal = isLocal
        self.iconName = iconName
        self.customEndpoint = customEndpoint
    }
    
    public var isAppleIntelligence: Bool {
        slug == ConfiguredModel.appleIntelligence.slug
    }
    
    public var isLocalServer: Bool {
        isLocal && !isAppleIntelligence
    }
    
    public static let appleIntelligence = ConfiguredModel(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Apple Intelligence",
        slug: "apple/foundation-model",
        isLocal: true,
        iconName: "apple.logo"
    )
}
