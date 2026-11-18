import SwiftUI

public struct ContentView: View {
    @StateObject private var llmService = LLMService.shared
    @StateObject private var agentManager = AgentManager()
    @StateObject private var terminalManager = TerminalManager()
    
    @State private var conversations: [Conversation] = []
    @State private var selectedConversationID: UUID?
    @State private var inputText: String = ""
    @State private var isGenerating: Bool = false
    @State private var showSettings: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var activeStreamTask: Task<Void, Never>? = nil
    @State private var pendingSaveTask: Task<Void, Never>? = nil
    @State private var placeholderConversationID: UUID? = nil
    @State private var focusTrigger: UUID = UUID()
    @State private var isSidebarVisible: Bool = true
    
    var selectedConversation: Binding<Conversation?> {
        Binding {
            if let id = selectedConversationID {
                return conversations.first(where: { $0.id == id })
            }
            return nil
        } set: { newVal in
            if let newVal = newVal, let idx = conversations.firstIndex(where: { $0.id == newVal.id }) {
                conversations[idx] = newVal
            }
        }
    }
    
    public var body: some View {
        HSplitView {
            // 1. Sidebar
            if isSidebarVisible {
                SidebarView(
                    conversations: $conversations,
                    selectedConversationID: $selectedConversationID,
                    llmService: llmService,
                    agentManager: agentManager,
                    terminalManager: terminalManager,
                    showSettings: $showSettings,
                    onInspectFile: { relativePath in
                        inputText = "Проанализируй файл \(relativePath) из проекта, объясни его назначение и логику."
                        sendMessage()
                    },
                    onAttachFile: { relativePath in
                        appendMention(relativePath)
                    }
                )
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 280)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            
            // 2. Main Chat Area
            VStack(spacing: 0) {
                // Top Header Toolbar
                HStack(spacing: 8) {
                    PanelToggleButton(
                        systemImage: "sidebar.leading",
                        isActive: isSidebarVisible,
                        helpText: "Toggle Sidebar (⌘\\)"
                    ) {
                        withAnimation(SwiftCatAnimations.spring) {
                            isSidebarVisible.toggle()
                        }
                    }
                    
                    Image(systemName: "swift")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.white, Color(white: 0.78)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Color.white.opacity(0.20), radius: 2)
                    
                    if let convo = selectedConversation.wrappedValue {
                        Text(convo.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(SiriColors.textPrimary)
                            .lineLimit(1)
                    } else {
                        Text("SwiftCat")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(SiriColors.textPrimary)
                    }
                    
                    Spacer()
                    
                    // Terminal Panel Toggle Button (Icon only with smooth animation)
                    TerminalIconButton(terminalManager: terminalManager)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(SiriColors.sidebarBackground)
                
                Divider()
                    .background(SiriColors.border)
                
                ChatView(
                    conversation: selectedConversation,
                    isGenerating: isGenerating,
                    agentManager: agentManager,
                    llmService: llmService,
                    onRunCommand: { cmd in
                        withAnimation(SwiftCatAnimations.spring) {
                            terminalManager.isPanelVisible = true
                        }
                        terminalManager.executeExternalCommand(cmd)
                    },
                    onRegenerate: regenerateLastResponse,
                    onEditUserMessage: editUserMessage,
                    onSuggestionClick: { suggestion in
                        inputText = suggestion
                        sendMessage()
                    }
                )
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    InputBarView(
                        inputText: $inputText,
                        isGenerating: isGenerating,
                        agentManager: agentManager,
                        llmService: llmService,
                        onSend: sendMessage,
                        onStop: stopGeneration,
                        onClearChat: clearCurrentChat,
                        focusTrigger: focusTrigger
                    )
                }
            }
            .frame(minWidth: 420)
            
            // 3. Right Terminal Panel (Claude Desktop style)
            if terminalManager.isPanelVisible {
                TerminalPanelView(terminalManager: terminalManager, onAskAI: { errorPrompt in
                    inputText = errorPrompt
                    sendMessage()
                })
                .frame(
                        minWidth: 300,
                        idealWidth: terminalManager.isMaximized ? 640 : 380,
                        maxWidth: terminalManager.isMaximized ? 900 : 520
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(llmService: llmService, agentManager: agentManager)
        }
        .background(
            ZStack {
                Button("") {
                    withAnimation(SwiftCatAnimations.spring) {
                        terminalManager.isPanelVisible.toggle()
                    }
                }
                .keyboardShortcut("j", modifiers: .command)
                
                Button("") {
                    startNewConversation()
                }
                .keyboardShortcut("n", modifiers: .command)
                
                Button("") {
                    clearCurrentChat()
                }
                .keyboardShortcut("k", modifiers: .command)
                
                Button("") {
                    showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
                
                Button("") {
                    agentManager.selectWorkspaceFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                
                Button("") {
                    if isGenerating { stopGeneration() }
                }
                .keyboardShortcut(".", modifiers: .command)
                
                Button("") {
                    withAnimation(SwiftCatAnimations.spring) {
                        isSidebarVisible.toggle()
                    }
                }
                .keyboardShortcut("\\", modifiers: .command)
            }
            .opacity(0)
        )
        .overlay(
            Group {
                if isDropTargeted {
                    ZStack {
                        Color.black.opacity(0.45)
                        VStack(spacing: 12) {
                            Image(systemName: "arrow.down.doc")
                                .font(.system(size: 38))
                                .foregroundColor(.cyan)
                            Text("Drop folder to attach workspace, or file to analyze")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                        }
                        .padding(28)
                        .background(Color(white: 0.15).opacity(0.85))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.cyan.opacity(0.6), lineWidth: 2)
                        )
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
            }
        )
        .overlay(alignment: .top) {
            if let notice = agentManager.lastActionNotification {
                Text(notice)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(SiriColors.textPrimary)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(white: 0.16).opacity(0.96))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 10, y: 4)
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    // Restarts whenever the text changes, so each notice gets its full time.
                    .task(id: notice) {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation(SwiftCatAnimations.spring) {
                            agentManager.lastActionNotification = nil
                        }
                    }
            }
        }
        .animation(SwiftCatAnimations.spring, value: agentManager.lastActionNotification)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted.animation(SwiftCatAnimations.spring)) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else { return }
                DispatchQueue.main.async {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                        if isDir.boolValue {
                            agentManager.setWorkspace(url)
                            terminalManager.setWorkspaceDirectory(url)
                            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                        } else if let relPath = agentManager.relativeWorkspacePath(for: url) {
                            appendMention(relPath)
                            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                        } else if let content = try? String(contentsOf: url, encoding: .utf8) {
                            inputText = "Проанализируй файл \(url.lastPathComponent):\n\n```\(url.pathExtension)\n\(content.prefix(4000))\n```"
                            focusTrigger = UUID()
                            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                        }
                    }
                }
            }
            return true
        }
        .onAppear {
            agentManager.restoreLastWorkspace()
            loadSavedConversations()
        }
        .onChange(of: conversations) {
            scheduleSave()
        }
        .onChange(of: isGenerating) {
            if !isGenerating { saveConversations() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            saveConversations()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if agentManager.currentWorkspaceURL != nil {
                agentManager.refreshWorkspace()
            }
        }
        .onChange(of: agentManager.currentWorkspaceURL) {
            terminalManager.setWorkspaceDirectory(agentManager.currentWorkspaceURL)
            if let currentID = selectedConversationID,
               let idx = conversations.firstIndex(where: { $0.id == currentID }) {
                conversations[idx].workspacePath = agentManager.currentWorkspaceURL?.path
            }
        }
        .onChange(of: terminalManager.isRunningCommand) { oldValue, newValue in
            if oldValue && !newValue {
                agentManager.refreshWorkspace()
            }
        }
        .onChange(of: selectedConversationID) {
            guard let currentID = selectedConversationID,
                  let convo = conversations.first(where: { $0.id == currentID }),
                  let savedPath = convo.workspacePath,
                  !savedPath.isEmpty else { return }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: savedPath, isDirectory: &isDir), isDir.boolValue {
                let url = URL(fileURLWithPath: savedPath)
                if agentManager.currentWorkspaceURL?.standardizedFileURL != url.standardizedFileURL {
                    agentManager.setWorkspace(url)
                }
            }
        }
    }
    
    private func appendMention(_ relativePath: String) {
        let mention = "@\(relativePath)"
        if inputText.isEmpty || inputText.hasSuffix(" ") || inputText.hasSuffix("\n") {
            inputText += mention + " "
        } else {
            inputText += " " + mention + " "
        }
        focusTrigger = UUID()
    }
    
    private func sendMessage() {
        sendPromptText(inputText, clearInput: true)
    }
    
    private func sendPromptText(_ rawText: String, clearInput: Bool) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Suggestions, file inspection and regenerate can all call this while a
        // reply is still streaming; a second stream would fight over the same state.
        guard !trimmed.isEmpty, !isGenerating else { return }
        
        let titlePreview = trimmed.count > 25 ? String(trimmed.prefix(25)) + "..." : trimmed
        if selectedConversationID == nil || conversations.isEmpty {
            let newConvo = Conversation(
                title: titlePreview,
                workspacePath: agentManager.currentWorkspaceURL?.path
            )
            conversations.insert(newConvo, at: 0)
            selectedConversationID = newConvo.id
        }
        
        guard let currentID = selectedConversationID,
              let convoIndex = conversations.firstIndex(where: { $0.id == currentID }) else {
            return
        }
        
        // Drop the untouched first-launch greeting once the user sends a real prompt,
        // so the conversation gets a proper title and APIs start on a user turn.
        if conversations[convoIndex].id == placeholderConversationID {
            conversations[convoIndex].messages.removeAll()
            placeholderConversationID = nil
        }
        
        let userMsg = ChatMessage(role: .user, content: trimmed)
        conversations[convoIndex].messages.append(userMsg)
        conversations[convoIndex].updatedAt = Date()
        
        if conversations[convoIndex].messages.count == 1 {
            conversations[convoIndex].title = titlePreview
        }
        
        if clearInput {
            inputText = ""
        }
        isGenerating = true
        
        let assistantMsgID = UUID()
        let assistantMsg = ChatMessage(
            id: assistantMsgID,
            role: .assistant,
            content: "",
            modelName: llmService.selectedModel.name
        )
        conversations[convoIndex].messages.append(assistantMsg)
        
        let convoHistory = conversations[convoIndex].messages.dropLast()
        let workspaceTree = agentManager.fileTreeSummary
        let isAgentMode = agentManager.isAgentModeEnabled
        let recentUserTexts = convoHistory.filter { $0.role == .user }.map(\.content)
        let inspectedFiles = agentManager.findRelevantFiles(inMessages: recentUserTexts)
        
        activeStreamTask = Task { @MainActor in
            class StreamState {
                var reasoningBuffer = ""
                var buffer = ""
                // How far the typewriter has revealed each buffer. Indices stay valid
                // as the buffers grow, so each tick costs only the newly shown text.
                var reasoningShown = "".startIndex
                var contentShown = "".startIndex
                var isDone = false
                var completedReasoningDuration: TimeInterval = 0
                var currentReasoningStart: Date? = nil
                var lastReportedTenths: Int = -1
                
                func totalReasoningDuration(at now: Date = Date()) -> TimeInterval? {
                    if let activeStart = currentReasoningStart {
                        return completedReasoningDuration + now.timeIntervalSince(activeStart)
                    }
                    return completedReasoningDuration > 0 ? completedReasoningDuration : nil
                }
                
                func finishReasoningTurn(at now: Date = Date()) {
                    if let activeStart = currentReasoningStart {
                        completedReasoningDuration += now.timeIntervalSince(activeStart)
                        currentReasoningStart = nil
                    }
                }
            }
            let state = StreamState()
            state.reasoningShown = state.reasoningBuffer.startIndex
            state.contentShown = state.buffer.startIndex
            
            // Smooth Typewriter Ticker (~60fps)
            let tickerTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 16_000_000) // 16ms
                    
                    guard let cIdx = self.conversations.firstIndex(where: { $0.id == currentID }),
                          let mIdx = self.conversations[cIdx].messages.firstIndex(where: { $0.id == assistantMsgID }) else {
                        return
                    }
                    
                    // Copy, mutate, write back once: a single published change per frame.
                    var message = self.conversations[cIdx].messages[mIdx]
                    var changed = false
                    
                    // Quantize live thinking duration updates to 0.1s resolution (matches UI display)
                    if let totalDuration = state.totalReasoningDuration() {
                        let tenths = Int((totalDuration * 10).rounded())
                        if tenths != state.lastReportedTenths {
                            state.lastReportedTenths = tenths
                            message.reasoningDuration = Double(tenths) / 10.0
                            changed = true
                        }
                    }
                    
                    // 1. Tick reasoning buffer
                    let reasoningLeft = state.reasoningBuffer.distance(from: state.reasoningShown, to: state.reasoningBuffer.endIndex)
                    if reasoningLeft > 0 {
                        let end = state.reasoningBuffer.index(state.reasoningShown, offsetBy: max(1, reasoningLeft / 4))
                        message.reasoning = (message.reasoning ?? "") + state.reasoningBuffer[state.reasoningShown..<end]
                        state.reasoningShown = end
                        changed = true
                    }
                    
                    // 2. Tick content buffer
                    let contentLeft = state.buffer.distance(from: state.contentShown, to: state.buffer.endIndex)
                    if contentLeft > 0 {
                        let end = state.buffer.index(state.contentShown, offsetBy: max(1, contentLeft / 5)) // Smooth adaptive speedup
                        message.content += state.buffer[state.contentShown..<end]
                        state.contentShown = end
                        changed = true
                    }
                    
                    if changed {
                        self.conversations[cIdx].messages[mIdx] = message
                    }
                    
                    if state.isDone && reasoningLeft == 0 && contentLeft == 0 {
                        break
                    }
                }
            }
            
            do {
                let handleReasoning: (String) -> Void = { chunk in
                    if state.currentReasoningStart == nil {
                        state.currentReasoningStart = Date()
                    }
                    state.reasoningBuffer += chunk
                }
                let handleToken: (String) -> Void = { chunk in
                    state.finishReasoningTurn()
                    state.buffer += chunk
                }
                
                var currentHistory = Array(convoHistory)
                var currentInspected = inspectedFiles
                var (fullResponse, fullReasoning) = try await llmService.sendPrompt(
                    conversation: currentHistory,
                    workspaceTree: workspaceTree,
                    inspectedFiles: currentInspected,
                    isAgentMode: isAgentMode,
                    onReasoning: handleReasoning,
                    onToken: handleToken
                )
                state.finishReasoningTurn()
                
                // Autonomous <read_file path="..." /> loop (up to 2 hops)
                var hop = 0
                var attemptedPaths = Set(currentInspected.keys)
                while isAgentMode && hop < 2 && !Task.isCancelled {
                    let requestedPaths = agentManager.extractReadRequests(from: fullResponse)
                        .filter { !attemptedPaths.contains($0) }
                    guard !requestedPaths.isEmpty else { break }
                    
                    var newlyLoaded: [String] = []
                    var missingPaths: [String] = []
                    for reqPath in requestedPaths.prefix(4) {
                        attemptedPaths.insert(reqPath)
                        if let fileText = agentManager.readFileContent(relativePath: reqPath) {
                            currentInspected[reqPath] = fileText
                            newlyLoaded.append(reqPath)
                        } else {
                            missingPaths.append(reqPath)
                        }
                    }
                    guard !newlyLoaded.isEmpty || !missingPaths.isEmpty else { break }
                    hop += 1
                    if !newlyLoaded.isEmpty {
                        agentManager.lastActionNotification = "Read: \(newlyLoaded.joined(separator: ", "))"
                    } else {
                        agentManager.lastActionNotification = "File not found: \(missingPaths.joined(separator: ", "))"
                    }
                    
                    var followUpParts: [String] = []
                    if !newlyLoaded.isEmpty {
                        followUpParts.append("Loaded requested file(s): \(newlyLoaded.joined(separator: ", ")).")
                    }
                    if !missingPaths.isEmpty {
                        followUpParts.append("Could not read: \(missingPaths.joined(separator: ", ")). Reason: file not found or outside workspace.")
                    }
                    followUpParts.append("Please continue with the complete answer.")
                    
                    currentHistory.append(ChatMessage(role: .assistant, content: fullResponse))
                    currentHistory.append(ChatMessage(
                        role: .user,
                        content: followUpParts.joined(separator: " ")
                    ))
                    
                    state.buffer += "\n\n"
                    let (nextResponse, nextReasoning) = try await llmService.sendPrompt(
                        conversation: currentHistory,
                        workspaceTree: workspaceTree,
                        inspectedFiles: currentInspected,
                        isAgentMode: isAgentMode,
                        onReasoning: handleReasoning,
                        onToken: handleToken
                    )
                    state.finishReasoningTurn()
                    fullResponse += "\n\n" + nextResponse
                    if !nextReasoning.isEmpty {
                        fullReasoning += (fullReasoning.isEmpty ? "" : "\n") + nextReasoning
                    }
                }
                
                state.finishReasoningTurn()
                state.isDone = true
                _ = await tickerTask.value
                
                // Ensure all characters reached the screen
                if let cIdx = self.conversations.firstIndex(where: { $0.id == currentID }),
                   let mIdx = self.conversations[cIdx].messages.firstIndex(where: { $0.id == assistantMsgID }) {
                    if !fullReasoning.isEmpty {
                        self.conversations[cIdx].messages[mIdx].reasoning = fullReasoning
                        if let finalDuration = state.totalReasoningDuration() {
                            self.conversations[cIdx].messages[mIdx].reasoningDuration = finalDuration
                        }
                    }
                    self.conversations[cIdx].messages[mIdx].content = fullResponse
                    self.conversations[cIdx].updatedAt = Date()
                }
                
                // If auto-apply is enabled, write files
                if isAgentMode && agentManager.autoApplyChanges {
                    let proposals = agentManager.extractFileProposals(from: fullResponse)
                        .map { (path: $0.path, content: $0.content) }
                    agentManager.writeFiles(proposals)
                }
            } catch {
                state.isDone = true
                tickerTask.cancel()
                
                let wasStopped = Task.isCancelled
                    || error is CancellationError
                    || (error as? URLError)?.code == .cancelled
                
                if let cIdx = self.conversations.firstIndex(where: { $0.id == currentID }),
                   let mIdx = self.conversations[cIdx].messages.firstIndex(where: { $0.id == assistantMsgID }) {
                    if wasStopped {
                        // Stopped by the user: keep whatever was received, without an error line.
                        self.conversations[cIdx].messages[mIdx].content = state.buffer
                        if !state.reasoningBuffer.isEmpty {
                            self.conversations[cIdx].messages[mIdx].reasoning = state.reasoningBuffer
                        }
                        if state.buffer.isEmpty && state.reasoningBuffer.isEmpty {
                            self.conversations[cIdx].messages.remove(at: mIdx)
                        }
                    } else {
                        let partial = state.buffer.isEmpty ? "" : state.buffer + "\n\n"
                        self.conversations[cIdx].messages[mIdx].content = partial + "Error: \(error.localizedDescription)"
                    }
                }
            }
            
            self.isGenerating = false
            self.activeStreamTask = nil
        }
    }
    
    /// Opens a blank chat, reusing one that is already empty instead of piling up
    /// untitled conversations.
    private func startNewConversation() {
        withAnimation(SwiftCatAnimations.spring) {
            if let empty = conversations.first(where: { $0.messages.isEmpty }) {
                selectedConversationID = empty.id
            } else {
                let newConvo = Conversation(
                    title: "New Conversation",
                    workspacePath: agentManager.currentWorkspaceURL?.path
                )
                conversations.insert(newConvo, at: 0)
                selectedConversationID = newConvo.id
            }
        }
        focusTrigger = UUID()
    }
    
    private func regenerateLastResponse() {
        guard let currentID = selectedConversationID,
              let convoIndex = conversations.firstIndex(where: { $0.id == currentID }),
              !conversations[convoIndex].messages.isEmpty,
              !isGenerating else { return }
        
        if conversations[convoIndex].messages.last?.role == .assistant {
            conversations[convoIndex].messages.removeLast()
        }
        
        if let lastUserMsg = conversations[convoIndex].messages.last(where: { $0.role == .user }) {
            let lastPrompt = lastUserMsg.content
            conversations[convoIndex].messages.removeAll(where: { $0.id == lastUserMsg.id })
            sendPromptText(lastPrompt, clearInput: false)
        }
    }
    
    private func editUserMessage(_ message: ChatMessage) {
        guard let currentID = selectedConversationID,
              let convoIndex = conversations.firstIndex(where: { $0.id == currentID }),
              let msgIndex = conversations[convoIndex].messages.firstIndex(where: { $0.id == message.id }),
              !isGenerating else { return }
        
        withAnimation(SwiftCatAnimations.spring) {
            inputText = message.content
            conversations[convoIndex].messages.removeSubrange(msgIndex..<conversations[convoIndex].messages.count)
            conversations[convoIndex].updatedAt = Date()
        }
        focusTrigger = UUID()
    }
    
    private func stopGeneration() {
        // Only cancel here. The stream task resets `isGenerating` itself once it has
        // unwound, so a late-finishing old task can never clobber a newer request.
        activeStreamTask?.cancel()
    }
    
    private func clearCurrentChat() {
        if isGenerating {
            stopGeneration()
        }
        guard let currentID = selectedConversationID,
              let convoIndex = conversations.firstIndex(where: { $0.id == currentID }) else { return }
        withAnimation(SwiftCatAnimations.spring) {
            conversations[convoIndex].messages.removeAll()
            if conversations[convoIndex].id == placeholderConversationID {
                placeholderConversationID = nil
            }
        }
        focusTrigger = UUID()
    }
    
    /// Coalesces bursts of edits into one write. While a reply streams, the
    /// conversation changes ~60 times a second; it is saved once when it ends.
    private func scheduleSave() {
        guard !isGenerating else { return }
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            saveConversations()
        }
    }
    
    private func saveConversations() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        // The untouched first-launch greeting is not user data; writing it would
        // create a history file that shadows chats still waiting to be migrated.
        if conversations.count == 1, let only = conversations.first,
           only.id == placeholderConversationID, only.messages.count <= 1 {
            return
        }
        ConversationStore.save(conversations)
    }
    
    private func loadSavedConversations() {
        guard conversations.isEmpty else { return }
        let saved = ConversationStore.load()
        if !saved.isEmpty {
            self.conversations = saved
            self.selectedConversationID = saved.first?.id
        } else {
            let welcome = Conversation(
                title: "Apple Intelligence",
                messages: [
                    ChatMessage(
                        role: .assistant,
                        content: "I can assist with tasks such as coding, answering questions, and editing files.",
                        modelName: "Apple Intelligence"
                    )
                ]
            )
            self.placeholderConversationID = welcome.id
            self.conversations = [welcome]
            self.selectedConversationID = welcome.id
        }
    }
}

public struct PanelToggleButton: View {
    let systemImage: String
    let isActive: Bool
    let helpText: String
    let action: () -> Void
    @State private var isHovered = false
    
    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(isActive ? SiriColors.textPrimary : (isHovered ? SiriColors.textPrimary : SiriColors.textSecondary))
                .frame(width: 26, height: 26)
                .background(
                    isActive
                        ? Color.white.opacity(0.10)
                        : (isHovered ? Color.white.opacity(0.07) : Color.white.opacity(0.03))
                )
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isActive ? Color.white.opacity(0.16) : SiriColors.border, lineWidth: 1)
                )
                .animation(SwiftCatAnimations.smooth, value: isHovered)
                .animation(SwiftCatAnimations.spring, value: isActive)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(helpText)
    }
}

public struct TerminalIconButton: View {
    @ObservedObject var terminalManager: TerminalManager
    
    public var body: some View {
        PanelToggleButton(
            systemImage: "terminal",
            isActive: terminalManager.isPanelVisible,
            helpText: "Toggle Terminal (⌘J)"
        ) {
            withAnimation(SwiftCatAnimations.spring) {
                terminalManager.isPanelVisible.toggle()
            }
        }
    }
}
