import SwiftUI
import AppKit

public struct SettingsSheet: View {
    @ObservedObject var llmService: LLMService
    @ObservedObject var agentManager: AgentManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var showAddModel: Bool = false
    @State private var addModelKind: AddModelKind = .cloud
    @State private var modelNameDraft: String = ""
    @State private var modelSlugDraft: String = ""
    
    @State private var isCheckingServer: Bool = false
    @State private var isKeyVisible: Bool = false
    @State private var statusMessage: String?
    @State private var hoveredModelID: UUID?
    @FocusState private var focusedField: Field?
    
    private enum AddModelKind: String, CaseIterable {
        case cloud = "Cloud"
        case local = "Local"
    }
    
    private enum Field: Hashable {
        case endpoint, apiKey, modelName, modelSlug
    }
    
    private var isOllamaInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Ollama.app")
    }
    
    private var uninstalledLocalModels: [String] {
        llmService.detectedLocalModels.filter { tag in
            !llmService.availableModels.contains(where: { $0.slug == tag })
        }
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Minimalist header
            HStack {
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SiriColors.textPrimary)
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(SiriColors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.08))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(SiriColors.border, lineWidth: 1)
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            
            hairlineDivider
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    modelsSection
                    connectionsSection
                    agentSection
                }
                .padding(18)
            }
        }
        .frame(width: 480, height: 540)
        .background(SiriColors.sidebarBackground)
        .onAppear {
            Task {
                await llmService.checkLocalServerStatus()
            }
        }
    }
    
    // MARK: - Models
    
    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Models")
                
                Spacer()
                
                Button(action: {
                    withAnimation(SwiftCatAnimations.spring) {
                        showAddModel.toggle()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: showAddModel ? "minus" : "plus")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(showAddModel ? "Close" : "Add")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(SiriColors.textSecondary)
                }
                .buttonStyle(.plain)
            }
            
            groupedContainer {
                VStack(spacing: 0) {
                    ForEach(Array(llmService.availableModels.enumerated()), id: \.element.id) { index, model in
                        if index > 0 {
                            rowDivider
                        }
                        modelRow(model)
                    }
                    
                    if !uninstalledLocalModels.isEmpty {
                        rowDivider
                        detectedModelsRow
                    }
                }
            }
            
            if showAddModel {
                addModelCard
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
    
    private func modelRow(_ model: ConfiguredModel) -> some View {
        let isSelected = llmService.selectedModel.id == model.id
        let isHovered = hoveredModelID == model.id
        let subtitle = model.isAppleIntelligence
            ? "On-device"
            : "\(model.isLocalServer ? "Local" : "Cloud") · \(model.slug)"
        
        return HStack(spacing: 10) {
            Button(action: {
                llmService.selectedModel = model
            }) {
                HStack(spacing: 10) {
                    Image(systemName: model.iconName)
                        .font(.system(size: 11.5))
                        .foregroundColor(isSelected ? SiriColors.textPrimary : SiriColors.textSecondary)
                        .frame(width: 16)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.name)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(SiriColors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        Text(subtitle)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.38))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    Spacer()
                    
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(SiriColors.textPrimary)
                    } else if isHovered {
                        Text("Use")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(SiriColors.textSecondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if !model.isAppleIntelligence {
                Button(action: {
                    withAnimation(SwiftCatAnimations.spring) {
                        llmService.removeModel(model)
                    }
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 10.5))
                        .foregroundColor(Color.white.opacity(isHovered ? 0.55 : 0.25))
                }
                .buttonStyle(.plain)
                .help("Remove model")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isHovered ? Color.white.opacity(0.03) : Color.clear)
        .onHover { hovered in
            hoveredModelID = hovered ? model.id : (hoveredModelID == model.id ? nil : hoveredModelID)
        }
    }
    
    private var detectedModelsRow: some View {
        HStack(spacing: 8) {
            Text("Detected")
                .font(.system(size: 11))
                .foregroundColor(SiriColors.textSecondary)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(uninstalledLocalModels, id: \.self) { tag in
                        Button(action: {
                            let clean = LLMService.cleanLocalModelName(tag)
                            llmService.addLocalModel(name: clean, slug: tag)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                    .font(.system(size: 8.5, weight: .semibold))
                                Text(LLMService.cleanLocalModelName(tag))
                                    .font(.system(size: 10.5, design: .monospaced))
                            }
                            .foregroundColor(SiriColors.textPrimary.opacity(0.8))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    private var addModelCard: some View {
        groupedContainer {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    // Monochrome Cloud | Local switcher
                    HStack(spacing: 2) {
                        ForEach(AddModelKind.allCases, id: \.self) { kind in
                            Button(action: { addModelKind = kind }) {
                                Text(kind.rawValue)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(addModelKind == kind ? SiriColors.textPrimary : SiriColors.textSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(addModelKind == kind ? Color.white.opacity(0.10) : Color.clear)
                                    .cornerRadius(5)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(7)
                    
                    Spacer()
                    
                    // Quiet preset chips
                    HStack(spacing: 6) {
                        if addModelKind == .cloud {
                            presetPill("Nemotron 550B", slug: "nvidia/nemotron-3-ultra-550b-a55b:free")
                            presetPill("Gemma 4", slug: "google/gemma-4-31b-it:free")
                            presetPill("Free", slug: "openrouter/free")
                        } else {
                            presetPill("Qwen 2.5 Coder", slug: "qwen2.5-coder:7b")
                            presetPill("Llama 3.2", slug: "llama3.2:3b")
                            presetPill("DeepSeek R1", slug: "deepseek-r1:8b")
                        }
                    }
                }
                
                HStack(spacing: 8) {
                    minimalInput(
                        placeholder: "Name (optional)",
                        text: $modelNameDraft,
                        field: .modelName,
                        monospaced: false
                    )
                    
                    minimalInput(
                        placeholder: addModelKind == .cloud ? "nvidia/nemotron..." : "qwen2.5-coder:7b",
                        text: $modelSlugDraft,
                        field: .modelSlug,
                        monospaced: true,
                        onSubmit: submitAddModel
                    )
                    
                    Button("Add", action: submitAddModel)
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(slugDraftIsEmpty ? SiriColors.textSecondary.opacity(0.5) : SiriColors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(slugDraftIsEmpty ? 0.03 : 0.10))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(SiriColors.border, lineWidth: 1)
                        )
                        .disabled(slugDraftIsEmpty)
                }
            }
            .padding(12)
        }
    }
    
    // MARK: - Connections
    
    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Connections")
                
                Spacer()
                
                HStack(spacing: 5) {
                    Circle()
                        .fill(llmService.isLocalServerOnline ? Color.green.opacity(0.85) : Color.white.opacity(0.25))
                        .frame(width: 6, height: 6)
                    
                    Text(llmService.isLocalServerOnline ? "Local online" : "Local offline")
                        .font(.system(size: 10.5))
                        .foregroundColor(SiriColors.textSecondary)
                }
            }
            
            groupedContainer {
                VStack(spacing: 0) {
                    // Local endpoint row
                    HStack(spacing: 10) {
                        Text("Endpoint")
                            .font(.system(size: 12))
                            .foregroundColor(SiriColors.textSecondary)
                            .frame(width: 72, alignment: .leading)
                        
                        minimalInput(
                            placeholder: "http://localhost:11434/v1",
                            text: $llmService.localServerEndpoint,
                            field: .endpoint,
                            monospaced: true,
                            onSubmit: runLocalServerCheck
                        )
                        
                        Menu {
                            endpointPresetItem("Ollama (:11434)", url: "http://localhost:11434/v1")
                            endpointPresetItem("LM Studio (:1234)", url: "http://localhost:1234/v1")
                            endpointPresetItem("llama.cpp (:8080)", url: "http://localhost:8080/v1")
                            if isOllamaInstalled && !llmService.isLocalServerOnline {
                                Divider()
                                Button("Launch Ollama.app") {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Ollama.app"))
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 11))
                                .foregroundColor(SiriColors.textSecondary)
                                .frame(width: 24, height: 24)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(5)
                        }
                        .menuStyle(.borderlessButton)
                        .help("Endpoint Presets")
                        
                        Button(action: runLocalServerCheck) {
                            Group {
                                if isCheckingServer {
                                    ProgressView().scaleEffect(0.45)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 10.5))
                                }
                            }
                            .foregroundColor(SiriColors.textSecondary)
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                        .help("Check local server")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    
                    rowDivider
                    
                    // OpenRouter API key row
                    HStack(spacing: 10) {
                        HStack(spacing: 5) {
                            Text("API Key")
                                .font(.system(size: 12))
                                .foregroundColor(SiriColors.textSecondary)
                            if !llmService.openRouterKey.isEmpty {
                                Circle()
                                    .fill(Color.green.opacity(0.85))
                                    .frame(width: 5, height: 5)
                            }
                        }
                        .frame(width: 72, alignment: .leading)
                        
                        minimalSecretInput(
                            placeholder: "sk-or-v1-...",
                            text: $llmService.openRouterKey
                        )
                        
                        Button(action: { isKeyVisible.toggle() }) {
                            Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                                .font(.system(size: 10.5))
                                .foregroundColor(SiriColors.textSecondary)
                                .frame(width: 24, height: 24)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                        .help(isKeyVisible ? "Hide key" : "Show key")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            
            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 10.5))
                    .foregroundColor(SiriColors.textSecondary)
                    .padding(.horizontal, 2)
            }
        }
    }
    
    // MARK: - Agent
    
    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Agent")
            
            groupedContainer {
                VStack(spacing: 0) {
                    agentToggleRow(
                        title: "Agent mode",
                        subtitle: "Inspect files and propose edits in workspace",
                        isOn: $agentManager.isAgentModeEnabled
                    )
                    
                    rowDivider
                    
                    agentToggleRow(
                        title: "Auto-apply writes",
                        subtitle: "Write proposed changes directly to disk",
                        isOn: $agentManager.autoApplyChanges
                    )
                    
                    rowDivider
                    
                    HStack(spacing: 10) {
                        Text("Workspace")
                            .font(.system(size: 12))
                            .foregroundColor(SiriColors.textSecondary)
                            .frame(width: 72, alignment: .leading)
                        
                        Text(agentManager.currentWorkspaceURL?.path ?? "None selected")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(agentManager.currentWorkspaceURL != nil ? SiriColors.textPrimary.opacity(0.85) : SiriColors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        Spacer()
                        
                        Button("Choose...") {
                            agentManager.selectWorkspaceFolder()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(SiriColors.textPrimary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(SiriColors.border, lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
            }
        }
    }
    
    // MARK: - Helpers & Reusable Styles
    
    private var slugDraftIsEmpty: Bool {
        modelSlugDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(SiriColors.textSecondary)
    }
    
    private var hairlineDivider: some View {
        Divider().background(SiriColors.border)
    }
    
    private var rowDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
            .padding(.leading, 12)
    }
    
    private func groupedContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(Color.white.opacity(0.03))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(SiriColors.border, lineWidth: 1)
            )
    }
    
    private func minimalInput(
        placeholder: String,
        text: Binding<String>,
        field: Field,
        monospaced: Bool,
        onSubmit: (() -> Void)? = nil
    ) -> some View {
        TextField(placeholder, text: text)
            .focused($focusedField, equals: field)
            .settingsFieldStyle(isFocused: focusedField == field, monospaced: monospaced)
            .onSubmit {
                onSubmit?()
            }
    }
    
    @ViewBuilder
    private func minimalSecretInput(placeholder: String, text: Binding<String>) -> some View {
        Group {
            if isKeyVisible {
                TextField(placeholder, text: text)
            } else {
                SecureField(placeholder, text: text)
            }
        }
        .focused($focusedField, equals: .apiKey)
        .settingsFieldStyle(isFocused: focusedField == .apiKey, monospaced: true)
    }
    
    private func agentToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(SiriColors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundColor(SiriColors.textSecondary)
            }
            
            Spacer()
            
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
    
    private func presetPill(_ title: String, slug: String) -> some View {
        Button(action: {
            modelNameDraft = title
            modelSlugDraft = slug
        }) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(SiriColors.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.05))
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }
    
    private func endpointPresetItem(_ title: String, url: String) -> some View {
        Button(action: {
            llmService.localServerEndpoint = url
            runLocalServerCheck()
        }) {
            HStack {
                Text(title)
                if llmService.localServerEndpoint == url {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
    
    private func submitAddModel() {
        let slug = modelSlugDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else { return }
        if addModelKind == .cloud {
            llmService.addCustomModel(name: modelNameDraft, slug: slug)
        } else {
            let name = modelNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            llmService.addLocalModel(name: name.isEmpty ? LLMService.cleanLocalModelName(slug) : name, slug: slug)
        }
        modelNameDraft = ""
        modelSlugDraft = ""
        withAnimation(SwiftCatAnimations.spring) {
            showAddModel = false
        }
    }
    
    private func runLocalServerCheck() {
        isCheckingServer = true
        statusMessage = nil
        Task {
            await llmService.checkLocalServerStatus()
            isCheckingServer = false
            if llmService.isLocalServerOnline {
                let count = llmService.detectedLocalModels.count
                statusMessage = count > 0
                    ? "Connected (\(count) model\(count == 1 ? "" : "s") detected)"
                    : "Connected to server"
            } else {
                statusMessage = "No server responding at \(llmService.localServerEndpoint)"
            }
        }
    }
}

private extension View {
    func settingsFieldStyle(isFocused: Bool, monospaced: Bool) -> some View {
        self
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .font(.system(size: 11.5, design: monospaced ? .monospaced : .default))
            .foregroundColor(SiriColors.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.04))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isFocused ? Color.white.opacity(0.22) : SiriColors.border, lineWidth: 1)
            )
    }
}
