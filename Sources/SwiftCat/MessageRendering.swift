import SwiftUI
import Foundation

/// A piece of an assistant reply: prose, a code block, a file read pill, or a proposed file write.
public enum ContentBlock: Equatable, Sendable {
    case text(String)
    case code(language: String, code: String)
    case fileWrite(path: String, content: String)
    case fileRead(path: String)
}

public enum ContentBlockParser {
    private final class CachedBlocks {
        let value: [ContentBlock]
        init(_ value: [ContentBlock]) { self.value = value }
    }
    
    nonisolated(unsafe) private static let cache: NSCache<NSString, CachedBlocks> = {
        let cache = NSCache<NSString, CachedBlocks>()
        cache.countLimit = 150
        return cache
    }()
    
    // Groups: 1 = "file:" marker, 2 = info string, 3 = fenced body,
    //         4 = write_file path, 5 = write_file body,
    //         6 = read_file path
    private static let blockRegex = try! NSRegularExpression(
        pattern: #"```(file:)?([^\n`]*)\n([\s\S]*?)```|<write_file\s+path=["']([^"']+)["']\s*>([\s\S]*?)<\/write_file>|<read_file\s+path=["']([^"']+)["']\s*(?:\/>|>\s*<\/read_file>)"#,
        options: []
    )
    
    public static func parse(_ raw: String, useCache: Bool = true) -> [ContentBlock] {
        let cacheKey = raw as NSString
        if useCache, let cached = cache.object(forKey: cacheKey) {
            return cached.value
        }
        
        var result: [ContentBlock] = []
        let nsString = raw as NSString
        var lastIndex = 0
        
        for match in blockRegex.matches(in: raw, options: [], range: NSRange(location: 0, length: nsString.length)) {
            if match.range.location > lastIndex {
                result.append(.text(nsString.substring(with: NSRange(location: lastIndex, length: match.range.location - lastIndex))))
            }
            
            if match.range(at: 4).location != NSNotFound {
                let path = nsString.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces)
                result.append(.fileWrite(path: path, content: trimmedBody(nsString.substring(with: match.range(at: 5)))))
            } else if match.range(at: 6).location != NSNotFound {
                let path = nsString.substring(with: match.range(at: 6)).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty {
                    result.append(.fileRead(path: path))
                }
            } else {
                let info = nsString.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                let body = nsString.substring(with: match.range(at: 3))
                if match.range(at: 1).location != NSNotFound, !info.isEmpty {
                    result.append(.fileWrite(path: info, content: trimmedBody(body)))
                } else {
                    result.append(.code(language: info, code: body))
                }
            }
            
            lastIndex = match.range.location + match.range.length
        }
        
        if lastIndex < nsString.length {
            result.append(contentsOf: parseTail(nsString.substring(from: lastIndex)))
        }
        
        if useCache {
            cache.setObject(CachedBlocks(result), forKey: cacheKey)
        }
        return result
    }
    
    /// Same trimming as `AgentManager.extractFileProposals`, so the card shows
    /// (and compares against disk) exactly what would be written.
    private static func trimmedBody(_ body: String) -> String {
        body.trimmingCharacters(in: .newlines)
    }
    
    /// The text after the last complete block. While a reply is streaming (or was
    /// cut off) it can end in a block that has opened but not closed yet; show that
    /// as code right away instead of dumping raw fence or tag markup into the prose.
    private static func parseTail(_ tail: String) -> [ContentBlock] {
        let fence = tail.range(of: "```")
        let writeTag = tail.range(of: "<write_file")
        let readTag = tail.range(of: "<read_file")
        
        let earliestIndex = [fence?.lowerBound, writeTag?.lowerBound, readTag?.lowerBound]
            .compactMap { $0 }
            .min()
        
        guard let start = earliestIndex else {
            return [.text(tail)]
        }
        
        if let fence, fence.lowerBound == start {
            var blocks = textBlock(String(tail[..<fence.lowerBound]))
            let rest = tail[fence.upperBound...]
            if let newline = rest.firstIndex(of: "\n") {
                var info = String(rest[..<newline]).trimmingCharacters(in: .whitespaces)
                if info.hasPrefix("file:") {
                    info = (String(info.dropFirst(5)) as NSString).pathExtension
                }
                blocks.append(.code(language: info, code: String(rest[rest.index(after: newline)...])))
            }
            return blocks
        }
        
        if let writeTag, writeTag.lowerBound == start {
            var blocks = textBlock(String(tail[..<writeTag.lowerBound]))
            let rest = tail[writeTag.lowerBound...]
            if let close = rest.firstIndex(of: ">") {
                let header = String(rest[..<close])
                var language = ""
                if let pathStart = header.range(of: "path=")?.upperBound {
                    let path = header[pathStart...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                    language = (path as NSString).pathExtension
                }
                let body = String(rest[rest.index(after: close)...])
                blocks.append(.code(language: language, code: body.trimmingCharacters(in: .newlines)))
            }
            return blocks
        }
        
        if let readTag, readTag.lowerBound == start {
            return textBlock(String(tail[..<readTag.lowerBound]))
        }
        
        return [.text(tail)]
    }
    
    private static func textBlock(_ text: String) -> [ContentBlock] {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.text(text)]
    }
}

/// Renders the prose part of a reply: inline Markdown (bold, italic, `code`,
/// links), headings and bullet lists. Block-level layout stays line-based so
/// the text can keep streaming in character by character.
public enum MarkdownRenderer {
    private final class CachedResult {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }
    
    nonisolated(unsafe) private static let cache: NSCache<NSString, CachedResult> = {
        let cache = NSCache<NSString, CachedResult>()
        cache.countLimit = 300
        return cache
    }()
    
    private static let inlineOptions = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )
    
    /// - Parameter useCache: pass `false` for text that is still streaming, since
    ///   every intermediate string would otherwise be stored.
    public static func render(_ text: String, useCache: Bool = true) -> AttributedString {
        let key = text as NSString
        if useCache, let cached = cache.object(forKey: key) {
            return cached.value
        }
        
        var result = AttributedString()
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            result.append(renderLine(line))
            if index < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        
        if useCache {
            cache.setObject(CachedResult(result), forKey: key)
        }
        return result
    }
    
    private static func renderLine(_ line: String) -> AttributedString {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let indent = String(line.prefix(line.count - trimmed.count))
        
        // Heading: 1-6 "#" followed by a space
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
            var heading = inline(String(trimmed.dropFirst(hashes + 1)))
            let size: CGFloat = hashes == 1 ? 18 : (hashes == 2 ? 16 : 14.5)
            heading.font = .system(size: size, weight: .semibold)
            return heading
        }
        
        // Horizontal rule: "---", "***", or "___"
        let trimmedStr = trimmed.trimmingCharacters(in: .whitespaces)
        if trimmedStr.count >= 3,
           let first = trimmedStr.first,
           "-*_".contains(first),
           trimmedStr.allSatisfy({ $0 == first }) {
            var hr = AttributedString("────────────────────────")
            hr.foregroundColor = Color.white.opacity(0.20)
            return hr
        }
        
        // Blockquote: "> quote"
        if trimmed.first == ">" {
            let afterBracket = trimmed.dropFirst()
            let body = afterBracket.first == " " ? String(afterBracket.dropFirst()) : String(afterBracket)
            var prefix = AttributedString(indent + "▎ ")
            prefix.foregroundColor = Color.white.opacity(0.35)
            var quoted = inline(body)
            quoted.foregroundColor = Color.white.opacity(0.72)
            return prefix + quoted
        }
        
        // Bullet / task checklist: "- [ ] item", "- [x] item", "- item", "* item", "+ item"
        if let marker = trimmed.first, "-*+".contains(marker), trimmed.dropFirst().first == " " {
            let rest = trimmed.dropFirst(2)
            if rest.hasPrefix("[ ] ") {
                var box = AttributedString(indent + "[ ] ")
                box.font = .system(size: 12.5, weight: .semibold, design: .monospaced)
                box.foregroundColor = Color.white.opacity(0.45)
                return box + inline(String(rest.dropFirst(4)))
            } else if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") {
                var box = AttributedString(indent + "[x] ")
                box.font = .system(size: 12.5, weight: .semibold, design: .monospaced)
                box.foregroundColor = .green
                var body = inline(String(rest.dropFirst(4)))
                body.foregroundColor = Color.white.opacity(0.75)
                return box + body
            }
            return AttributedString(indent + "•  ") + inline(String(rest))
        }
        
        // Numbered list: "1. item" or "1) item"
        let digits = trimmed.prefix(while: { $0.isNumber })
        if !digits.isEmpty && digits.count <= 4 {
            let rest = trimmed.dropFirst(digits.count)
            if let punct = rest.first, (punct == "." || punct == ")"), rest.dropFirst().first == " " {
                var numPrefix = AttributedString("\(indent)\(digits)\(punct)  ")
                numPrefix.font = .system(size: 13.5, weight: .medium, design: .monospaced)
                return numPrefix + inline(String(rest.dropFirst(2)))
            }
        }
        
        return inline(line)
    }
    
    private static func inline(_ text: String) -> AttributedString {
        guard !text.isEmpty else { return AttributedString() }
        return (try? AttributedString(markdown: text, options: inlineOptions)) ?? AttributedString(text)
    }
}
