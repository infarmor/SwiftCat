import Foundation
import Testing
@testable import SwiftCat

// MARK: - StreamChunkRouter

private func route(_ chunks: [String]) -> (content: String, reasoning: String, firstContentAfter: Int?) {
    let router = StreamChunkRouter()
    var firstContentAfter: Int?
    for (index, chunk) in chunks.enumerated() {
        router.feedDelta(content: chunk, reasoning: nil, onReasoning: { _ in }, onContent: { _ in
            if firstContentAfter == nil { firstContentAfter = index }
        })
    }
    let result = router.finish(onReasoning: { _ in }, onContent: { _ in })
    return (result.content, result.reasoning, firstContentAfter)
}

@Test func routerSeparatesThinkBlock() {
    let result = route(["<think>plan</think>answer"])
    #expect(result.content == "answer")
    #expect(result.reasoning == "plan")
}

@Test func routerHandlesTagsSplitAcrossChunks() {
    let result = route(["Hi <th", "ink>pl", "an</thi", "nk> done"])
    #expect(result.content == "Hi  done")
    #expect(result.reasoning == "plan")
}

@Test func routerDoesNotStallOnLoneAngleBracket() {
    // "<" that is not the start of a tag must be shown immediately, not held until a ">" arrives.
    let result = route(["if a < b then", " more"])
    #expect(result.content == "if a < b then more")
    #expect(result.firstContentAfter == 0)
}

@Test func routerKeepsOtherTagsAsContent() {
    let result = route(["<write_file path=\"a.txt\">x</write_file>"])
    #expect(result.content == "<write_file path=\"a.txt\">x</write_file>")
    #expect(result.reasoning.isEmpty)
}

@Test func routerFlushesUnclosedThinkBlockAsReasoning() {
    let result = route(["<think>never closed"])
    #expect(result.content.isEmpty)
    #expect(result.reasoning == "never closed")
}

// MARK: - DiffEngine

@Test func diffMarksAddedAndRemovedLines() {
    let diff = DiffEngine.computeDiff(oldText: "a\nb\nc", newText: "a\nx\nc")
    #expect(diff.filter { $0.kind == .added }.map(\.text) == ["x"])
    #expect(diff.filter { $0.kind == .removed }.map(\.text) == ["b"])
    #expect(diff.filter { $0.kind == .same }.map(\.text) == ["a", "c"])
}

@Test func diffOfIdenticalTextHasNoChanges() {
    let diff = DiffEngine.computeDiff(oldText: "a\nb", newText: "a\nb")
    #expect(diff.allSatisfy { $0.kind == .same })
}

@Test func diffHandlesLargeFilesWithSmallMiddleEdit() {
    var oldLines = (1...2000).map { "line \($0)" }
    var newLines = oldLines
    oldLines[1000] = "before"
    newLines[1000] = "after"
    
    let diff = DiffEngine.computeDiff(
        oldText: oldLines.joined(separator: "\n"),
        newText: newLines.joined(separator: "\n")
    )
    #expect(diff.filter { $0.kind == .same }.count == 1999)
    #expect(diff.filter { $0.kind == .removed }.map(\.text) == ["before"])
    #expect(diff.filter { $0.kind == .added }.map(\.text) == ["after"])
}

// MARK: - AgentManager

@MainActor
private func makeWorkspace() throws -> (manager: AgentManager, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftCatTests-\(UUID().uuidString)")
        .appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let manager = AgentManager()
    manager.currentWorkspaceURL = root
    return (manager, root)
}

@MainActor @Test func writeFileCreatesNestedFileInsideWorkspace() throws {
    let (manager, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    
    try manager.writeFile(relativePath: "/src/app/main.txt", content: "hello")
    #expect(manager.readFileContent(relativePath: "src/app/main.txt") == "hello")
    #expect(manager.fileCount == 1)
}

@MainActor @Test func writeFileRejectsPathsOutsideWorkspace() throws {
    let (manager, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    
    #expect(throws: AgentError.self) {
        try manager.writeFile(relativePath: "../escaped.txt", content: "nope")
    }
    #expect(throws: AgentError.self) {
        try manager.writeFile(relativePath: "a/../../escaped.txt", content: "nope")
    }
    let escaped = root.deletingLastPathComponent().appendingPathComponent("escaped.txt")
    #expect(!FileManager.default.fileExists(atPath: escaped.path))
    #expect(manager.readFileContent(relativePath: "../../etc/hosts") == nil)
}

@MainActor @Test func findRelevantFilesMatchesNamesContainingIgnoredWords() throws {
    let (manager, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    
    // "Router" contains "out", which is also an ignored directory name.
    try manager.writeFile(relativePath: "Router.swift", content: "struct Router {}")
    try manager.writeFile(relativePath: "node_modules/pkg/Router.swift", content: "ignored")
    
    let found = manager.findRelevantFiles(in: "explain Router.swift please")
    #expect(found == ["Router.swift": "struct Router {}"])
}

@MainActor @Test func extractsFileProposalsFromBothFormats() {
    let manager = AgentManager()
    let text = """
    Intro
    <write_file path="a/one.swift">
    let one = 1
    </write_file>
    ```file:b/two.txt
    two
    ```
    """
    let proposals = manager.extractFileProposals(from: text)
    #expect(proposals.map(\.path) == ["a/one.swift", "b/two.txt"])
    #expect(proposals.map(\.content) == ["let one = 1", "two"])
}

@MainActor @Test func extractsReadFileRequestsAndDeletesFiles() throws {
    let (manager, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    
    try manager.writeFile(relativePath: "src/ab.swift", content: "let x = 1")
    // Even short filename ("ab.swift") is resolved via explicit @mention
    let found = manager.findRelevantFiles(in: "Check @src/ab.swift please")
    #expect(found["src/ab.swift"] == "let x = 1")
    
    let reads = manager.extractReadRequests(from: """
    Need context:
    <read_file path="src/ab.swift" />
    <read_file path="src/other.swift"></read_file>
    """)
    #expect(reads == ["src/ab.swift", "src/other.swift"])
    
    try manager.deleteFile(relativePath: "src/ab.swift")
    #expect(manager.readFileContent(relativePath: "src/ab.swift") == nil)
}

@MainActor @Test func backupAndRevertHandlesModifiedAndNewFiles() throws {
    let (manager, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    
    // 1. Editing an existing file captures pre-write content for revert
    try manager.writeFile(relativePath: "App.swift", content: "v1")
    try manager.writeFile(relativePath: "App.swift", content: "v2")
    let modSnap = manager.backupSnapshot(for: "App.swift", proposedContent: "v2")
    #expect(modSnap == FileBackupSnapshot(existed: true, content: "v1"))
    
    try manager.revertFile(relativePath: "App.swift", to: "v2")
    #expect(manager.readFileContent(relativePath: "App.swift") == "v1")
    #expect(manager.backupSnapshot(for: "App.swift", proposedContent: "v2") == nil)
    
    // 2. Reverting a newly created file deletes it from disk
    try manager.writeFile(relativePath: "BrandNew.swift", content: "new")
    let newSnap = manager.backupSnapshot(for: "BrandNew.swift", proposedContent: "new")
    #expect(newSnap == FileBackupSnapshot(existed: false, content: ""))
    
    try manager.revertFile(relativePath: "BrandNew.swift", to: "new")
    #expect(manager.readFileContent(relativePath: "BrandNew.swift") == nil)
}

@MainActor @Test func findRelevantFilesRetainsMultiTurnContext() throws {
    let (manager, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    
    try manager.writeFile(relativePath: "Service.swift", content: "class Service {}")
    let found = manager.findRelevantFiles(inMessages: [
        "Explain @Service.swift",
        "Now add error handling to it"
    ])
    #expect(found["Service.swift"] == "class Service {}")
}

// MARK: - Terminal helpers

@Test func stripAndRenderANSIHandlesColorsAndCarriageReturns() {
    let raw = "\u{1B}[32mPASS\u{1B}[0m\r\nstep 1\rstep 2"
    #expect(TerminalManager.stripANSI(raw) == "PASS\nstep 2")
    
    let rendered = TerminalManager.renderANSI("\u{1B}[31mFAIL\u{1B}[0m", defaultColor: .white)
    #expect(String(rendered.characters) == "FAIL")
}

@Test func utf8DecodingCarriesSplitCharacterToNextChunk() {
    let bytes = Array("привет".utf8)
    var pending = Data(bytes.prefix(3)) // "п" plus half of "р"
    #expect(TerminalManager.decodeUTF8Prefix(of: &pending) == "п")
    #expect(pending.count == 1)
    pending.append(contentsOf: bytes.dropFirst(3))
    #expect(TerminalManager.decodeUTF8Prefix(of: &pending) == "ривет")
    #expect(pending.isEmpty)
}

@Test func cdArgumentIsUnquoted() {
    #expect(TerminalManager.unquoted("\"My Folder\"") == "My Folder")
    #expect(TerminalManager.unquoted("'x y'") == "x y")
    #expect(TerminalManager.unquoted("My\\ Folder") == "My Folder")
}

// MARK: - LLM error parsing

@MainActor @Test func errorMessageIsExtractedFromJSONBody() {
    #expect(LLMService.errorMessage(fromBody: #"{"error":{"message":"Invalid key","code":401}}"#) == "Invalid key")
    #expect(LLMService.errorMessage(fromBody: #"{"error":"model not found"}"#) == "model not found")
    #expect(LLMService.errorMessage(fromBody: "plain text") == "plain text")
}

// MARK: - Reply parsing

@Test func parserSplitsProseCodeAndFileWrites() {
    let blocks = ContentBlockParser.parse("""
    Intro
    ```swift
    let a = 1
    ```
    <read_file path="src/helper.swift" />
    <write_file path="src/a.txt">
    hello
    </write_file>
    """)
    #expect(blocks == [
        .text("Intro\n"),
        .code(language: "swift", code: "let a = 1\n"),
        .text("\n"),
        .fileRead(path: "src/helper.swift"),
        .text("\n"),
        .fileWrite(path: "src/a.txt", content: "hello")
    ])
}

@Test func parserTreatsFilePrefixedFenceAsFileWrite() {
    let blocks = ContentBlockParser.parse("```file:b/two.txt\ntwo\n```")
    #expect(blocks == [.fileWrite(path: "b/two.txt", content: "two")])
}

@Test func parserAcceptsLanguagesWithSymbols() {
    let blocks = ContentBlockParser.parse("```c++\nint x;\n```")
    #expect(blocks == [.code(language: "c++", code: "int x;\n")])
}

@Test func parserShowsUnfinishedBlocksAsCodeWhileStreaming() {
    #expect(ContentBlockParser.parse("Here:\n```swift\nlet a") == [
        .text("Here:\n"),
        .code(language: "swift", code: "let a")
    ])
    #expect(ContentBlockParser.parse("<write_file path=\"a/b.py\">\nprint(1)") == [
        .code(language: "py", code: "print(1)")
    ])
    // The opening tag itself has not finished arriving: show nothing yet.
    #expect(ContentBlockParser.parse("Text <write_file pa") == [.text("Text ")])
    #expect(ContentBlockParser.parse("Checking <read_file pa") == [.text("Checking ")])
}

@MainActor @Test func fileCardContentMatchesWhatAutoApplyWrites() {
    let reply = "<write_file path=\"a.txt\">\nline\n\n</write_file>"
    let proposals = AgentManager().extractFileProposals(from: reply)
    #expect(ContentBlockParser.parse(reply) == [.fileWrite(path: "a.txt", content: proposals[0].content)])
}

// MARK: - Rendering

private func plainText(_ attributed: AttributedString) -> String {
    String(attributed.characters)
}

@Test func markdownRendersInlineStylesHeadingsAndBullets() {
    let rendered = MarkdownRenderer.render("# Title\nSome **bold** and `code`\n- item one\n\nlast", useCache: false)
    #expect(plainText(rendered) == "Title\nSome bold and code\n•  item one\n\nlast")
}

@Test func markdownRendersNumberedListsQuotesAndDividers() {
    let rendered = MarkdownRenderer.render("1. first\n> note\n---", useCache: false)
    #expect(plainText(rendered) == "1.  first\n▎ note\n────────────────────────")
}

@Test func markdownLeavesUnbalancedMarkersReadable() {
    let rendered = MarkdownRenderer.render("a ** b and 2 * 3", useCache: false)
    #expect(plainText(rendered) == "a ** b and 2 * 3")
}

@Test func highlighterPreservesCodeAndDoesNotTreatStringContentAsComment() {
    let code = "let url = \"http://example.com\" // note\nlet n = 42"
    let highlighted = SyntaxHighlighter.highlight(code: code, language: "swift")
    #expect(plainText(highlighted) == code)
    
    // The whole string literal is one run, so the "//" inside it started no comment.
    let runs = highlighted.runs.map { String(highlighted[$0.range].characters) }
    #expect(runs.contains("\"http://example.com\""))
    #expect(runs.contains("// note"))
}

@Test func highlighterKeepsSwiftHashDirectivesOutOfComments() {
    let highlighted = SyntaxHighlighter.highlight(code: "#if DEBUG\nlet x = 1\n#endif", language: "swift")
    let runs = highlighted.runs.map { String(highlighted[$0.range].characters) }
    #expect(!runs.contains("#if DEBUG"))
    
    let shell = SyntaxHighlighter.highlight(code: "ls # list", language: "bash")
    #expect(shell.runs.map { String(shell[$0.range].characters) }.contains("# list"))
}

@Test func highlighterHandlesBlockCommentsAndMultilineStrings() {
    let code = """
    /* multi
       line */
    let s = \"\"\"
    // inside string
    \"\"\"
    """
    let highlighted = SyntaxHighlighter.highlight(code: code, language: "swift")
    #expect(plainText(highlighted) == code)
    let runs = highlighted.runs.map { String(highlighted[$0.range].characters) }
    #expect(runs.contains("/* multi\n   line */"))
    #expect(runs.contains("\"\"\"\n// inside string\n\"\"\""))
}

@Test func sidebarMarkdownExportFormatsMetadataAndReasoning() {
    let convo = Conversation(
        title: "Debug Build",
        messages: [
            ChatMessage(role: .user, content: "Why did tests fail?"),
            ChatMessage(
                role: .assistant,
                content: "Missing import in `Main.swift`.",
                reasoning: "Checked build output for missing symbols."
            )
        ],
        workspacePath: "/tmp/DemoRepo"
    )
    
    let markdown = SidebarView.markdownExport(for: convo)
    #expect(markdown.contains("# Debug Build"))
    #expect(markdown.contains("_Workspace: `/tmp/DemoRepo`_"))
    #expect(markdown.contains("## User\n\nWhy did tests fail?"))
    #expect(markdown.contains("## Assistant"))
    #expect(markdown.contains("<details><summary>Reasoning</summary>\n\nChecked build output for missing symbols.\n\n</details>"))
    #expect(markdown.contains("Missing import in `Main.swift`."))
}

@Test func contentBlockParserCacheMatchesUncachedParse() {
    let sample = """
    Intro text.

    ```swift
    let x = 1
    ```

    <read_file path="Sources/App.swift" />
    """
    let uncached = ContentBlockParser.parse(sample, useCache: false)
    let cachedFirst = ContentBlockParser.parse(sample, useCache: true)
    let cachedSecond = ContentBlockParser.parse(sample, useCache: true)
    #expect(cachedFirst.count == uncached.count)
    #expect(cachedSecond.count == uncached.count)
}

@Test func markdownRendersTaskChecklistsWithoutEmojis() {
    let rendered = MarkdownRenderer.render("- [ ] todo item\n- [x] finished item\n- [X] upper x", useCache: false)
    #expect(plainText(rendered) == "[ ] todo item\n[x] finished item\n[x] upper x")
}

@MainActor @Test func writeFilesBatchesRefreshAndReportsMixedResults() throws {
    let (manager, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    
    let initialGeneration = manager.writeGeneration
    let outcome = manager.writeFiles([
        (path: "a.swift", content: "let a = 1"),
        (path: "../escape.txt", content: "bad"),
        (path: "nested/b.swift", content: "let b = 2")
    ])
    
    #expect(outcome.saved == ["a.swift", "nested/b.swift"])
    #expect(outcome.errors.count == 1)
    #expect(manager.writeGeneration == initialGeneration + 1)
    #expect(manager.fileCount == 2)
    #expect(manager.lastActionNotification?.hasPrefix("Could not save:") == true)
    
    let okOutcome = manager.writeFiles([
        (path: "c.swift", content: "let c = 3"),
        (path: "d.swift", content: "let d = 4")
    ])
    #expect(okOutcome.errors.isEmpty)
    #expect(manager.lastActionNotification == "Saved 2 files")
}

@MainActor @Test func findRelevantFilesMatchesStemsAndRelativeWorkspacePath() throws {
    let (manager, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    
    try manager.writeFile(relativePath: "Sources/TerminalManager.swift", content: "final class TerminalManager {}")
    try manager.writeFile(relativePath: "Sources/Helper.swift", content: "struct Helper {}")
    // Ignored build folder files must not leak into tree or matches.
    let targetDir = root.appendingPathComponent("target", isDirectory: true)
    try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
    try "ignored".write(to: targetDir.appendingPathComponent("TerminalManager.rs"), atomically: true, encoding: .utf8)
    
    let matched = manager.findRelevantFiles(inMessages: ["Please check TerminalManager for cancellation bugs"])
    #expect(matched["Sources/TerminalManager.swift"] == "final class TerminalManager {}")
    #expect(matched["target/TerminalManager.rs"] == nil)
    
    let insideURL = root.appendingPathComponent("Sources/Helper.swift")
    let outsideURL = root.deletingLastPathComponent().appendingPathComponent("Outside.swift")
    #expect(manager.relativeWorkspacePath(for: insideURL) == "Sources/Helper.swift")
    #expect(manager.relativeWorkspacePath(for: outsideURL) == nil)
}

@Test func cleanLocalModelNameStripsRegistryTagsAndGgufVariants() {
    let raw = "hf.co/mradermacher/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic-GGUF:Q4_K_M"
    #expect(LLMService.cleanLocalModelName(raw) == "DeepSeek-V4-Pro-Qwen3.5-9B")
    #expect(LLMService.cleanLocalModelName("qwen2.5-coder:7b") == "qwen2.5-coder")
}

@Test func diffHandlesMultipleSeparatedEditsWithExactLineNumbers() {
    let oldText = "1\n2\n3\n4\n5\n6"
    let newText = "1\n2a\n3\n4\n5b\n6"
    let diff = DiffEngine.computeDiff(oldText: oldText, newText: newText)
    
    #expect(diff.filter { $0.kind == .removed }.map(\.text) == ["2", "5"])
    #expect(diff.filter { $0.kind == .added }.map(\.text) == ["2a", "5b"])
    #expect(diff.filter { $0.kind == .same }.map(\.text) == ["1", "3", "4", "6"])
    #expect(diff.last?.oldLineNum == 6 && diff.last?.newLineNum == 6)
}
