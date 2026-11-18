import Foundation
import AppKit
import SwiftUI

public struct TerminalEntry: Identifiable, Equatable {
    public let id = UUID()
    public let prompt: String
    public let command: String
    public var output: String
    public var exitCode: Int32
}

/// Lets the running process be reached from the main actor for cancellation.
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    
    func cancel() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        // Terminate child processes first while `pid` is still their parent,
        // otherwise descendants keep the stdout/stderr pipe open and stall EOF.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", "\(pid)"]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        try? pkill.run()
        pkill.waitUntilExit()
        
        process.terminate()
    }
}

@MainActor
public class TerminalManager: ObservableObject {
    @Published public var currentDirectory: URL {
        didSet {
            updatePrompt()
        }
    }
    
    @Published public var promptString: String = ""
    @Published public var entries: [TerminalEntry] = []
    @Published public var commandInput: String = ""
    @Published public var isRunningCommand: Bool = false
    @Published public var isPanelVisible: Bool = true
    @Published public var isMaximized: Bool = false
    
    private var runningProcess: ProcessBox?
    private var commandHistory: [String] = []
    private var historyIndex: Int = -1
    
    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.currentDirectory = home
        updatePrompt()
    }
    
    public func setWorkspaceDirectory(_ url: URL?) {
        if let url = url {
            self.currentDirectory = url
        }
    }
    
    public func executeExternalCommand(_ command: String) {
        isPanelVisible = true
        commandInput = command
        runCurrentCommand()
    }
    
    /// Stops the command that is currently running, if any.
    public func cancelRunningCommand() {
        runningProcess?.cancel()
    }
    
    private func updatePrompt() {
        let user = NSUserName()
        let host = ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "mac"
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        var dirDisplay = currentDirectory.path
        if dirDisplay.hasPrefix(homePath) {
            dirDisplay = "~" + dirDisplay.dropFirst(homePath.count)
        }
        self.promptString = "\(user)@\(host) \(dirDisplay) %"
    }
    
    public func runCurrentCommand() {
        let rawCmd = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawCmd.isEmpty else { return }
        
        // One command at a time; the typed text stays in the field until the current one ends.
        guard !isRunningCommand else { return }
        
        if commandHistory.last != rawCmd {
            commandHistory.append(rawCmd)
        }
        historyIndex = -1
        let currentPrompt = self.promptString
        commandInput = ""
        
        // Handle built-in commands like 'clear'
        if rawCmd == "clear" {
            entries.removeAll()
            return
        }
        
        // Handle a plain 'cd'. Compound commands ("cd app && make") go to zsh as a whole.
        if rawCmd == "cd" || rawCmd.hasPrefix("cd ") {
            let pathArg = rawCmd.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            if pathArg.rangeOfCharacter(from: CharacterSet(charactersIn: "&|;<>$`")) == nil {
                handleChangeDirectory(Self.unquoted(pathArg), prompt: currentPrompt, originalCommand: rawCmd)
                return
            }
        }
        
        isRunningCommand = true
        let entry = TerminalEntry(prompt: currentPrompt, command: rawCmd, output: "", exitCode: 0)
        let entryID = entry.id
        entries.append(entry)
        
        let box = ProcessBox()
        runningProcess = box
        let directory = currentDirectory
        
        Task.detached {
            let process = box.process
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", rawCmd]
            process.currentDirectoryURL = directory
            
            var env = ProcessInfo.processInfo.environment
            env["TERM"] = "xterm-256color"
            env["LANG"] = "en_US.UTF-8"
            process.environment = env
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            // No interactive stdin here: a command waiting for input would hang forever.
            process.standardInput = FileHandle.nullDevice
            
            var exitCode: Int32 = 0
            do {
                try process.run()
                
                // Stream output as it arrives so long builds show progress.
                let handle = pipe.fileHandleForReading
                var pending = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    let text = Self.decodeUTF8Prefix(of: &pending)
                    if !text.isEmpty {
                        await self.appendOutput(text, to: entryID)
                    }
                }
                if !pending.isEmpty {
                    await self.appendOutput(String(decoding: pending, as: UTF8.self), to: entryID)
                }
                
                process.waitUntilExit()
                exitCode = process.terminationStatus
            } catch {
                await self.appendOutput("Error: \(error.localizedDescription)", to: entryID)
                exitCode = 1
            }
            
            await self.finishCommand(entryID, exitCode: exitCode)
        }
    }
    
    private func appendOutput(_ text: String, to entryID: UUID) {
        // Look the entry up by id: 'clear' may have removed or shifted it meanwhile.
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[index].output += text
    }
    
    private func finishCommand(_ entryID: UUID, exitCode: Int32) {
        if let index = entries.firstIndex(where: { $0.id == entryID }) {
            let normalized = Self.normalizeControlChars(entries[index].output)
            entries[index].output = normalized.trimmingCharacters(in: .newlines)
            entries[index].exitCode = exitCode
        }
        runningProcess = nil
        isRunningCommand = false
    }
    
    /// Strips ANSI CSI/OSC escape sequences cleanly (for AI prompts, clipboard, and search).
    nonisolated static func stripANSI(_ text: String) -> String {
        let normalized = normalizeControlChars(text)
        let pattern = #"\x1B\[[0-9;?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B[@-Z\\-_]"#
        return normalized.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    
    /// Normalizes `\r\n` to `\n` and applies standalone `\r` carriage returns cleanly
    /// so progress bars don't leave hundreds of stale lines.
    nonisolated static func normalizeControlChars(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard unified.contains("\r") else { return unified }
        let lines = unified.components(separatedBy: "\n")
        return lines.map { line in
            let segments = line.components(separatedBy: "\r")
            return segments.last ?? line
        }.joined(separator: "\n")
    }
    
    private final class CachedANSIText {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }
    
    nonisolated(unsafe) private static let ansiCache: NSCache<NSString, CachedANSIText> = {
        let cache = NSCache<NSString, CachedANSIText>()
        cache.countLimit = 100
        return cache
    }()
    
    /// Renders basic ANSI SGR color/bold codes into a SwiftUI `AttributedString`
    /// while stripping unrecognized escape sequences.
    nonisolated static func renderANSI(_ raw: String, defaultColor: Color, useCache: Bool = false) -> AttributedString {
        let cacheKey = "\(String(describing: defaultColor))\u{0}\(raw)" as NSString
        if useCache, let cached = ansiCache.object(forKey: cacheKey) {
            return cached.value
        }
        
        let text = normalizeControlChars(raw)
        let pattern = #"\x1B\[([0-9;]*)m|\x1B\[[0-9;?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B[@-Z\\-_]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return AttributedString(text)
        }
        
        let nsText = text as NSString
        var result = AttributedString()
        var cursor = 0
        var activeColor = defaultColor
        var isBold = false
        
        func appendSlice(_ range: NSRange) {
            guard range.length > 0 else { return }
            var piece = AttributedString(nsText.substring(with: range))
            piece.foregroundColor = activeColor
            if isBold {
                piece.font = .system(size: 12, weight: .semibold, design: .monospaced)
            }
            result.append(piece)
        }
        
        for match in regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) {
            appendSlice(NSRange(location: cursor, length: match.range.location - cursor))
            
            if match.range(at: 1).location != NSNotFound {
                let params = nsText.substring(with: match.range(at: 1))
                let codes = params.isEmpty ? [0] : params.split(separator: ";").compactMap { Int($0) }
                for code in codes {
                    switch code {
                    case 0:
                        activeColor = defaultColor
                        isBold = false
                    case 1:
                        isBold = true
                    case 22:
                        isBold = false
                    case 30, 90:
                        activeColor = Color(white: 0.45)
                    case 31, 91:
                        activeColor = Color.red.opacity(0.92)
                    case 32, 92:
                        activeColor = Color.green.opacity(0.92)
                    case 33, 93:
                        activeColor = Color.yellow.opacity(0.92)
                    case 34, 94:
                        activeColor = Color.blue.opacity(0.92)
                    case 35, 95:
                        activeColor = Color.purple.opacity(0.92)
                    case 36, 96:
                        activeColor = Color.cyan.opacity(0.92)
                    case 37, 97:
                        activeColor = .white
                    case 39:
                        activeColor = defaultColor
                    default:
                        break
                    }
                }
            }
            cursor = match.range.location + match.range.length
        }
        appendSlice(NSRange(location: cursor, length: nsText.length - cursor))
        if useCache {
            ansiCache.setObject(CachedANSIText(result), forKey: cacheKey)
        }
        return result
    }
    
    /// Decodes as much of `data` as forms complete UTF-8, leaving a trailing
    /// partial character (split across two reads) in `data` for the next chunk.
    nonisolated static func decodeUTF8Prefix(of data: inout Data) -> String {
        for trailing in 0...min(3, data.count) {
            let prefix = data.prefix(data.count - trailing)
            if let text = String(data: prefix, encoding: .utf8) {
                data = Data(data.suffix(trailing))
                return text
            }
        }
        // Not valid UTF-8 at all (binary output): decode lossily and move on.
        let text = String(decoding: data, as: UTF8.self)
        data = Data()
        return text
    }
    
    nonisolated static func unquoted(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" else {
            return text.replacingOccurrences(of: "\\ ", with: " ")
        }
        return String(text.dropFirst().dropLast())
    }
    
    private func handleChangeDirectory(_ target: String, prompt: String, originalCommand: String) {
        var newURL = currentDirectory
        if target.isEmpty || target == "~" {
            newURL = FileManager.default.homeDirectoryForCurrentUser
        } else if target.hasPrefix("~/") {
            let sub = target.dropFirst(2)
            newURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(sub))
        } else if target.hasPrefix("/") {
            newURL = URL(fileURLWithPath: target)
        } else {
            newURL = currentDirectory.appendingPathComponent(target)
        }
        
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: newURL.path, isDirectory: &isDir), isDir.boolValue {
            self.currentDirectory = newURL.standardizedFileURL
            entries.append(TerminalEntry(prompt: prompt, command: originalCommand, output: "", exitCode: 0))
        } else {
            entries.append(TerminalEntry(prompt: prompt, command: originalCommand, output: "cd: no such file or directory: \(target)", exitCode: 1))
        }
    }
    
    public func navigateHistory(up: Bool) {
        guard !commandHistory.isEmpty else { return }
        if up {
            if historyIndex == -1 {
                historyIndex = commandHistory.count - 1
            } else if historyIndex > 0 {
                historyIndex -= 1
            }
        } else {
            if historyIndex != -1 && historyIndex < commandHistory.count - 1 {
                historyIndex += 1
            } else {
                historyIndex = -1
                commandInput = ""
                return
            }
        }
        
        if historyIndex >= 0 && historyIndex < commandHistory.count {
            commandInput = commandHistory[historyIndex]
        }
    }
}
