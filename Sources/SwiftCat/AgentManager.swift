import Foundation
import AppKit

public struct WorkspaceItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: String
    public let ext: String
}

public struct FileBackupSnapshot: Equatable, Sendable {
    public let existed: Bool
    public let content: String
}

public enum AgentError: LocalizedError {
    case noWorkspace
    case invalidPath(String)
    case outsideWorkspace(String)
    
    public var errorDescription: String? {
        switch self {
        case .noWorkspace:
            return "No workspace selected"
        case .invalidPath(let path):
            return "Invalid file path: '\(path)'"
        case .outsideWorkspace(let path):
            return "Refused to write '\(path)': the path points outside the workspace folder"
        }
    }
}

@MainActor
public class AgentManager: ObservableObject {
    @Published public var currentWorkspaceURL: URL? {
        didSet {
            refreshWorkspace()
        }
    }
    
    @Published public var fileTreeSummary: String = ""
    @Published public var fileCount: Int = 0
    @Published public var flatWorkspaceFiles: [WorkspaceItem] = []
    @Published public var gitBranch: String? = nil
    @Published public var isAgentModeEnabled: Bool = true
    @Published public var autoApplyChanges: Bool = false {
        didSet {
            UserDefaults.standard.set(autoApplyChanges, forKey: "agent_auto_apply")
        }
    }
    @Published public var lastActionNotification: String?
    /// Bumped on every successful write so views can re-check what is on disk.
    @Published public private(set) var writeGeneration: Int = 0
    
    private static let lastWorkspaceKey = "agent_last_workspace_path"
    
    private struct FileRevertKey: Hashable {
        let path: String
        let proposedContent: String
    }
    private var backups: [FileRevertKey: FileBackupSnapshot] = [:]
    
    private let ignoredNames: Set<String> = [
        ".git", ".DS_Store", "node_modules", ".build", ".swiftpm", "DerivedData",
        "Pods", "Carthage", ".venv", "venv", "__pycache__", ".pytest_cache",
        ".mypy_cache", ".idea", ".vscode", ".cache", "dist", "out", "build",
        "target", ".next", ".nuxt", ".gradle"
    ]
    
    /// Upper bound on tree entries sent to the model, so a huge project
    /// cannot blow up the prompt.
    private let maxTreeEntries = 600
    
    public init() {
        let savedAutoApply = UserDefaults.standard.bool(forKey: "agent_auto_apply")
        self.autoApplyChanges = savedAutoApply
    }
    
    public func toggleAutoApply() {
        autoApplyChanges.toggle()
    }
    
    public func restoreLastWorkspace() {
        guard currentWorkspaceURL == nil,
              let path = UserDefaults.standard.string(forKey: Self.lastWorkspaceKey),
              !path.isEmpty else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            self.currentWorkspaceURL = URL(fileURLWithPath: path)
        }
    }
    
    public func setWorkspace(_ url: URL?) {
        if currentWorkspaceURL?.standardizedFileURL != url?.standardizedFileURL {
            backups.removeAll()
        }
        self.currentWorkspaceURL = url
        if let url {
            UserDefaults.standard.set(url.path, forKey: Self.lastWorkspaceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.lastWorkspaceKey)
        }
    }
    
    public func selectWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Project"
        panel.title = "Choose Workspace Folder for SwiftCat Agent"
        
        if panel.runModal() == .OK, let url = panel.url {
            setWorkspace(url)
        }
    }
    
    public func clearWorkspace() {
        setWorkspace(nil)
        self.fileTreeSummary = ""
        self.fileCount = 0
        self.flatWorkspaceFiles = []
        self.gitBranch = nil
    }
    
    public func refreshWorkspace() {
        guard let url = currentWorkspaceURL else {
            fileTreeSummary = ""
            fileCount = 0
            flatWorkspaceFiles = []
            gitBranch = nil
            return
        }
        
        self.gitBranch = detectGitBranch(from: url)
        var count = 0
        var items: [WorkspaceItem] = []
        fileTreeSummary = generateFileTree(from: url, maxDepth: 4, fileCount: &count, items: &items)
        self.fileCount = count
        self.flatWorkspaceFiles = items
    }
    
    private func detectGitBranch(from baseURL: URL) -> String? {
        let gitDir = baseURL.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir.path) else { return nil }
        let headFile = gitDir.appendingPathComponent("HEAD")
        guard let headContent = try? String(contentsOf: headFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        if headContent.hasPrefix("ref: refs/heads/") {
            return String(headContent.dropFirst("ref: refs/heads/".count))
        }
        return String(headContent.prefix(7))
    }
    
    private func generateFileTree(from baseURL: URL, maxDepth: Int, fileCount: inout Int, items: inout [WorkspaceItem]) -> String {
        var lines: [String] = []
        lines.append("Root: \(baseURL.lastPathComponent)")
        
        var entryCount = 0
        var wasTruncated = false
        let basePrefix = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        
        func traverse(url: URL, depth: Int, prefix: String) {
            guard depth <= maxDepth, !wasTruncated else { return }
            let fileManager = FileManager.default
            guard let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
                return
            }
            
            let sorted = contents.sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
            
            for item in sorted {
                let name = item.lastPathComponent
                if ignoredNames.contains(name) { continue }
                
                if entryCount >= maxTreeEntries {
                    wasTruncated = true
                    return
                }
                entryCount += 1
                
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let relativePath = item.path.hasPrefix(basePrefix) ? String(item.path.dropFirst(basePrefix.count)) : item.path
                
                if isDir {
                    lines.append("\(prefix)├── \(name)/")
                    traverse(url: item, depth: depth + 1, prefix: prefix + "│   ")
                } else {
                    fileCount += 1
                    let size = (try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    let formattedSize = formatBytes(size)
                    lines.append("\(prefix)├── \(name) (\(formattedSize))")
                    items.append(WorkspaceItem(
                        name: name,
                        path: relativePath,
                        isDirectory: false,
                        size: formattedSize,
                        ext: (name as NSString).pathExtension.lowercased()
                    ))
                }
            }
        }
        
        traverse(url: baseURL, depth: 1, prefix: "")
        if wasTruncated {
            lines.append("... (tree truncated after \(maxTreeEntries) entries)")
        }
        return lines.joined(separator: "\n")
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024.0
        return String(format: "%.1f MB", mb)
    }
    
    public func normalizedRelativePath(_ relativePath: String) -> String {
        relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^(\\./|/)+", with: "", options: .regularExpression)
    }
    
    /// Resolves a path inside the current workspace. Throws when there is no
    /// workspace or when the path would land outside of it (absolute paths,
    /// `..` segments), since these paths come straight from model output.
    public func resolveWorkspaceURL(for relativePath: String) throws -> URL {
        guard let baseURL = currentWorkspaceURL?.standardizedFileURL else {
            throw AgentError.noWorkspace
        }
        let cleanPath = normalizedRelativePath(relativePath)
        guard !cleanPath.isEmpty else {
            throw AgentError.invalidPath(relativePath)
        }
        
        let targetURL = baseURL.appendingPathComponent(cleanPath).standardizedFileURL
        let basePrefix = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        guard targetURL.path.hasPrefix(basePrefix) else {
            throw AgentError.outsideWorkspace(relativePath)
        }
        return targetURL
    }
    
    public func readFileContent(relativePath: String) -> String? {
        guard let targetURL = try? resolveWorkspaceURL(for: relativePath) else { return nil }
        return try? String(contentsOf: targetURL, encoding: .utf8)
    }
    
    /// Returns a workspace-relative path if `url` points inside `currentWorkspaceURL`.
    public func relativeWorkspacePath(for url: URL) -> String? {
        guard let baseURL = currentWorkspaceURL?.standardizedFileURL else { return nil }
        let targetPath = url.standardizedFileURL.path
        let basePrefix = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        guard targetPath.hasPrefix(basePrefix) else { return nil }
        let rel = String(targetPath.dropFirst(basePrefix.count))
        return rel.isEmpty ? nil : rel
    }
    
    public func backupSnapshot(for relativePath: String, proposedContent: String) -> FileBackupSnapshot? {
        let key = FileRevertKey(path: normalizedRelativePath(relativePath), proposedContent: proposedContent)
        return backups[key]
    }
    
    public func findRelevantFiles(in prompt: String) -> [String: String] {
        findRelevantFiles(inMessages: [prompt])
    }
    
    public func findRelevantFiles(inMessages texts: [String], maxFiles: Int = 8) -> [String: String] {
        guard let baseURL = currentWorkspaceURL?.standardizedFileURL, !texts.isEmpty else { return [:] }
        var results: [String: String] = [:]
        let maxFileBytes = 150_000
        let recentTexts = Array(texts.suffix(6).reversed())
        let basePrefix = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        
        // 1. Prioritize explicit @file mentions from newest messages backward
        let mentionPattern = #"(?:^|\s)@([^\s,;:!?\"'`()\[\]{}]+)"#
        if let regex = try? NSRegularExpression(pattern: mentionPattern, options: []) {
            for text in recentTexts {
                let nsPrompt = text as NSString
                let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsPrompt.length))
                for match in matches where match.numberOfRanges >= 2 {
                    let rawMention = nsPrompt.substring(with: match.range(at: 1))
                    if let url = try? resolveWorkspaceURL(for: rawMention),
                       let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
                       values.isDirectory != true,
                       (values.fileSize ?? 0) <= maxFileBytes,
                       let content = try? String(contentsOf: url, encoding: .utf8) {
                        let rel = url.path.hasPrefix(basePrefix) ? String(url.path.dropFirst(basePrefix.count)) : rawMention
                        if results[rel] == nil {
                            results[rel] = content
                        }
                    } else if let matchedItem = flatWorkspaceFiles.first(where: {
                        $0.path.caseInsensitiveCompare(rawMention) == .orderedSame ||
                        $0.name.caseInsensitiveCompare(rawMention) == .orderedSame
                    }), results[matchedItem.path] == nil,
                              let content = readFileContent(relativePath: matchedItem.path) {
                        results[matchedItem.path] = content
                    }
                    if results.count >= maxFiles { return results }
                }
            }
        }
        
        // 2. Fall back to filename / path matches across recent turns (newest turns win)
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return results
        }
        
        let lowerTexts = recentTexts.map { $0.lowercased() }
        // Prioritize explicit file/path matches, then fall back to whole-word symbol/stem matches.
        var candidates: [(rank: Int, isExactName: Bool, relPath: String, content: String)] = []
        
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            
            if values?.isDirectory == true {
                // Match whole names only: a substring check would also skip
                // "Layout.swift" or "Router.swift" because they contain "out".
                if ignoredNames.contains(name) { enumerator.skipDescendants() }
                continue
            }
            if ignoredNames.contains(name) { continue }
            
            // Very short names ("a", "go") match almost any prompt by accident.
            guard name.count >= 3 else { continue }
            
            let path = fileURL.standardizedFileURL.path
            let relativePath = path.hasPrefix(basePrefix) ? String(path.dropFirst(basePrefix.count)) : path
            guard results[relativePath] == nil else { continue }
            
            let nameLower = name.lowercased()
            let relLower = relativePath.lowercased()
            let stemLower = ((name as NSString).deletingPathExtension).lowercased()
            
            if let exactRank = lowerTexts.firstIndex(where: { $0.contains(nameLower) || $0.contains(relLower) }) {
                guard (values?.fileSize ?? 0) <= maxFileBytes,
                      let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                candidates.append((rank: exactRank, isExactName: true, relPath: relativePath, content: content))
            } else if stemLower.count >= 5 {
                let escaped = NSRegularExpression.escapedPattern(for: stemLower)
                let wordPattern = "(?<![a-z0-9_])" + escaped + "(?![a-z0-9_])"
                if let stemRank = lowerTexts.firstIndex(where: { $0.range(of: wordPattern, options: .regularExpression) != nil }) {
                    guard (values?.fileSize ?? 0) <= maxFileBytes,
                          let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                    candidates.append((rank: stemRank, isExactName: false, relPath: relativePath, content: content))
                }
            }
        }
        
        let sortedCandidates = candidates.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.isExactName != $1.isExactName { return $0.isExactName }
            return $0.relPath < $1.relPath
        }
        for candidate in sortedCandidates {
            if results.count >= maxFiles { break }
            results[candidate.relPath] = candidate.content
        }
        
        return results
    }
    
    public func writeFile(relativePath: String, content: String, refresh: Bool = true) throws {
        let targetURL = try resolveWorkspaceURL(for: relativePath)
        let normPath = normalizedRelativePath(relativePath)
        let key = FileRevertKey(path: normPath, proposedContent: content)
        if backups[key] == nil {
            let existed = FileManager.default.fileExists(atPath: targetURL.path)
            let diskContent = existed ? ((try? String(contentsOf: targetURL, encoding: .utf8)) ?? "") : ""
            if !existed || diskContent != content {
                backups[key] = FileBackupSnapshot(existed: existed, content: diskContent)
            }
        }
        
        let parentDir = targetURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try content.write(to: targetURL, atomically: true, encoding: .utf8)
        
        if refresh {
            self.refreshWorkspace()
            self.writeGeneration += 1
            self.lastActionNotification = "Saved: \(normPath)"
        }
    }
    
    /// Writes multiple proposed files while refreshing the workspace tree only once.
    @discardableResult
    public func writeFiles(_ proposals: [(path: String, content: String)]) -> (saved: [String], errors: [String]) {
        var saved: [String] = []
        var errors: [String] = []
        for item in proposals {
            do {
                try writeFile(relativePath: item.path, content: item.content, refresh: false)
                saved.append(normalizedRelativePath(item.path))
            } catch {
                errors.append("\(item.path): \(error.localizedDescription)")
            }
        }
        if !saved.isEmpty {
            self.refreshWorkspace()
            self.writeGeneration += 1
        }
        if !errors.isEmpty {
            self.lastActionNotification = "Could not save: " + errors.joined(separator: "; ")
        } else if saved.count == 1, let single = saved.first {
            self.lastActionNotification = "Saved: \(single)"
        } else if saved.count > 1 {
            self.lastActionNotification = "Saved \(saved.count) files"
        }
        return (saved, errors)
    }
    
    public func revertFile(relativePath: String, to proposedContent: String) throws {
        let normPath = normalizedRelativePath(relativePath)
        let key = FileRevertKey(path: normPath, proposedContent: proposedContent)
        guard let snapshot = backups[key] else { return }
        backups.removeValue(forKey: key)
        
        if snapshot.existed {
            let targetURL = try resolveWorkspaceURL(for: relativePath)
            let parentDir = targetURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try snapshot.content.write(to: targetURL, atomically: true, encoding: .utf8)
            self.refreshWorkspace()
            self.writeGeneration += 1
            self.lastActionNotification = "Reverted: \(normPath)"
        } else {
            try deleteFile(relativePath: relativePath)
        }
    }
    
    public func deleteFile(relativePath: String) throws {
        let targetURL = try resolveWorkspaceURL(for: relativePath)
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        self.refreshWorkspace()
        self.writeGeneration += 1
        self.lastActionNotification = "Removed: \(relativePath.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
    
    public func extractReadRequests(from text: String) -> [String] {
        var paths: [String] = []
        var seen = Set<String>()
        let pattern = #"<read_file\s+path=["']([^"']+)["']\s*(?:\/>|>[\s\S]*?<\/read_file>)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsString = text as NSString
        for match in regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length)) {
            if match.numberOfRanges >= 2 {
                let path = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty && !seen.contains(path) {
                    seen.insert(path)
                    paths.append(path)
                }
            }
        }
        return paths
    }
    
    public func extractFileProposals(from text: String) -> [FileActionProposal] {
        var proposals: [FileActionProposal] = []
        var detectedPaths = Set<String>()
        
        // Pattern 1: <write_file path="...">content</write_file>
        let xmlPattern = #"<write_file\s+path=["']([^"']+)["']>([\s\S]*?)<\/write_file>"#
        if let regex = try? NSRegularExpression(pattern: xmlPattern, options: []) {
            let nsString = text as NSString
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches {
                if match.numberOfRanges >= 3 {
                    let path = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let content = nsString.substring(with: match.range(at: 2)).trimmingCharacters(in: .newlines)
                    if !detectedPaths.contains(path) {
                        detectedPaths.insert(path)
                        proposals.append(FileActionProposal(path: path, content: content, isApplied: false))
                    }
                }
            }
        }
        
        // Pattern 2: ```file:relative/path ... ```
        let blockPattern = #"```(?:file:)([^\n]+)\n([\s\S]*?)```"#
        if let regex = try? NSRegularExpression(pattern: blockPattern, options: []) {
            let nsString = text as NSString
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches {
                if match.numberOfRanges >= 3 {
                    let path = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let content = nsString.substring(with: match.range(at: 2)).trimmingCharacters(in: .newlines)
                    if !detectedPaths.contains(path) {
                        detectedPaths.insert(path)
                        proposals.append(FileActionProposal(path: path, content: content, isApplied: false))
                    }
                }
            }
        }
        
        return proposals
    }
}
