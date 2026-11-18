import SwiftUI
import AppKit

public struct TerminalPanelView: View {
    @ObservedObject var terminalManager: TerminalManager
    var onAskAI: ((String) -> Void)? = nil
    @FocusState private var isInputFocused: Bool
    
    @State private var isHoveringPlus = false
    @State private var isHoveringExpand = false
    @State private var isHoveringClose = false
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header matching Claude Desktop / IDE style
            HStack(spacing: 8) {
                // Active Shell Tab
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                        .foregroundColor(SiriColors.textSecondary)
                    
                    Text("zsh")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(SiriColors.textPrimary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.06))
                .cornerRadius(6)
                
                // Clear Terminal button
                Button(action: {
                    withAnimation(SwiftCatAnimations.spring) {
                        terminalManager.entries.removeAll()
                    }
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(terminalManager.entries.isEmpty ? SiriColors.textSecondary.opacity(0.4) : (isHoveringPlus ? SiriColors.textPrimary : SiriColors.textSecondary))
                        .frame(width: 22, height: 22)
                        .background(isHoveringPlus && !terminalManager.entries.isEmpty ? Color.white.opacity(0.1) : Color.white.opacity(0.04))
                        .clipShape(Circle())
                        .scaleEffect(isHoveringPlus && !terminalManager.entries.isEmpty ? 1.08 : 1.0)
                        .animation(SwiftCatAnimations.spring, value: isHoveringPlus)
                }
                .buttonStyle(.plain)
                .disabled(terminalManager.entries.isEmpty)
                .onHover { isHoveringPlus = $0 }
                .help("Clear Terminal Screen")
                
                Spacer()
                
                // Toggle Maximize width
                Button(action: {
                    withAnimation(SwiftCatAnimations.spring) {
                        terminalManager.isMaximized.toggle()
                    }
                }) {
                    Image(systemName: terminalManager.isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11))
                        .foregroundColor(isHoveringExpand ? SiriColors.textPrimary : SiriColors.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(isHoveringExpand ? Color.white.opacity(0.08) : Color.clear)
                        .cornerRadius(4)
                        .scaleEffect(isHoveringExpand ? 1.08 : 1.0)
                        .animation(SwiftCatAnimations.spring, value: isHoveringExpand)
                }
                .buttonStyle(.plain)
                .onHover { isHoveringExpand = $0 }
                .help("Toggle Terminal Size")
                
                // Close Panel button
                Button(action: {
                    withAnimation(SwiftCatAnimations.spring) {
                        terminalManager.isPanelVisible = false
                    }
                }) {
                    Image(systemName: "sidebar.trailing")
                        .font(.system(size: 12))
                        .foregroundColor(isHoveringClose ? SiriColors.textPrimary : SiriColors.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(isHoveringClose ? Color.white.opacity(0.08) : Color.clear)
                        .cornerRadius(4)
                        .scaleEffect(isHoveringClose ? 1.08 : 1.0)
                        .animation(SwiftCatAnimations.spring, value: isHoveringClose)
                }
                .buttonStyle(.plain)
                .onHover { isHoveringClose = $0 }
                .help("Hide Terminal")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(SiriColors.sidebarBackground)
            
            Divider()
                .background(SiriColors.border)
            
            // Terminal Output and Active Prompt Area
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        // History of Executed Commands
                        ForEach(terminalManager.entries) { entry in
                            let isActiveEntry = terminalManager.isRunningCommand && entry.id == terminalManager.entries.last?.id
                            TerminalEntryRow(
                                entry: entry,
                                isRunning: isActiveEntry,
                                onAskAI: onAskAI
                            )
                        }
                        
                        // Active Interactive Prompt Line
                        HStack(spacing: 6) {
                            Text(terminalManager.promptString)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(Color.cyan.opacity(0.85))
                            
                            TextField("", text: $terminalManager.commandInput)
                                .focused($isInputFocused)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(SiriColors.textPrimary)
                                .onSubmit {
                                    terminalManager.runCurrentCommand()
                                }
                                .onKeyPress(.upArrow) {
                                    terminalManager.navigateHistory(up: true)
                                    return .handled
                                }
                                .onKeyPress(.downArrow) {
                                    terminalManager.navigateHistory(up: false)
                                    return .handled
                                }
                            
                            if terminalManager.isRunningCommand {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 14, height: 14)
                                
                                Button(action: { terminalManager.cancelRunningCommand() }) {
                                    Image(systemName: "stop.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundColor(Color.red.opacity(0.85))
                                }
                                .buttonStyle(.plain)
                                .help("Stop running command")
                            } else {
                                Text("█")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(Color.white.opacity(0.75))
                            }
                        }
                        .id("bottom_prompt")
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(red: 0.07, green: 0.07, blue: 0.08))
                .onAppear {
                    isInputFocused = true
                }
                .onChange(of: terminalManager.entries.count) {
                    withAnimation(SwiftCatAnimations.spring) {
                        proxy.scrollTo("bottom_prompt", anchor: .bottom)
                    }
                }
                .onChange(of: terminalManager.entries.last?.output) {
                    // Follow live output of the running command.
                    proxy.scrollTo("bottom_prompt", anchor: .bottom)
                }
                .onChange(of: terminalManager.isRunningCommand) {
                    withAnimation(SwiftCatAnimations.spring) {
                        proxy.scrollTo("bottom_prompt", anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundColor(SiriColors.border),
            alignment: .leading
        )
    }
}

private struct TerminalEntryRow: View {
    let entry: TerminalEntry
    let isRunning: Bool
    let onAskAI: ((String) -> Void)?
    
    @State private var copied = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.prompt)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.cyan.opacity(0.85))
                
                Text(entry.command)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(SiriColors.textPrimary)
                
                Spacer()
                
                if !isRunning && entry.exitCode != 0 {
                    Text("exit \(entry.exitCode)")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(.red.opacity(0.95))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.red.opacity(0.14))
                        .cornerRadius(4)
                }
                
                if !isRunning && !entry.output.isEmpty {
                    Button(action: {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(TerminalManager.stripANSI(entry.output), forType: .string)
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copied = false
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 9.5))
                            Text(copied ? "Copied" : "Copy")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(copied ? .green : SiriColors.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            if !entry.output.isEmpty {
                Text(TerminalManager.renderANSI(
                    entry.output,
                    defaultColor: entry.exitCode == 0 ? Color(white: 0.88) : Color.red.opacity(0.9),
                    useCache: !isRunning
                ))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(.leading, 2)
            }
            
            if entry.exitCode != 0,
               !isRunning,
               let onAskAI {
                Button(action: {
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                    let cleanOutput = TerminalManager.stripANSI(entry.output)
                    let snippet = cleanOutput.count > 4000 ? String(cleanOutput.suffix(4000)) : cleanOutput
                    let prompt = """
                    Command `\(entry.command)` failed with exit code \(entry.exitCode):
                    ```
                    \(snippet)
                    ```
                    Diagnose the error and fix it.
                    """
                    onAskAI(prompt)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9.5))
                        Text("Ask AI to Fix (exit \(entry.exitCode))")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundColor(.cyan)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.cyan.opacity(0.12))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }
}
