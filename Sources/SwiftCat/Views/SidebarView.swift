import SwiftUI
import AppKit

public struct SidebarView: View {
    @Binding var conversations: [Conversation]
    @Binding var selectedConversationID: UUID?
    @ObservedObject var llmService: LLMService
    @ObservedObject var agentManager: AgentManager
    @ObservedObject var terminalManager: TerminalManager
    @Binding var showSettings: Bool
    var onInspectFile: ((String) -> Void)? = nil
    var onAttachFile: ((String) -> Void)? = nil
    
    @State private var selectedTab: SidebarTab = .chats
    @State private var chatSearchText = ""
    @State private var fileSearchText = ""
    @State private var hoveredConvoID: UUID? = nil
    @State private var hoveredFilePath: String? = nil
    @State private var renamingConvoID: UUID? = nil
    @State private var renameDraft: String = ""
    @FocusState private var isRenameFocused: Bool
    
    enum SidebarTab: String, CaseIterable {
        case chats = "Chats"
        case files = "Files"
    }
    
    var filteredConversations: [Conversation] {
        // Most recently active first. Search looks through every message,
        // not just the title and the last line.
        let sorted = conversations.sorted { $0.updatedAt > $1.updatedAt }
        if chatSearchText.isEmpty {
            return sorted
        } else {
            return sorted.filter { convo in
                convo.title.localizedCaseInsensitiveContains(chatSearchText) ||
                convo.messages.contains { $0.content.localizedCaseInsensitiveContains(chatSearchText) }
            }
        }
    }
    
    var todayConversations: [Conversation] {
        let calendar = Calendar.current
        return filteredConversations.filter { calendar.isDateInToday($0.updatedAt) }
    }
    
    var olderConversations: [Conversation] {
        let calendar = Calendar.current
        return filteredConversations.filter { !calendar.isDateInToday($0.updatedAt) }
    }
    
    var filteredWorkspaceFiles: [WorkspaceItem] {
        if fileSearchText.isEmpty {
            return agentManager.flatWorkspaceFiles
        } else {
            return agentManager.flatWorkspaceFiles.filter {
                $0.name.localizedCaseInsensitiveContains(fileSearchText) ||
                $0.path.localizedCaseInsensitiveContains(fileSearchText)
            }
        }
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Brand Logo & Action Buttons
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "swift")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.white, Color(white: 0.78)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Color.white.opacity(0.20), radius: 2)
                    
                    Text("SwiftCat")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(SiriColors.textPrimary)
                }
                
                Spacer()
                
                // New chat button
                Button(action: createNewConversation) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(SiriColors.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("New Conversation (Cmd+N)")
                
                if selectedTab == .files {
                    // Workspace Actions Menu
                    Menu {
                        Button(action: { agentManager.selectWorkspaceFolder() }) {
                            Label("Select Project Folder...", systemImage: "folder.badge.plus")
                        }
                        
                        if let url = agentManager.currentWorkspaceURL {
                            Button(action: {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }) {
                                Label("Reveal in Finder", systemImage: "arrow.up.right.square")
                            }
                            
                            Button(action: {
                                terminalManager.setWorkspaceDirectory(url)
                                terminalManager.isPanelVisible = true
                            }) {
                                Label("Open in Terminal", systemImage: "terminal")
                            }
                            
                            Divider()
                            
                            Button(role: .destructive, action: {
                                agentManager.clearWorkspace()
                            }) {
                                Label("Disconnect Workspace", systemImage: "xmark.circle")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(SiriColors.textSecondary)
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(6)
                    }
                    .menuStyle(.borderlessButton)
                    .help("Workspace Options")
                }
                
                // Settings button
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(SiriColors.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("Settings & API Keys")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)
            
            // Segmented Tab Picker: Chats | Files
            HStack(spacing: 4) {
                tabButton(tab: .chats, icon: "bubble.left.and.bubble.right", count: nil)
                tabButton(tab: .files, icon: "folder", count: agentManager.fileCount > 0 ? agentManager.fileCount : nil)
            }
            .padding(3)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.04))
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            
            Divider()
                .background(SiriColors.border)
            
            // Tab Content
            if selectedTab == .chats {
                chatsContentView
            } else {
                filesContentView
            }
        }
        .background(SiriColors.sidebarBackground)
    }
    
    private func tabButton(tab: SidebarTab, icon: String, count: Int?) -> some View {
        let isSelected = selectedTab == tab
        return Button(action: {
            withAnimation(SwiftCatAnimations.spring) {
                selectedTab = tab
            }
        }) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                
                Text(tab.rawValue)
                    .font(.system(size: 11, weight: .medium))
                
                if let count = count {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.12))
                        .cornerRadius(4)
                }
            }
            .foregroundColor(isSelected ? SiriColors.textPrimary : SiriColors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.white.opacity(0.08) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Chats List
    private var chatsContentView: some View {
        VStack(spacing: 0) {
            // Search chats bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(SiriColors.textSecondary)
                
                TextField("Filter chats...", text: $chatSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(SiriColors.textPrimary)
                    .onExitCommand { chatSearchText = "" }
                
                if !chatSearchText.isEmpty {
                    Button(action: { chatSearchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(SiriColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.04))
            .cornerRadius(6)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !todayConversations.isEmpty {
                        Section(header: sectionHeader("Today")) {
                            ForEach(todayConversations) { convo in
                                conversationRow(convo)
                            }
                        }
                    }
                    
                    if !olderConversations.isEmpty {
                        Section(header: sectionHeader("Earlier")) {
                            ForEach(olderConversations) { convo in
                                conversationRow(convo)
                            }
                        }
                    }
                    
                    if filteredConversations.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(conversations.isEmpty ? "No chats yet" : "No matching chats")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(SiriColors.textSecondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 20)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
        }
    }
    
    // MARK: - Files Explorer
    private var filesContentView: some View {
        VStack(spacing: 0) {
            if let workspace = agentManager.currentWorkspaceURL {
                // Workspace Header Info
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.cyan)
                    
                    Text(workspace.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(SiriColors.textPrimary)
                        .lineLimit(1)
                    
                    if let branch = agentManager.gitBranch {
                        Menu {
                            Button(action: {
                                terminalManager.isPanelVisible = true
                                terminalManager.executeExternalCommand("git status")
                            }) {
                                Label("git status", systemImage: "terminal")
                            }
                            
                            Button(action: {
                                terminalManager.isPanelVisible = true
                                terminalManager.executeExternalCommand("git diff")
                            }) {
                                Label("git diff", systemImage: "doc.text.magnifyingglass")
                            }
                            
                            Button(action: {
                                terminalManager.isPanelVisible = true
                                terminalManager.executeExternalCommand("git log --oneline -n 10")
                            }) {
                                Label("git log", systemImage: "clock")
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 8))
                                Text(branch)
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                            }
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.cyan.opacity(0.12))
                            .cornerRadius(4)
                        }
                        .menuStyle(.borderlessButton)
                        .help("Git Branch: \(branch)")
                    }
                    
                    Spacer()
                    
                    Text("\(agentManager.fileCount) files")
                        .font(.system(size: 10))
                        .foregroundColor(SiriColors.textSecondary)
                    
                    Button(action: {
                        agentManager.refreshWorkspace()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(SiriColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh workspace files")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.02))
                
                // Search filter bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundColor(SiriColors.textSecondary)
                    
                    TextField("Filter files...", text: $fileSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(SiriColors.textPrimary)
                        .onExitCommand { fileSearchText = "" }
                    
                    if !fileSearchText.isEmpty {
                        Button(action: { fileSearchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(SiriColors.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.04))
                .cornerRadius(6)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                
                // File List
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredWorkspaceFiles) { file in
                            fileRow(file)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            } else {
                // Empty Workspace State
                VStack(spacing: 12) {
                    Spacer()
                    
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(SiriColors.textSecondary)
                    
                    Text("No Project Attached")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(SiriColors.textPrimary)
                    
                    Text("Connect a workspace to let SwiftCat inspect code, propose changes, and run project commands.")
                        .font(.system(size: 11))
                        .foregroundColor(SiriColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    
                    Button(action: {
                        agentManager.selectWorkspaceFolder()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("Attach Project Folder")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundColor(SiriColors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(7)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(SiriColors.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    
                    Text("Shortcut: ⇧⌘O")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(SiriColors.textSecondary.opacity(0.8))
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
            }
        }
    }
    
    private func fileRow(_ file: WorkspaceItem) -> some View {
        let isHovered = hoveredFilePath == file.path
        let (icon, color) = iconForExtension(file.ext)
        
        return HStack(spacing: 6) {
            Button(action: {
                onInspectFile?(file.path)
            }) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundColor(color)
                        .frame(width: 16)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(SiriColors.textPrimary)
                            .lineLimit(1)
                        
                        Text(file.path)
                            .font(.system(size: 10))
                            .foregroundColor(SiriColors.textSecondary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isHovered, let onAttachFile {
                Button(action: {
                    onAttachFile(file.path)
                }) {
                    Text("@")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(SiriColors.textPrimary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(SiriColors.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Attach as @file")
            }
            
            Text(file.size)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(SiriColors.textSecondary.opacity(0.8))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isHovered ? SiriColors.cardBackground.opacity(0.7) : Color.clear)
        .cornerRadius(6)
        .onHover { isHovering in
            hoveredFilePath = isHovering ? file.path : nil
        }
        .contextMenu {
            Button(action: {
                onInspectFile?(file.path)
            }) {
                Label("Ask SwiftCat about this file", systemImage: "sparkles")
            }
            
            if let onAttachFile {
                Button(action: {
                    onAttachFile(file.path)
                }) {
                    Label("Attach as @file", systemImage: "at")
                }
            }
            
            Button(action: {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(file.path, forType: .string)
            }) {
                Label("Copy Relative Path", systemImage: "doc.on.doc")
            }
            
            if let baseURL = agentManager.currentWorkspaceURL {
                Button(action: {
                    let fileURL = baseURL.appendingPathComponent(file.path)
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }) {
                    Label("Reveal in Finder", systemImage: "arrow.up.right.square")
                }
            }
        }
    }
    
    private func iconForExtension(_ ext: String) -> (String, Color) {
        switch ext.lowercased() {
        case "swift":
            return ("swift", .orange)
        case "py":
            return ("chevron.left.forwardslash.chevron.right", .yellow)
        case "js", "ts", "jsx", "tsx":
            return ("curlybraces", .yellow)
        case "json", "yaml", "yml", "toml":
            return ("doc.badge.gearshape", .cyan)
        case "html", "css":
            return ("globe", .blue)
        case "md", "txt", "rtf":
            return ("doc.text", .indigo)
        case "sh", "zsh", "bash":
            return ("terminal", .green)
        case "png", "jpg", "jpeg", "svg", "pdf":
            return ("photo", .pink)
        default:
            return ("doc", SiriColors.textSecondary)
        }
    }
    
    // MARK: - Footer Model Selector
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(SiriColors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.top, 4)
    }
    
    private func conversationRow(_ convo: Conversation) -> some View {
        let isSelected = selectedConversationID == convo.id
        let isHovered = hoveredConvoID == convo.id
        let isRenaming = renamingConvoID == convo.id
        
        return Group {
            if isRenaming {
                TextField("Title", text: $renameDraft)
                    .focused($isRenameFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(SiriColors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(SiriColors.activeCard)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.cyan.opacity(0.4), lineWidth: 1)
                    )
                    .onSubmit {
                        commitRename(convo)
                    }
                    .onExitCommand {
                        renamingConvoID = nil
                    }
            } else {
                Button(action: {
                    withAnimation(SwiftCatAnimations.spring) {
                        selectedConversationID = convo.id
                    }
                }) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(convo.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(SiriColors.textPrimary)
                            .lineLimit(1)
                        
                        Text(convo.previewSnippet)
                            .font(.system(size: 11))
                            .foregroundColor(SiriColors.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        isSelected ? SiriColors.activeCard : (isHovered ? SiriColors.cardBackground.opacity(0.6) : Color.clear)
                    )
                    .cornerRadius(8)
                    .animation(SwiftCatAnimations.smooth, value: isSelected)
                    .animation(SwiftCatAnimations.smooth, value: isHovered)
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    hoveredConvoID = isHovering ? convo.id : nil
                }
                .contextMenu {
                    Button(action: {
                        renameDraft = convo.title
                        renamingConvoID = convo.id
                        isRenameFocused = true
                    }) {
                        Label("Rename", systemImage: "pencil")
                    }
                    
                    Button(action: {
                        exportConversation(convo)
                    }) {
                        Label("Export Markdown...", systemImage: "square.and.arrow.up")
                    }
                    
                    Divider()
                    
                    Button(role: .destructive, action: {
                        withAnimation(SwiftCatAnimations.spring) {
                            deleteConversation(convo)
                        }
                    }) {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }
    
    private func exportConversation(_ convo: Conversation) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "Export Conversation as Markdown"
        let sanitized = convo.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = "\(sanitized.isEmpty ? "Conversation" : sanitized).md"
        if panel.runModal() == .OK, let url = panel.url {
            let markdown = Self.markdownExport(for: convo)
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    
    public nonisolated static func markdownExport(for convo: Conversation) -> String {
        var lines: [String] = ["# \(convo.title)"]
        if let workspacePath = convo.workspacePath, !workspacePath.isEmpty {
            lines.append("")
            lines.append("_Workspace: `\(workspacePath)`_")
        }
        for message in convo.messages {
            let roleLabel: String
            switch message.role {
            case .user: roleLabel = "User"
            case .assistant: roleLabel = "Assistant"
            case .system: roleLabel = "System"
            }
            lines.append("")
            lines.append("## \(roleLabel)")
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                lines.append("")
                lines.append("<details><summary>Reasoning</summary>")
                lines.append("")
                lines.append(reasoning)
                lines.append("")
                lines.append("</details>")
            }
            if !message.content.isEmpty {
                lines.append("")
                lines.append(message.content)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
    
    private func commitRename(_ convo: Conversation) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let idx = conversations.firstIndex(where: { $0.id == convo.id }) {
            conversations[idx].title = trimmed
        }
        renamingConvoID = nil
    }
    
    private func createNewConversation() {
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
    }
    
    private func deleteConversation(_ convo: Conversation) {
        if let idx = conversations.firstIndex(where: { $0.id == convo.id }) {
            conversations.remove(at: idx)
            if selectedConversationID == convo.id {
                selectedConversationID = conversations.first?.id
            }
        }
    }
}
