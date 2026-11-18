import SwiftUI
import Foundation

public struct SyntaxHighlighter {
    private static let keywords: Set<String> = [
        // Swift
        "import", "let", "var", "func", "struct", "class", "enum", "extension",
        "protocol", "init", "deinit", "return", "if", "else", "guard", "switch",
        "case", "default", "for", "while", "repeat", "in", "break", "continue",
        "try", "catch", "throw", "throws", "rethrows", "async", "await", "actor",
        "public", "private", "fileprivate", "internal", "open", "static", "mutating",
        "override", "final", "some", "any", "where", "self", "Self", "nil", "true", "false",
        // Python / JS / TS / Rust / Go / C++
        "def", "from", "as", "with", "yield", "lambda", "elif", "except", "finally",
        "const", "function", "export", "typeof", "interface", "type", "package",
        "readonly", "null", "undefined", "fn", "pub", "impl", "trait", "mod", "use",
        "crate", "match", "mut", "go", "defer", "chan", "select", "void", "sizeof",
        "namespace", "using", "template", "typename", "nullptr"
    ]
    
    /// Languages where `#` starts a comment (and `//` does not).
    private static let hashCommentLanguages: Set<String> = [
        "python", "py", "bash", "sh", "zsh", "shell", "terminal", "ruby", "rb",
        "yaml", "yml", "toml", "perl", "r", "makefile", "make", "dockerfile",
        "conf", "ini", "elixir", "powershell", "ps1", "fish", "nginx"
    ]
    
    private enum CommentStyle {
        case slash, hash, either
        
        var pattern: String {
            switch self {
            // "(?<!:)" keeps the "//" of an unquoted URL from starting a comment.
            case .slash: return #"/\*[\s\S]*?\*/|(?<!:)//.*"#
            case .hash: return #"#.*"#
            case .either: return #"/\*[\s\S]*?\*/|(?<!:)//.*|#.*"#
            }
        }
    }
    
    // One pass over the code: a string is matched before a comment marker inside it
    // can be, and keywords or numbers inside strings and comments stay untouched.
    private static func makeTokenRegex(_ style: CommentStyle) -> NSRegularExpression {
        let pattern = #"("""[\s\S]*?"""|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')|("# + style.pattern + #")|(\b\d+(?:\.\d+)?\b)|(\b[A-Za-z_][A-Za-z0-9_]*\b)"#
        // The pattern is a compile-time constant, so this cannot fail at runtime.
        return try! NSRegularExpression(pattern: pattern, options: [])
    }
    
    private static let slashRegex = makeTokenRegex(.slash)
    private static let hashRegex = makeTokenRegex(.hash)
    private static let eitherRegex = makeTokenRegex(.either)
    
    private final class CachedResult {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }
    
    // Views ask for the same block on every render; NSCache is thread-safe.
    nonisolated(unsafe) private static let cache: NSCache<NSString, CachedResult> = {
        let cache = NSCache<NSString, CachedResult>()
        cache.countLimit = 300
        return cache
    }()
    
    private static let plainColor = Color(white: 0.90)
    private static let stringColor = Color(red: 0.98, green: 0.74, blue: 0.52) // warm amber
    private static let commentColor = Color(white: 0.45)
    private static let numberColor = Color(red: 0.82, green: 0.68, blue: 0.98) // soft lilac
    private static let keywordColor = Color(red: 0.96, green: 0.46, blue: 0.65) // magenta/pink
    private static let typeColor = Color(red: 0.45, green: 0.85, blue: 0.78) // mint teal
    
    public static func highlight(code: String, language: String = "") -> AttributedString {
        let lang = language.lowercased()
        let cacheKey = "\(lang)\u{0}\(code)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached.value
        }
        
        let regex: NSRegularExpression
        if lang.isEmpty {
            regex = eitherRegex
        } else if hashCommentLanguages.contains(lang) {
            regex = hashRegex
        } else {
            regex = slashRegex
        }
        
        let nsCode = code as NSString
        var result = AttributedString()
        var cursor = 0
        
        func append(_ range: NSRange, color: Color) {
            guard range.length > 0 else { return }
            var piece = AttributedString(nsCode.substring(with: range))
            piece.foregroundColor = color
            result.append(piece)
        }
        
        for match in regex.matches(in: code, options: [], range: NSRange(location: 0, length: nsCode.length)) {
            append(NSRange(location: cursor, length: match.range.location - cursor), color: plainColor)
            
            let color: Color
            if match.range(at: 1).location != NSNotFound {
                color = stringColor
            } else if match.range(at: 2).location != NSNotFound {
                color = commentColor
            } else if match.range(at: 3).location != NSNotFound {
                color = numberColor
            } else {
                let word = nsCode.substring(with: match.range)
                if keywords.contains(word) {
                    color = keywordColor
                } else if word.first?.isUppercase == true {
                    color = typeColor
                } else {
                    color = plainColor
                }
            }
            append(match.range, color: color)
            cursor = match.range.location + match.range.length
        }
        append(NSRange(location: cursor, length: nsCode.length - cursor), color: plainColor)
        
        cache.setObject(CachedResult(result), forKey: cacheKey)
        return result
    }
}
