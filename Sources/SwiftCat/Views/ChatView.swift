import SwiftUI
import AppKit

public struct ChatView: View {
    @Binding var conversation: Conversation?
    var isGenerating: Bool
    @ObservedObject var agentManager: AgentManager
    @ObservedObject var llmService: LLMService
    var onRunCommand: ((String) -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil
    var onEditUserMessage: ((ChatMessage) -> Void)? = nil
    var onSuggestionClick: (String) -> Void
    
    /// True while the view is scrolled to (or near) the end, so new text keeps it
    /// there. Scrolling up to read turns it off until the user returns to the bottom.
    @State private var isPinnedToBottom = true
    
    private struct ScrollMetrics: Equatable {
        var bottomGap: CGFloat
        var contentHeight: CGFloat
    }
    
    public var body: some View {
        ZStack {
            SiriColors.background
                .ignoresSafeArea()
            
            if let convo = conversation, !convo.messages.isEmpty {
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottomTrailing) {
                        ScrollView {
                            LazyVStack(spacing: 24) {
                                ForEach(convo.messages) { message in
                                    let isLast = message.id == convo.messages.last?.id
                                    messageRow(message, isStreamingThis: isLast && isGenerating)
                                        .id(message.id)
                                }
                            }
                            .padding(.horizontal, 36)
                            .padding(.top, 28)
                            .padding(.bottom, 36)
                        }
                        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                            ScrollMetrics(
                                bottomGap: geometry.contentSize.height - geometry.visibleRect.maxY,
                                contentHeight: geometry.contentSize.height
                            )
                        } action: { old, new in
                            // Only a scroll (content height unchanged) tells us what the user
                            // wants; growth from streaming text must not unpin the view.
                            if abs(new.contentHeight - old.contentHeight) < 0.5 {
                                isPinnedToBottom = new.bottomGap < 60
                            }
                        }
                        .onAppear {
                            if let lastID = convo.messages.last?.id {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                        .onChange(of: convo.id) {
                            isPinnedToBottom = true
                            if let lastID = convo.messages.last?.id {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                        .onChange(of: convo.messages.count) {
                            // A new message (the user just sent one) always jumps to the end.
                            isPinnedToBottom = true
                            if let lastID = convo.messages.last?.id {
                                withAnimation(SwiftCatAnimations.spring) {
                                    proxy.scrollTo(lastID, anchor: .bottom)
                                }
                            }
                        }
                        .onChange(of: convo.messages.last?.content) {
                            if isPinnedToBottom, let lastID = convo.messages.last?.id {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                        .onChange(of: convo.messages.last?.reasoning) {
                            if isPinnedToBottom, let lastID = convo.messages.last?.id {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                        
                        if !isPinnedToBottom, let lastID = convo.messages.last?.id {
                            Button(action: {
                                isPinnedToBottom = true
                                withAnimation(SwiftCatAnimations.spring) {
                                    proxy.scrollTo(lastID, anchor: .bottom)
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.down")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("Bottom")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(SiriColors.textPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(white: 0.16).opacity(0.95))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                                )
                                .shadow(color: Color.black.opacity(0.35), radius: 6, y: 2)
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 24)
                            .padding(.bottom, 16)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        }
                    }
                }
            } else {
                EmptyChatStateView(
                    agentManager: agentManager,
                    selectedModel: llmService.selectedModel,
                    onSuggestionClick: onSuggestionClick
                )
            }
        }
    }
    
    private func messageRow(_ message: ChatMessage, isStreamingThis: Bool) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            // Assistant Model Label
            if message.role == .assistant {
                let isApple = message.modelName?.contains("Apple") == true
                let isLocal = !isApple && (llmService.availableModels.first(where: { $0.name == message.modelName })?.isLocalServer
                    ?? (message.modelName?.contains("Local") == true))
                
                HStack(spacing: 6) {
                    Image(systemName: isApple ? "apple.logo" : (isLocal ? "cpu" : "sparkles"))
                        .font(.system(size: 11))
                        .foregroundColor(isApple ? .cyan : (isLocal ? .green : .purple))
                    
                    Text((message.modelName ?? "Assistant").replacingOccurrences(of: " (Local)", with: "").replacingOccurrences(of: "(Local)", with: ""))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(SiriColors.textSecondary)
                }
                .padding(.leading, 2)
            }
            
            // Content
            if message.role == .user {
                UserMessageBubble(
                    message: message,
                    isGenerating: isGenerating,
                    onEdit: { onEditUserMessage?(message) }
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    // 1. Thinking / Reasoning Block
                    if let reasoning = message.reasoning, !reasoning.isEmpty {
                        ThinkingBlockView(
                            reasoning: reasoning,
                            duration: message.reasoningDuration,
                            isCurrentlyThinking: isStreamingThis && message.content.isEmpty
                        )
                    } else if isStreamingThis && message.content.isEmpty {
                        ThinkingLiveIndicator()
                    }
                    
                    // 2. Assistant Response Content
                    if !message.content.isEmpty {
                        AssistantMessageContentView(
                            content: message.content,
                            agentManager: agentManager,
                            isStreaming: isStreamingThis,
                            onRunCommand: onRunCommand
                        )
                    }
                    
                    // 3. Assistant footer action bar (copy markdown, word count)
                    if !isStreamingThis && !message.content.isEmpty {
                        MessageFooterBar(
                            content: message.content,
                            onRegenerate: onRegenerate
                        )
                    }
                }
                .padding(.leading, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}

public struct HairlineSpinner: View {
    @State private var isSpinning = false
    
    public init() {}
    
    public var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [Color.white.opacity(0.12), Color.white.opacity(0.85)],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
            )
            .frame(width: 10, height: 10)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .animation(
                Animation.linear(duration: 0.9)
                    .repeatForever(autoreverses: false),
                value: isSpinning
            )
            .onAppear {
                isSpinning = true
            }
    }
}

public struct ShimmeringText: View {
    let text: String
    @State private var phase: CGFloat = -0.8
    
    public init(_ text: String) {
        self.text = text
    }
    
    public var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(Color.white.opacity(0.40))
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.white.opacity(0.70),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: max(20, geo.size.width * 0.5))
                    .offset(x: phase * geo.size.width * 1.5)
                }
                .mask(
                    Text(text)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                )
            )
            .onAppear {
                withAnimation(Animation.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1.0
                }
            }
    }
}

public struct TerminalCursorView: View {
    @State private var isVisible = true
    
    public init() {}
    
    public var body: some View {
        Text("▋")
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(Color.white.opacity(isVisible ? 0.75 : 0.0))
            .animation(
                Animation.easeInOut(duration: 0.45)
                    .repeatForever(autoreverses: true),
                value: isVisible
            )
            .onAppear {
                isVisible = false
            }
    }
}

public struct ThinkingBlockView: View {
    let reasoning: String
    let duration: TimeInterval?
    let isCurrentlyThinking: Bool
    
    @State private var isExpanded: Bool = true
    @State private var isHovering: Bool = false
    @State private var isCopied: Bool = false
    
    public init(reasoning: String, duration: TimeInterval? = nil, isCurrentlyThinking: Bool) {
        self.reasoning = reasoning
        self.duration = duration
        self.isCurrentlyThinking = isCurrentlyThinking
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header button with collapse/expand and copy
            HStack(spacing: 8) {
                Button(action: {
                    withAnimation(SwiftCatAnimations.spring) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 6) {
                        if isCurrentlyThinking {
                            HairlineSpinner()
                            ShimmeringText("Thinking...")
                            
                            if let d = duration, d > 0.05 {
                                Text(String(format: "(%.1fs)", d))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Color.white.opacity(0.35))
                            }
                        } else {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(Color.white.opacity(0.35))
                                .frame(width: 8)
                            
                            Text("Thinking...")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(Color.white.opacity(0.40))
                            
                            if let d = duration, d > 0.05 {
                                Text(String(format: "· %.1fs", d))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Color.white.opacity(0.30))
                            }
                            
                            let wordCount = reasoning.split(whereSeparator: { $0.isWhitespace }).count
                            if wordCount > 0 {
                                Text("· \(wordCount) words")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Color.white.opacity(0.25))
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                
                // Copy reasoning icon on hover
                if isHovering && !reasoning.isEmpty {
                    Button(action: copyReasoning) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundColor(isCopied ? .green : Color.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .onHover { hovering in
                isHovering = hovering
            }
            
            // Collapsible thought stream
            if isExpanded {
                HStack(alignment: .top, spacing: 10) {
                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 1.2)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text(reasoning.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.60))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                        
                        if isCurrentlyThinking {
                            TerminalCursorView()
                        } else {
                            Text("...done thinking.")
                                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                                .foregroundColor(Color.white.opacity(0.35))
                                .padding(.top, 2)
                        }
                    }
                }
                .padding(.leading, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.leading, 2)
        .onAppear {
            if isCurrentlyThinking {
                isExpanded = true
            }
        }
    }
    
    private func copyReasoning() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reasoning, forType: .string)
        withAnimation(SwiftCatAnimations.spring) { isCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(SwiftCatAnimations.spring) { isCopied = false }
        }
    }
}

public struct ThinkingLiveIndicator: View {
    public var body: some View {
        HStack(spacing: 6) {
            HairlineSpinner()
            ShimmeringText("Thinking...")
        }
        .padding(.leading, 2)
        .padding(.vertical, 4)
    }
}

public struct MessageFooterBar: View {
    let content: String
    var onRegenerate: (() -> Void)? = nil
    
    @State private var isCopied = false
    
    var wordCount: Int {
        content.split(whereSeparator: \.isWhitespace).count
    }
    
    public var body: some View {
        HStack(spacing: 12) {
            Button(action: copyMarkdown) {
                HStack(spacing: 4) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                    Text(isCopied ? "Copied" : "Copy Markdown")
                        .font(.system(size: 11))
                }
                .foregroundColor(isCopied ? .green : SiriColors.textSecondary)
            }
            .buttonStyle(.plain)
            
            if let retry = onRegenerate {
                Button(action: {
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                    retry()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                        Text("Regenerate")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(SiriColors.textSecondary)
                }
                .buttonStyle(.plain)
            }
            
            Spacer()
            
            Text("\(wordCount) words")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(SiriColors.textSecondary.opacity(0.7))
        }
        .padding(.top, 4)
    }
    
    private func copyMarkdown() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        withAnimation(SwiftCatAnimations.spring) { isCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(SwiftCatAnimations.spring) { isCopied = false }
        }
    }
}

public struct UserMessageBubble: View {
    let message: ChatMessage
    let isGenerating: Bool
    var onEdit: (() -> Void)? = nil
    
    @State private var isHovered = false
    @State private var isCopied = false
    
    public var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(message.content)
                .font(.system(size: 14))
                .foregroundColor(SiriColors.textPrimary)
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(Color(white: 0.17))
                .cornerRadius(16)
                .textSelection(.enabled)
            
            if isHovered {
                HStack(spacing: 10) {
                    Button(action: {
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.content, forType: .string)
                        withAnimation(SwiftCatAnimations.spring) { isCopied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(SwiftCatAnimations.spring) { isCopied = false }
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 9))
                            Text(isCopied ? "Copied" : "Copy")
                                .font(.system(size: 10.5))
                        }
                        .foregroundColor(isCopied ? .green : SiriColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    
                    if !isGenerating, let onEdit {
                        Button(action: {
                            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                            onEdit()
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 9))
                                Text("Edit")
                                    .font(.system(size: 10.5))
                            }
                            .foregroundColor(SiriColors.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, 4)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(SwiftCatAnimations.smooth) {
                isHovered = hovering
            }
        }
    }
}

public struct AssistantMessageContentView: View {
    let content: String
    @ObservedObject var agentManager: AgentManager
    var isStreaming: Bool = false
    var onRunCommand: ((String) -> Void)? = nil
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let blocks = ContentBlockParser.parse(content, useCache: !isStreaming)
            let fileBlocks: [(path: String, content: String)] = blocks.compactMap {
                if case .fileWrite(let path, let fileContent) = $0 {
                    return (path, fileContent)
                }
                return nil
            }
            let pendingFiles = fileBlocks.filter {
                agentManager.readFileContent(relativePath: $0.path) != $0.content
            }
            
            if !isStreaming && fileBlocks.count >= 2 {
                HStack(spacing: 8) {
                    Image(systemName: pendingFiles.isEmpty ? "checkmark.circle.fill" : "square.stack.3d.up")
                        .font(.system(size: 11))
                        .foregroundColor(pendingFiles.isEmpty ? .green : .cyan)
                    
                    Text(pendingFiles.isEmpty ? "All \(fileBlocks.count) files applied" : "\(fileBlocks.count) files proposed")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(SiriColors.textSecondary)
                    
                    Spacer()
                    
                    if !pendingFiles.isEmpty {
                        Button(action: {
                            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                            agentManager.writeFiles(pendingFiles)
                        }) {
                            Text("Apply All (\(pendingFiles.count))")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.04))
                .cornerRadius(7)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(pendingFiles.isEmpty ? Color.green.opacity(0.25) : SiriColors.border, lineWidth: 1)
                )
            }
            
            ForEach(0..<blocks.count, id: \.self) { idx in
                let block = blocks[idx]
                let isLastBlock = idx == blocks.count - 1
                switch block {
                case .text(let str):
                    if !str.isEmpty {
                        HStack(alignment: .bottom, spacing: 2) {
                            Text(MarkdownRenderer.render(str, useCache: !isStreaming))
                                .font(.system(size: 14, weight: .regular))
                                .foregroundColor(SiriColors.textPrimary)
                                .lineSpacing(5)
                                .textSelection(.enabled)
                            
                            if isStreaming && isLastBlock {
                                MinimalCursorView()
                                    .padding(.bottom, 2)
                            }
                        }
                    } else if isStreaming && isLastBlock {
                        MinimalCursorView()
                    }
                case .code(let lang, let code):
                    CodeBlockView(language: lang, code: code, onRunCommand: onRunCommand)
                case .fileWrite(let path, let fileContent):
                    FileWriteBlockView(path: path, content: fileContent, agentManager: agentManager)
                case .fileRead(let path):
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 10.5))
                            .foregroundColor(.cyan.opacity(0.85))
                        Text("Read")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(SiriColors.textSecondary)
                        Text(path)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(SiriColors.textPrimary.opacity(0.85))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                }
            }
        }
    }
}

public struct CodeBlockView: View {
    let language: String
    let code: String
    var onRunCommand: ((String) -> Void)? = nil
    
    @State private var isCopied = false
    @State private var isExecuted = false
    
    var isShellCommand: Bool {
        let l = language.lowercased()
        return l == "bash" || l == "sh" || l == "zsh" || l == "shell" || l == "terminal"
    }
    
    var lines: [String] {
        code.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Minimalist Code Header
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text(language.isEmpty ? "code" : language.lowercased())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.85))
                    
                    Text("· \(lines.count) lines")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.35))
                }
                
                Spacer()
                
                // 'Run in Terminal' Button
                if isShellCommand, let onRun = onRunCommand {
                    Button(action: {
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                        onRun(code)
                        withAnimation(SwiftCatAnimations.spring) {
                            isExecuted = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation(SwiftCatAnimations.spring) { isExecuted = false }
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: isExecuted ? "checkmark" : "play.fill")
                                .font(.system(size: 9))
                            Text(isExecuted ? "Running" : "Run in Terminal")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(isExecuted ? .green : .cyan)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                    .help("Execute directly in the integrated terminal")
                }
                
                Button(action: copyToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(isCopied ? "Copied" : "Copy")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(isCopied ? .green : SiriColors.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.04))
            
            // Code Content with Line Numbers and Syntax Highlighting
            ScrollView(.horizontal, showsIndicators: false) {
                let lineNumbersText = (1...max(1, lines.count)).map(String.init).joined(separator: "\n")
                HStack(alignment: .top, spacing: 10) {
                    // Single Text column matching code font & lineSpacing exactly so lines never drift.
                    Text(lineNumbersText)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .lineSpacing(3)
                        .multilineTextAlignment(.trailing)
                        .foregroundColor(Color.white.opacity(0.22))
                        .frame(minWidth: 20, alignment: .trailing)
                        .padding(.vertical, 10)
                        .padding(.leading, 10)
                    
                    // Hairline divider
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 1)
                        .padding(.vertical, 4)
                    
                    // Syntax Highlighted Code
                    Text(SyntaxHighlighter.highlight(code: code.trimmingCharacters(in: .newlines), language: language))
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .lineSpacing(3)
                        .padding(.vertical, 10)
                        .padding(.trailing, 14)
                        .textSelection(.enabled)
                }
            }
        }
        .background(Color(red: 0.04, green: 0.04, blue: 0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(SiriColors.border, lineWidth: 1)
        )
    }
    
    private func copyToClipboard() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        withAnimation(SwiftCatAnimations.spring) { isCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(SwiftCatAnimations.spring) { isCopied = false }
        }
    }
}

public struct FileWriteBlockView: View {
    let path: String
    let content: String
    @ObservedObject var agentManager: AgentManager
    
    @State private var isApplied: Bool = false
    @State private var showDiff: Bool = false
    @State private var applyError: String?
    // Computed once per proposal instead of on every render (file read + LCS diff).
    @State private var diffLines: [DiffLine] = []
    
    var lineCount: Int {
        content.components(separatedBy: "\n").count
    }
    
    var targetURL: URL? {
        try? agentManager.resolveWorkspaceURL(for: path)
    }
    
    var fileAlreadyExists: Bool {
        guard let target = targetURL else { return false }
        return FileManager.default.fileExists(atPath: target.path)
    }
    
    private var snapshot: FileBackupSnapshot? {
        agentManager.backupSnapshot(for: path, proposedContent: content)
    }
    
    private var isNewFile: Bool {
        if let snapshot { return !snapshot.existed }
        return !fileAlreadyExists
    }
    
    private func refreshDiff() {
        let disk = agentManager.readFileContent(relativePath: path)
        // "Applied" reflects what is really on disk, not just the auto-apply setting.
        isApplied = (disk == content)
        if showDiff || !isNewFile {
            let baseline = (isApplied ? snapshot?.content : disk) ?? ""
            diffLines = DiffEngine.computeDiff(oldText: baseline, newText: content)
        } else {
            diffLines = []
        }
    }
    
    var diffStats: (added: Int, removed: Int) {
        var a = 0, r = 0
        for l in diffLines {
            if l.kind == .added { a += 1 }
            else if l.kind == .removed { r += 1 }
        }
        return (a, r)
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: isNewFile ? "doc.badge.plus" : "pencil.line")
                    .foregroundColor(isNewFile ? .green : .cyan)
                    .font(.system(size: 12))
                
                Text(path)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(SiriColors.textPrimary)
                
                // Status badge
                Text(isNewFile ? "New File" : "Modified")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(isNewFile ? .green : .cyan)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background((isNewFile ? Color.green : Color.cyan).opacity(0.12))
                    .cornerRadius(4)
                
                // Diff stats
                if !isNewFile {
                    HStack(spacing: 3) {
                        Text("+\(diffStats.added)")
                            .foregroundColor(.green)
                        Text("-\(diffStats.removed)")
                            .foregroundColor(.red.opacity(0.9))
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                } else {
                    Text("\(lineCount) lines")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(SiriColors.textSecondary)
                }
                
                Spacer()
                
                // Mode switch: Code | Diff
                HStack(spacing: 2) {
                    Button(action: { withAnimation(SwiftCatAnimations.spring) { showDiff = false } }) {
                        Text("Code")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(!showDiff ? SiriColors.textPrimary : SiriColors.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(!showDiff ? Color.white.opacity(0.12) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { withAnimation(SwiftCatAnimations.spring) { showDiff = true } }) {
                        Text("Diff")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(showDiff ? SiriColors.textPrimary : SiriColors.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(showDiff ? Color.white.opacity(0.12) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(2)
                .background(Color.white.opacity(0.04))
                .cornerRadius(5)
                
                // Apply or Applied Status
                if isApplied {
                    HStack(spacing: 6) {
                        Label("Applied", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.green)
                        
                        if snapshot != nil {
                            Button(action: revertChange) {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.system(size: 9))
                                    Text("Revert")
                                        .font(.system(size: 10.5, weight: .medium))
                                }
                                .foregroundColor(SiriColors.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                            .help("Restore previous file state")
                        }
                        
                        if let fileURL = targetURL {
                            Button(action: {
                                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                            }) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 11))
                                    .foregroundColor(SiriColors.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .help("Reveal in Finder")
                        }
                    }
                } else {
                    Button(action: applyChange) {
                        Text("Apply Changes")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.04))
            .cornerRadius(6)
            
            if let applyError {
                Label(applyError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.9))
                    .padding(.horizontal, 10)
            }
            
            // Content: Either full code or interactive line diff
            if showDiff {
                DiffViewer(diffLines: diffLines)
            } else {
                CodeBlockView(language: (path as NSString).pathExtension, code: content)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.02))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isApplied ? Color.green.opacity(0.3) : SiriColors.border, lineWidth: 1)
        )
        // Never write from here: with auto-apply on, merely scrolling an old chat
        // into view would overwrite newer files. Auto-apply runs once, when the reply completes.
        .onAppear(perform: refreshDiff)
        .onChange(of: content) { refreshDiff() }
        .onChange(of: showDiff) {
            if showDiff && diffLines.isEmpty {
                refreshDiff()
            }
        }
        .onChange(of: agentManager.writeGeneration) { refreshDiff() }
    }
    
    private func applyChange() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        do {
            try agentManager.writeFile(relativePath: path, content: content)
            applyError = nil
            withAnimation(SwiftCatAnimations.spring) {
                isApplied = true
            }
        } catch {
            applyError = error.localizedDescription
        }
    }
    
    private func revertChange() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        do {
            try agentManager.revertFile(relativePath: path, to: content)
            applyError = nil
            withAnimation(SwiftCatAnimations.spring) {
                isApplied = false
            }
        } catch {
            applyError = error.localizedDescription
        }
    }
}

public struct EmptyChatStateView: View {
    @ObservedObject var agentManager: AgentManager
    let selectedModel: ConfiguredModel
    var onSuggestionClick: (String) -> Void
    
    private var suggestions: [String] {
        if agentManager.currentWorkspaceURL != nil {
            return [
                "Объясни архитектуру проекта и ключевые модули",
                "Проверь последние изменения git и найди потенциальные баги",
                "Предложи улучшения производительности и рефакторинг"
            ]
        }
        return [
            "Напиши чистый SwiftUI компонент с анимацией",
            "Помоги разобраться с async/await и MainActor в Swift 6",
            "Объясни алгоритм и сложность кода"
        ]
    }
    
    public var body: some View {
        VStack(spacing: 18) {
            Spacer()
            
            Image(systemName: "swift")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.white, Color(white: 0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            VStack(spacing: 4) {
                Text("SwiftCat")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(SiriColors.textPrimary)
                
                Text(agentManager.currentWorkspaceURL.map { "Workspace: \($0.lastPathComponent)" } ?? "Model: \(selectedModel.name)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(SiriColors.textSecondary)
            }
            
            if agentManager.currentWorkspaceURL == nil {
                Button(action: { agentManager.selectWorkspaceFolder() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 11))
                        Text("Attach Project Folder (⇧⌘O)")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundColor(.cyan)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.cyan.opacity(0.10))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.cyan.opacity(0.25), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { prompt in
                    Button(action: { onSuggestionClick(prompt) }) {
                        HStack {
                            Text(prompt)
                                .font(.system(size: 12.5))
                                .foregroundColor(Color.white.opacity(0.82))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10))
                                .foregroundColor(SiriColors.textSecondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .frame(maxWidth: 440)
                        .background(Color.white.opacity(0.035))
                        .cornerRadius(9)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(SiriColors.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Text("Type `/` for commands  ·  `@` to attach a file  ·  `⌘J` for terminal")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(SiriColors.textSecondary.opacity(0.75))
            
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

public struct DiffViewer: View {
    let diffLines: [DiffLine]
    
    public var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(diffLines) { line in
                    HStack(spacing: 8) {
                        // Old line number
                        Text(line.oldLineNum != nil ? "\(line.oldLineNum!)" : " ")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(SiriColors.textSecondary.opacity(0.5))
                            .frame(width: 24, alignment: .trailing)
                        
                        // New line number
                        Text(line.newLineNum != nil ? "\(line.newLineNum!)" : " ")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(SiriColors.textSecondary.opacity(0.5))
                            .frame(width: 24, alignment: .trailing)
                        
                        // Marker (+, -, space)
                        Text(lineMarker(line.kind))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(markerColor(line.kind))
                            .frame(width: 12)
                        
                        // Line content
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(lineColor(line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(lineBackground(line.kind))
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 280)
        .background(Color(red: 0.05, green: 0.05, blue: 0.06))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(SiriColors.border, lineWidth: 1)
        )
    }
    
    private func lineMarker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "-"
        case .same: return " "
        }
    }
    
    private func markerColor(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return .green
        case .removed: return .red
        case .same: return .clear
        }
    }
    
    private func lineColor(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.95)
        case .removed: return Color.red.opacity(0.90)
        case .same: return Color(white: 0.85)
        }
    }
    
    private func lineBackground(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.12)
        case .removed: return Color.red.opacity(0.12)
        case .same: return Color.clear
        }
    }
}
