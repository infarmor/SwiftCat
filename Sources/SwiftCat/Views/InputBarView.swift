import SwiftUI

public struct SlashCommandItem: Identifiable {
    public let id = UUID()
    public let name: String
    public let description: String
    public let icon: String
}

public struct InputBarView: View {
    @Binding var inputText: String
    var isGenerating: Bool
    @ObservedObject var agentManager: AgentManager
    @ObservedObject var llmService: LLMService
    var onSend: () -> Void
    var onStop: () -> Void
    var onClearChat: (() -> Void)? = nil
    var focusTrigger: UUID = UUID()
    
    @FocusState private var isFieldFocused: Bool
    @State private var selectedSuggestionIndex: Int = 0
    @State private var dismissedPopupForText: String? = nil
    
    private var slashCommands: [SlashCommandItem] {
        [
            SlashCommandItem(name: "/git", description: "Review git status, diff and branch", icon: "arrow.triangle.branch"),
            SlashCommandItem(name: "/diff", description: "Inspect uncommitted code diffs", icon: "plus.forwardslash.minus"),
            SlashCommandItem(name: "/files", description: "Outline workspace file structure", icon: "folder"),
            SlashCommandItem(name: "/agent", description: "Toggle autonomous Agent mode", icon: "bolt"),
            SlashCommandItem(name: "/clear", description: "Clear current conversation", icon: "trash")
        ]
    }
    
    private var filteredSlashCommands: [SlashCommandItem] {
        guard dismissedPopupForText != inputText else { return [] }
        guard inputText.hasPrefix("/"), !inputText.contains(" ") else { return [] }
        let query = inputText.lowercased()
        if query == "/" { return slashCommands }
        return slashCommands.filter { $0.name.hasPrefix(query) }
    }
    
    /// Extracts the trailing `@query` token if the user is currently typing a file mention.
    private var activeAtMentionQuery: String? {
        guard dismissedPopupForText != inputText else { return nil }
        guard !inputText.hasPrefix("/") else { return nil }
        guard let atIndex = inputText.lastIndex(of: "@") else { return nil }
        if atIndex > inputText.startIndex {
            let prev = inputText[inputText.index(before: atIndex)]
            guard prev.isWhitespace else { return nil }
        }
        let afterAt = inputText[inputText.index(after: atIndex)...]
        guard !afterAt.contains(where: { $0.isWhitespace }) else { return nil }
        return String(afterAt)
    }
    
    private var attachedMentions: [String] {
        guard agentManager.currentWorkspaceURL != nil else { return [] }
        let pattern = #"(?:^|\s)@([^\s,;:!?\"'`()\[\]{}]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsText = inputText as NSString
        var seen = Set<String>()
        var result: [String] = []
        let activeTrailing = activeAtMentionQuery
        for match in regex.matches(in: inputText, options: [], range: NSRange(location: 0, length: nsText.length)) {
            guard match.numberOfRanges >= 2 else { continue }
            let token = nsText.substring(with: match.range(at: 1))
            if token == activeTrailing { continue }
            let isKnown = agentManager.flatWorkspaceFiles.contains(where: {
                $0.path.caseInsensitiveCompare(token) == .orderedSame ||
                $0.name.caseInsensitiveCompare(token) == .orderedSame
            }) || agentManager.readFileContent(relativePath: token) != nil
            if isKnown && !seen.contains(token) {
                seen.insert(token)
                result.append(token)
            }
        }
        return result
    }
    
    private var filteredFileMentions: [WorkspaceItem] {
        guard let query = activeAtMentionQuery?.lowercased() else { return [] }
        let files = agentManager.flatWorkspaceFiles
        guard !files.isEmpty else { return [] }
        if query.isEmpty {
            return Array(files.prefix(7))
        }
        let exactPrefix = files.filter { $0.name.lowercased().hasPrefix(query) }
        let substringMatch = files.filter {
            !$0.name.lowercased().hasPrefix(query) &&
            ($0.name.lowercased().contains(query) || $0.path.lowercased().contains(query))
        }
        return Array((exactPrefix + substringMatch).prefix(7))
    }
    
    public var body: some View {
        VStack(spacing: 6) {
            // 1. Slash Command Auto-Suggestions Palette
            if !filteredSlashCommands.isEmpty && !isGenerating {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(filteredSlashCommands.enumerated()), id: \.element.id) { idx, cmd in
                        let isSelected = idx == min(selectedSuggestionIndex, max(0, filteredSlashCommands.count - 1))
                        Button(action: {
                            executeSlashCommand(cmd.name)
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: cmd.icon)
                                    .font(.system(size: 11))
                                    .foregroundColor(.cyan)
                                    .frame(width: 16)
                                
                                Text(cmd.name)
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                
                                Text("— \(cmd.description)")
                                    .font(.system(size: 11))
                                    .foregroundColor(SiriColors.textSecondary)
                                
                                Spacer()
                                
                                if isSelected {
                                    Text("↵")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(Color.white.opacity(0.35))
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(isSelected ? 0.09 : 0.02))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .onHover { isHovering in
                            if isHovering { selectedSuggestionIndex = idx }
                        }
                    }
                }
                .padding(6)
                .background(Color(red: 0.08, green: 0.08, blue: 0.10))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .padding(.horizontal, 28)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            
            // 2. @file Mention Auto-Suggestions Palette
            if !filteredFileMentions.isEmpty && !isGenerating {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(filteredFileMentions.enumerated()), id: \.element.id) { idx, item in
                        let isSelected = idx == min(selectedSuggestionIndex, max(0, filteredFileMentions.count - 1))
                        Button(action: {
                            insertFileMention(item)
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 11))
                                    .foregroundColor(.cyan)
                                    .frame(width: 16)
                                
                                Text(item.name)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.white)
                                
                                if item.path != item.name {
                                    Text(item.path)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundColor(SiriColors.textSecondary)
                                        .lineLimit(1)
                                }
                                
                                Spacer()
                                
                                Text(item.size)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Color.white.opacity(0.30))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(isSelected ? 0.09 : 0.02))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .onHover { isHovering in
                            if isHovering { selectedSuggestionIndex = idx }
                        }
                    }
                }
                .padding(6)
                .background(Color(red: 0.08, green: 0.08, blue: 0.10))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .padding(.horizontal, 28)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            
            // Attached @file chips
            if !attachedMentions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachedMentions, id: \.self) { mention in
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 9))
                                    .foregroundColor(.cyan)
                                Text((mention as NSString).lastPathComponent)
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundColor(SiriColors.textPrimary)
                                Button(action: { removeMention(mention) }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(SiriColors.textSecondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.cyan.opacity(0.10))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.cyan.opacity(0.22), lineWidth: 1)
                            )
                            .help(mention)
                        }
                    }
                    .padding(.horizontal, 28)
                }
                .transition(.opacity)
            }
            
            // Minimalist Workspace Indicator
            if let workspace = agentManager.currentWorkspaceURL {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundColor(SiriColors.textSecondary)
                    
                    Text(workspace.lastPathComponent)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(SiriColors.textSecondary)
                    
                    if agentManager.isAgentModeEnabled {
                        Text("AGENT")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.cyan.opacity(0.12))
                            .cornerRadius(3)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        withAnimation(SwiftCatAnimations.spring) {
                            agentManager.clearWorkspace()
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9))
                            .foregroundColor(SiriColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.04))
                .cornerRadius(8)
                .padding(.horizontal, 28)
                .transition(.opacity)
            }
            
            // Minimalist Capsule
            HStack(alignment: .bottom, spacing: 10) {
                // '+' button with menu
                Menu {
                    Button(action: {
                        withAnimation(SwiftCatAnimations.spring) {
                            agentManager.selectWorkspaceFolder()
                        }
                    }) {
                        Label("Attach Project Folder", systemImage: "folder")
                    }
                    
                    Toggle(isOn: $agentManager.isAgentModeEnabled.animation(SwiftCatAnimations.spring)) {
                        Label("Agent Mode", systemImage: "bolt")
                    }
                    
                    if agentManager.currentWorkspaceURL != nil {
                        Button(role: .destructive, action: {
                            withAnimation(SwiftCatAnimations.spring) {
                                agentManager.clearWorkspace()
                            }
                        }) {
                            Label("Disconnect Workspace", systemImage: "xmark")
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(SiriColors.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.05))
                        .clipShape(Circle())
                }
                .menuStyle(.borderlessButton)
                
                // Text input
                // Grows up to 8 lines; Return sends, Option-Return inserts a line break.
                TextField("Ask SwiftCat (type / for commands or @ for files)...", text: $inputText, axis: .vertical)
                    .lineLimit(1...8)
                    .focused($isFieldFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(SiriColors.textPrimary)
                    .onChange(of: focusTrigger) {
                        isFieldFocused = true
                    }
                    .onChange(of: inputText) {
                        selectedSuggestionIndex = 0
                        if dismissedPopupForText != inputText {
                            dismissedPopupForText = nil
                        }
                    }
                    .onKeyPress(.escape) {
                        if activeSuggestionCount > 0 {
                            dismissedPopupForText = inputText
                            return .handled
                        } else if isGenerating {
                            onStop()
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.downArrow) {
                        let count = activeSuggestionCount
                        guard count > 0 else { return .ignored }
                        selectedSuggestionIndex = (selectedSuggestionIndex + 1) % count
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        let count = activeSuggestionCount
                        guard count > 0 else { return .ignored }
                        selectedSuggestionIndex = (selectedSuggestionIndex - 1 + count) % count
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        if !filteredFileMentions.isEmpty {
                            let idx = min(selectedSuggestionIndex, filteredFileMentions.count - 1)
                            insertFileMention(filteredFileMentions[idx])
                            return .handled
                        } else if !filteredSlashCommands.isEmpty {
                            let idx = min(selectedSuggestionIndex, filteredSlashCommands.count - 1)
                            executeSlashCommand(filteredSlashCommands[idx].name)
                            return .handled
                        }
                        return .ignored
                    }
                    .onSubmit {
                        if !filteredFileMentions.isEmpty && !isGenerating {
                            let idx = min(selectedSuggestionIndex, filteredFileMentions.count - 1)
                            insertFileMention(filteredFileMentions[idx])
                        } else if !filteredSlashCommands.isEmpty && !isGenerating {
                            let idx = min(selectedSuggestionIndex, filteredSlashCommands.count - 1)
                            executeSlashCommand(filteredSlashCommands[idx].name)
                        } else if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating {
                            if inputText.hasPrefix("/") {
                                executeSlashCommand(inputText)
                            } else {
                                onSend()
                            }
                        }
                    }
                
                // Model Selector Pill in Input Bar
                Menu {
                    ForEach(llmService.availableModels) { model in
                        Button(action: {
                            withAnimation(SwiftCatAnimations.spring) {
                                llmService.selectedModel = model
                            }
                        }) {
                            HStack {
                                Label(model.name, systemImage: model.iconName)
                                if llmService.selectedModel.id == model.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: llmService.selectedModel.iconName)
                            .font(.system(size: 10))
                            .foregroundColor(llmService.selectedModel.isAppleIntelligence ? .cyan : (llmService.selectedModel.isLocalServer ? .green : .purple))
                        
                        Text(llmService.selectedModel.name)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.70))
                            .lineLimit(1)
                        
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundColor(Color.white.opacity(0.35))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(10)
                }
                .menuStyle(.borderlessButton)
                
                // Action: Stop or Send
                if isGenerating {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 24, height: 24)
                            .background(Color.red.opacity(0.8))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                } else if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: {
                        if inputText.hasPrefix("/") {
                            executeSlashCommand(inputText)
                        } else {
                            onSend()
                        }
                    }) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.black)
                            .frame(width: 24, height: 24)
                            .background(Color.white)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(SiriColors.inputBarBackground)
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isFieldFocused ? Color.white.opacity(0.20) : SiriColors.border, lineWidth: 1)
                    .animation(SwiftCatAnimations.smooth, value: isFieldFocused)
            )
            .padding(.horizontal, 28)
            .padding(.bottom, 14)
        }
    }
    
    private var activeSuggestionCount: Int {
        if !filteredFileMentions.isEmpty { return filteredFileMentions.count }
        if !filteredSlashCommands.isEmpty { return filteredSlashCommands.count }
        return 0
    }
    
    private func insertFileMention(_ item: WorkspaceItem) {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        guard let atIndex = inputText.lastIndex(of: "@") else { return }
        let prefix = inputText[..<atIndex]
        inputText = "\(prefix)@\(item.path) "
        selectedSuggestionIndex = 0
    }
    
    private func removeMention(_ mention: String) {
        let escaped = NSRegularExpression.escapedPattern(for: mention)
        let pattern = #"(?:^|\s)@"# + escaped + #"(?=\s|$)"#
        let updated = inputText.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        inputText = updated.isEmpty ? "" : updated + " "
    }
    
    private func executeSlashCommand(_ raw: String) {
        let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        
        switch cmd {
        case "/clear":
            inputText = ""
            onClearChat?()
        case "/agent":
            withAnimation(SwiftCatAnimations.spring) {
                agentManager.isAgentModeEnabled.toggle()
            }
            inputText = ""
        case "/git":
            inputText = "Run `git status` and describe the current repository branch and pending changes."
            onSend()
        case "/diff":
            inputText = "Review all unstaged git diffs in the project and suggest clean improvements."
            onSend()
        case "/files":
            inputText = "Analyze the project file structure and list key modules."
            onSend()
        default:
            onSend()
        }
    }
}
