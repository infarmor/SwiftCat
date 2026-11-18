import Foundation

/// Splits a streamed model response into visible content and reasoning.
/// Reasoning arrives either as a dedicated delta field or inline between
/// `<think>` and `</think>` tags, which may be split across chunks.
public final class StreamChunkRouter: @unchecked Sendable {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private var inThinkTag = false
    private var buffer = ""
    private var fullReasoning = ""
    private var fullContent = ""

    public init() {}

    public func feedDelta(
        content: String?,
        reasoning: String?,
        onReasoning: (String) -> Void,
        onContent: (String) -> Void
    ) {
        if let r = reasoning, !r.isEmpty {
            fullReasoning += r
            onReasoning(r)
        }

        guard let c = content, !c.isEmpty else { return }
        buffer += c

        while !buffer.isEmpty {
            let tag = inThinkTag ? Self.closeTag : Self.openTag

            if let tagRange = buffer.range(of: tag) {
                emit(String(buffer[..<tagRange.lowerBound]), onReasoning: onReasoning, onContent: onContent)
                inThinkTag.toggle()
                buffer = String(buffer[tagRange.upperBound...])
            } else {
                // Hold back only a trailing fragment that could still become the tag
                // (e.g. "<thi"); everything before it is safe to show right away.
                let held = Self.partialTagSuffixLength(of: buffer, tag: tag)
                emit(String(buffer.dropLast(held)), onReasoning: onReasoning, onContent: onContent)
                buffer = String(buffer.suffix(held))
                break
            }
        }
    }

    public func finish(onReasoning: (String) -> Void, onContent: (String) -> Void) -> (content: String, reasoning: String) {
        emit(buffer, onReasoning: onReasoning, onContent: onContent)
        buffer = ""
        return (fullContent, fullReasoning)
    }

    private func emit(_ text: String, onReasoning: (String) -> Void, onContent: (String) -> Void) {
        guard !text.isEmpty else { return }
        if inThinkTag {
            fullReasoning += text
            onReasoning(text)
        } else {
            fullContent += text
            onContent(text)
        }
    }

    /// Length of the longest suffix of `text` that is a proper prefix of `tag`.
    private static func partialTagSuffixLength(of text: String, tag: String) -> Int {
        let maxLength = min(text.count, tag.count - 1)
        guard maxLength > 0 else { return 0 }
        for length in stride(from: maxLength, through: 1, by: -1) where text.hasSuffix(tag.prefix(length)) {
            return length
        }
        return 0
    }
}
