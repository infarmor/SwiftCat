import Foundation
import FoundationModels

public enum LLMError: LocalizedError {
    case missingAPIKey
    case invalidEndpoint(String)
    case http(provider: String, status: Int, message: String)
    case stream(provider: String, message: String)
    case localServerUnreachable(model: String, url: String)
    case appleIntelligenceUnavailable(String)
    
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenRouter API Key is missing. Please open Settings (gear icon) and paste your key."
        case .invalidEndpoint(let endpoint):
            return "The endpoint '\(endpoint)' is not a valid URL. Check it in Settings."
        case .http(let provider, let status, let message):
            return "\(provider) error (\(status)): \(message)"
        case .stream(let provider, let message):
            return "\(provider) error: \(message)"
        case .localServerUnreachable(let model, let url):
            return "Failed to connect to local model '\(model)' at \(url). Make sure Ollama or your local model runner is active on your Mac!"
        case .appleIntelligenceUnavailable(let reason):
            return "Apple Intelligence is not available on this Mac right now (\(reason)). Pick another model in Settings."
        }
    }
}

/// Stores API keys in an owner-only (`0600`) file inside Application Support
/// rather than the world-readable UserDefaults plist, while keeping local
/// unsigned builds free of macOS Keychain prompts.
private enum PrivateCredentialsStore {
    private static let legacyKey = "openrouter_api_key"
    
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SwiftCat", isDirectory: true).appendingPathComponent("credentials.json")
    }
    
    static func loadOpenRouterKey() -> String {
        if let data = try? Data(contentsOf: fileURL),
           let dict = try? JSONDecoder().decode([String: String].self, from: data),
           let key = dict["openrouter_api_key"] {
            return key
        }
        if let legacy = UserDefaults.standard.string(forKey: legacyKey), !legacy.isEmpty {
            saveOpenRouterKey(legacy)
            UserDefaults.standard.removeObject(forKey: legacyKey)
            return legacy
        }
        return ""
    }
    
    static func saveOpenRouterKey(_ key: String) {
        let dir = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(["openrouter_api_key": key])
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("SwiftCat: failed to save credentials: \(error.localizedDescription)")
        }
    }
}

@MainActor
public class LLMService: ObservableObject {
    public static let shared = LLMService()
    
    @Published public var openRouterKey: String {
        didSet {
            PrivateCredentialsStore.saveOpenRouterKey(openRouterKey)
        }
    }
    
    @Published public var localServerEndpoint: String {
        didSet {
            UserDefaults.standard.set(localServerEndpoint, forKey: "local_llm_endpoint")
        }
    }
    
    @Published public var isLocalServerOnline: Bool = false
    @Published public var detectedLocalModels: [String] = []
    
    @Published public var availableModels: [ConfiguredModel] = [] {
        didSet {
            saveModels()
        }
    }
    
    @Published public var selectedModel: ConfiguredModel {
        didSet {
            UserDefaults.standard.set(selectedModel.slug, forKey: "selected_model_slug")
        }
    }
    
    public init() {
        let savedKey = PrivateCredentialsStore.loadOpenRouterKey()
        self.openRouterKey = savedKey
        
        let savedEndpoint = UserDefaults.standard.string(forKey: "local_llm_endpoint") ?? "http://localhost:11434/v1"
        self.localServerEndpoint = savedEndpoint
        
        // Load saved models or start clean with Apple Intelligence
        var models = [ConfiguredModel.appleIntelligence]
        var migratedNames = false
        if let data = UserDefaults.standard.data(forKey: "configured_models_v2"),
           let decoded = try? JSONDecoder().decode([ConfiguredModel].self, from: data) {
            for var m in decoded where m.slug != ConfiguredModel.appleIntelligence.slug {
                if m.isLocalServer && (
                    m.name.contains("/") ||
                    m.name.localizedCaseInsensitiveContains("gguf") ||
                    m.name.localizedCaseInsensitiveContains("heretic") ||
                    m.name.localizedCaseInsensitiveContains("uncensored")
                ) {
                    m.name = Self.cleanLocalModelName(m.slug)
                    migratedNames = true
                }
                models.append(m)
            }
        }
        self.availableModels = models
        
        let savedSlug = UserDefaults.standard.string(forKey: "selected_model_slug") ?? ConfiguredModel.appleIntelligence.slug
        if let match = models.first(where: { $0.slug == savedSlug }) {
            self.selectedModel = match
        } else {
            self.selectedModel = ConfiguredModel.appleIntelligence
        }
        
        if migratedNames {
            saveModels()
        }
        
        Task {
            await self.checkLocalServerStatus()
        }
    }
    
    public nonisolated static func cleanLocalModelName(_ raw: String) -> String {
        let name = raw.components(separatedBy: "/").last ?? raw
        let base = name.components(separatedBy: ":").first ?? name
        var clean = base
        for suffix in ["-UNCENSORED", "-heretic", "-GGUF"] {
            clean = clean.replacingOccurrences(of: suffix, with: "", options: .caseInsensitive)
        }
        return clean.isEmpty ? raw : clean
    }
    
    private func autoSyncDetectedLocalModels(_ rawNames: [String]) {
        for raw in rawNames {
            let clean = Self.cleanLocalModelName(raw)
            if !availableModels.contains(where: { $0.slug == raw }) {
                let model = ConfiguredModel(
                    name: clean,
                    slug: raw,
                    isLocal: true,
                    iconName: "cpu"
                )
                availableModels.append(model)
            }
        }
        // Only pick a local model automatically when the user has never chosen one;
        // otherwise an explicit Apple Intelligence selection would be overridden on every refresh.
        let hasExplicitChoice = UserDefaults.standard.string(forKey: "selected_model_slug") != nil
        if !hasExplicitChoice, selectedModel.isAppleIntelligence, let firstLocal = availableModels.first(where: { $0.isLocalServer }) {
            selectedModel = firstLocal
        }
    }
    
    public func addCustomModel(name: String, slug: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSlug.isEmpty else { return }
        
        let newModel = ConfiguredModel(
            name: cleanName.isEmpty ? cleanSlug : cleanName,
            slug: cleanSlug,
            isLocal: false,
            iconName: "sparkles"
        )
        
        availableModels.removeAll { $0.slug == cleanSlug && !$0.isLocal }
        availableModels.append(newModel)
        selectedModel = newModel
    }
    
    public func addLocalModel(name: String, slug: String, endpoint: String? = nil) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSlug.isEmpty else { return }
        
        let newModel = ConfiguredModel(
            name: cleanName.isEmpty ? cleanSlug : cleanName,
            slug: cleanSlug,
            isLocal: true,
            iconName: "cpu",
            customEndpoint: endpoint
        )
        
        availableModels.removeAll { $0.slug == cleanSlug && $0.isLocal }
        availableModels.append(newModel)
        selectedModel = newModel
    }
    
    public func removeModel(_ model: ConfiguredModel) {
        guard !model.isAppleIntelligence else { return } // Cannot delete Apple Intelligence
        availableModels.removeAll { $0.id == model.id }
        if selectedModel.id == model.id {
            selectedModel = ConfiguredModel.appleIntelligence
        }
    }
    
    public func checkLocalServerStatus() async {
        let cleanEndpoint = localServerEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        
        // 1. Check Ollama native tags on the configured host (not a hard-coded one)
        if cleanEndpoint.contains("11434"), var components = URLComponents(string: cleanEndpoint) {
            components.path = "/api/tags"
            components.query = nil
            if let tagsURL = components.url {
                var req = URLRequest(url: tagsURL)
                req.timeoutInterval = 2.0
                if let (data, resp) = try? await URLSession.shared.data(for: req),
                   (resp as? HTTPURLResponse)?.statusCode == 200 {
                    struct OllamaTags: Decodable {
                        struct Item: Decodable { let name: String }
                        let models: [Item]
                    }
                    if let tags = try? JSONDecoder().decode(OllamaTags.self, from: data) {
                        self.isLocalServerOnline = true
                        self.detectedLocalModels = tags.models.map { $0.name }
                        self.autoSyncDetectedLocalModels(self.detectedLocalModels)
                        return
                    }
                }
            }
        }
        
        // 2. Check generic OpenAI /models
        let modelsPath = cleanEndpoint.hasSuffix("/v1") ? "\(cleanEndpoint)/models" : "\(cleanEndpoint)/v1/models"
        if let modelsURL = URL(string: modelsPath) {
            var req = URLRequest(url: modelsURL)
            req.timeoutInterval = 2.0
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                struct OpenAIModels: Decodable {
                    struct Item: Decodable { let id: String }
                    let data: [Item]
                }
                if let parsed = try? JSONDecoder().decode(OpenAIModels.self, from: data) {
                    self.isLocalServerOnline = true
                    self.detectedLocalModels = parsed.data.map { $0.id }
                    self.autoSyncDetectedLocalModels(self.detectedLocalModels)
                    return
                }
            }
        }
        
        self.isLocalServerOnline = false
        self.detectedLocalModels = []
    }
    
    private func saveModels() {
        if let encoded = try? JSONEncoder().encode(availableModels) {
            UserDefaults.standard.set(encoded, forKey: "configured_models_v2")
        }
    }
    
    public func sendPrompt(
        conversation: [ChatMessage],
        workspaceTree: String?,
        inspectedFiles: [String: String]? = nil,
        isAgentMode: Bool,
        onReasoning: @escaping (String) -> Void,
        onToken: @escaping (String) -> Void
    ) async throws -> (content: String, reasoning: String) {
        // Empty turns (a stopped or failed reply) only confuse the model and some APIs reject them.
        let history = conversation.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        if selectedModel.isAppleIntelligence {
            return try await sendToAppleFoundationModel(conversation: history, onReasoning: onReasoning, onToken: onToken)
        } else if selectedModel.isLocalServer {
            return try await sendToLocalServer(conversation: history, workspaceTree: workspaceTree, inspectedFiles: inspectedFiles, isAgentMode: isAgentMode, onReasoning: onReasoning, onToken: onToken)
        } else {
            return try await sendToOpenRouter(conversation: history, workspaceTree: workspaceTree, inspectedFiles: inspectedFiles, isAgentMode: isAgentMode, onReasoning: onReasoning, onToken: onToken)
        }
    }
    
    // MARK: - Apple Intelligence (on-device)
    
    private func sendToAppleFoundationModel(
        conversation: [ChatMessage],
        onReasoning: @escaping (String) -> Void,
        onToken: @escaping (String) -> Void
    ) async throws -> (content: String, reasoning: String) {
        if case .unavailable(let reason) = SystemLanguageModel.default.availability {
            throw LLMError.appleIntelligenceUnavailable(String(describing: reason))
        }
        
        // Fresh session per request without any system instructions preamble.
        let session = LanguageModelSession()
        
        // The on-device model has a small context window, so keep the prompt tight.
        let recentMessages = conversation.suffix(6)
        var promptText = ""
        
        if recentMessages.count <= 1, let single = recentMessages.last {
            promptText = single.content
        } else {
            for msg in recentMessages {
                let roleName = msg.role == .user ? "User" : "Assistant"
                promptText += "\(roleName): \(msg.content)\n\n"
            }
            promptText += "Assistant:"
        }
        
        let router = StreamChunkRouter()
        var emitted = ""
        // Each snapshot carries the whole text so far; forward only what is new.
        for try await snapshot in session.streamResponse(to: Prompt(promptText)) {
            let text = snapshot.content
            if text.hasPrefix(emitted) {
                router.feedDelta(content: String(text.dropFirst(emitted.count)), reasoning: nil, onReasoning: onReasoning, onContent: onToken)
            }
            emitted = text
        }
        return router.finish(onReasoning: onReasoning, onContent: onToken)
    }
    
    // MARK: - Local OpenAI-compatible server
    
    private func sendToLocalServer(
        conversation: [ChatMessage],
        workspaceTree: String?,
        inspectedFiles: [String: String]?,
        isAgentMode: Bool,
        onReasoning: @escaping (String) -> Void,
        onToken: @escaping (String) -> Void
    ) async throws -> (content: String, reasoning: String) {
        let base = (selectedModel.customEndpoint ?? localServerEndpoint).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let chatURLString = base.hasSuffix("/v1") ? "\(base)/chat/completions" : "\(base)/v1/chat/completions"
        
        guard let url = URL(string: chatURLString), url.scheme != nil else {
            throw LLMError.invalidEndpoint(base)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer local", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        
        let systemContent = Self.buildSystemPrompt(
            workspaceTree: workspaceTree,
            inspectedFiles: inspectedFiles,
            isAgentMode: isAgentMode
        )
        
        request.httpBody = try Self.chatRequestBody(model: selectedModel.slug, system: systemContent, conversation: conversation)
        
        do {
            return try await streamChatCompletion(request: request, provider: "Local model", onReasoning: onReasoning, onToken: onToken)
        } catch let error as URLError where Self.connectionFailureCodes.contains(error.code) {
            // Only genuine connection problems get the "is Ollama running?" hint;
            // HTTP errors and cancellation keep their own message.
            throw LLMError.localServerUnreachable(model: selectedModel.name, url: chatURLString)
        }
    }
    
    // MARK: - OpenRouter
    
    private func sendToOpenRouter(
        conversation: [ChatMessage],
        workspaceTree: String?,
        inspectedFiles: [String: String]?,
        isAgentMode: Bool,
        onReasoning: @escaping (String) -> Void,
        onToken: @escaping (String) -> Void
    ) async throws -> (content: String, reasoning: String) {
        let apiKey = openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw LLMError.missingAPIKey
        }
        
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("https://swiftcat.local", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("SwiftCat macOS", forHTTPHeaderField: "X-Title")
        request.timeoutInterval = 120
        
        let systemContent = Self.buildSystemPrompt(
            workspaceTree: workspaceTree,
            inspectedFiles: inspectedFiles,
            isAgentMode: isAgentMode
        )
        
        request.httpBody = try Self.chatRequestBody(model: selectedModel.slug, system: systemContent, conversation: conversation)
        
        return try await streamChatCompletion(request: request, provider: "OpenRouter", onReasoning: onReasoning, onToken: onToken)
    }
    
    // MARK: - Shared OpenAI-compatible streaming
    
    private static let connectionFailureCodes: Set<URLError.Code> = [
        .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost,
        .notConnectedToInternet, .dnsLookupFailed, .badURL, .unsupportedURL
    ]
    
    static func buildSystemPrompt(
        workspaceTree: String?,
        inspectedFiles: [String: String]?,
        isAgentMode: Bool
    ) -> String {
        var systemContent = """
        You are SwiftCat, an elite Staff Software Engineer and autonomous AI coding agent running natively on macOS (Apple Silicon).
        You are deeply integrated into the user's development environment with direct filesystem access, file-writing tools, and an integrated macOS terminal (zsh).

        ### OPERATIONAL RULES & CAPABILITIES:
        1. NO EXCUSES OR DISCLAIMERS: Never say "As an AI model, I cannot access your computer or filesystem" or "I cannot write files". You DO have direct file-writing tools and workspace context through SwiftCat.
        2. FILE SYSTEM OPERATIONS:
           - When creating a new file or modifying an existing file on the user's Mac, ALWAYS output the complete file using this exact tag format:
             <write_file path="relative/path/to/filename.ext">
             // Complete, fully-functional code without lazy placeholders (no '// ...rest of code...')
             </write_file>
             The SwiftCat desktop app will automatically detect this tag and apply the changes directly to disk.
           - If you need to read the contents of a workspace file that is not yet in the inspected section below before answering or editing, emit:
             <read_file path="relative/path/to/filename.ext" />
             SwiftCat will automatically load the file from disk and continue your turn with its contents.
        3. INTEGRATED TERMINAL:
           The user has a live interactive zsh terminal open right next to this chat. When commands need to be run (e.g. compiling, testing, git commands, installing dependencies), provide clean, exact shell commands in ```bash code blocks so they can run them immediately with one click.
        4. COMMUNICATION STYLE:
           - Professional, concise, senior engineer tone.
           - Skip conversational fluff (avoid "Sure, I'd be happy to help!", "Certainly!").
           - Respond in the exact language the user used (Russian, English, etc.).
           - Absolute rule: NEVER use emojis in your responses. Keep formatting clean and minimal.
           - When explaining code changes, be brief and highlight the exact logic modified.

        5. CRITICAL INSTRUCTION ON FILE ACCESS INQUIRIES:
           If the user asks whether you can see their files, access files, or inspect their code:
           - DO NOT give standard generic AI disclaimers like "I do not have access to your filesystem".
           - If a workspace structure is provided below: Affirm immediately: "Да, я вижу структуру и файлы вашего проекта в SwiftCat." and name the key files you see.
           - If NO workspace folder is attached yet: State clearly in Russian: "Папка проекта пока не подключена к SwiftCat. Нажмите кнопку «+» рядом с полем ввода (или используйте ⇧⌘O), чтобы выбрать папку проекта — после этого я сразу увижу всю структуру файлов и смогу их редактировать."
        """
        
        if isAgentMode, let tree = workspaceTree, !tree.isEmpty {
            systemContent += "\n\n### ACTIVE WORKSPACE DIRECTORY STRUCTURE:\nThe user has attached their project folder to SwiftCat. Here is the current file tree:\n```\n\(tree)\n```\nUse this tree to understand project architecture, file relationships, and file locations. When asked about files, answer directly based on this structure."
        } else {
            systemContent += "\n\n### WORKSPACE STATUS:\nNo project folder is attached to this chat yet. If the user asks you to inspect or edit local files, remind them: 'Нажмите кнопку \"+\" слева от поля ввода и выберите \"Attach Project Folder\", чтобы я подключился к папке вашего проекта.'"
        }
        systemContent += inspectedFilesSection(inspectedFiles, title: "RELEVANT FILE CONTENTS INSPECTED FROM WORKSPACE")
        return systemContent
    }
    
    private static func inspectedFilesSection(_ files: [String: String]?, title: String) -> String {
        guard let files, !files.isEmpty else { return "" }
        var section = "\n\n### \(title):\n"
        // Sorted so the prompt is stable between requests.
        for (path, content) in files.sorted(by: { $0.key < $1.key }) {
            section += "\n--- File: \(path) ---\n```\n\(content)\n```\n"
        }
        return section
    }
    
    private static func chatRequestBody(model: String, system: String, conversation: [ChatMessage]) throws -> Data {
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for msg in conversation {
            messages.append(["role": msg.role.rawValue, "content": msg.content])
        }
        let payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }
    
    /// Pulls a readable message out of an error body such as `{"error":{"message":"..."}}`.
    static func errorMessage(fromBody body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = json["error"] as? String {
                return message
            }
            if let message = json["message"] as? String {
                return message
            }
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No details returned by the server." : String(trimmed.prefix(600))
    }
    
    private func streamChatCompletion(
        request: URLRequest,
        provider: String,
        onReasoning: @escaping (String) -> Void,
        onToken: @escaping (String) -> Void
    ) async throws -> (content: String, reasoning: String) {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        guard (200..<300).contains(httpResponse.statusCode) else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 4000 { break }
            }
            throw LLMError.http(provider: provider, status: httpResponse.statusCode, message: Self.errorMessage(fromBody: errorBody))
        }
        
        let router = StreamChunkRouter()
        for try await line in bytes.lines {
            // The SSE spec allows "data:" with or without a following space.
            guard line.hasPrefix("data:") else { continue }
            let dataStr = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if dataStr == "[DONE]" { break }
            
            guard let jsonData = dataStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }
            
            // Providers report failures that happen mid-stream as a data event.
            if json["error"] != nil {
                throw LLMError.stream(provider: provider, message: Self.errorMessage(fromBody: dataStr))
            }
            
            guard let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else {
                continue
            }
            
            let contentChunk = delta["content"] as? String
            let reasoningChunk = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String) ?? (delta["thought"] as? String) ?? (delta["thinking"] as? String)
            
            router.feedDelta(content: contentChunk, reasoning: reasoningChunk, onReasoning: onReasoning, onContent: onToken)
        }
        
        return router.finish(onReasoning: onReasoning, onContent: onToken)
    }
}
