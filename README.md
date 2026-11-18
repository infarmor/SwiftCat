# SwiftCat

A native macOS AI coding assistant with an integrated terminal. Chat with a model, let it propose changes to your project, review them as diffs, and apply them with one click.

Built with SwiftUI. No Electron, no web view.

## Features

- **Three model backends**: Apple Intelligence (on-device, via FoundationModels), local servers (Ollama, LM Studio, llama.cpp or any OpenAI-compatible endpoint), and [OpenRouter](https://openrouter.ai) for cloud models.
- **Workspace-aware**: attach a project folder and the model sees its file tree and any files you mention by name.
- **Reviewable file changes**: the model proposes `<write_file>` blocks; each one becomes a card with a line diff and an Apply button. Writes are confined to the attached folder.
- **Integrated terminal**: run the shell commands from a reply with one click. Output streams live and a running command can be stopped.
- **Streaming with reasoning**: `<think>` blocks and dedicated reasoning fields are shown separately from the answer.
- **Markdown replies** with syntax-highlighted code blocks.
- **Local history**: conversations are stored as JSON in `~/Library/Application Support/SwiftCat/`.

## Requirements

- macOS 26 or later
- Xcode 26 or later (Swift 6 toolchain)
- Apple Intelligence enabled, only if you want to use the on-device model

## Build and run

```bash
git clone https://github.com/infarmor/SwiftCat.git
cd SwiftCat
swift run SwiftCat
```

To build a proper app bundle and install it into `~/Applications`:

```bash
./build_app.sh
open ~/Applications/SwiftCat.app
```

Run the tests:

```bash
swift test
```

## Configuration

Open Settings (`⌘,`).

| Backend | Setup |
| --- | --- |
| Apple Intelligence | Nothing to configure. |
| Local server | Set the endpoint (default `http://localhost:11434/v1`). Detected models are added automatically. |
| OpenRouter | Paste your API key. |

The OpenRouter key is stored in the app's preferences (UserDefaults), not in the Keychain.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘N` | New conversation |
| `⌘K` | Clear current conversation |
| `⌘J` | Toggle terminal |
| `⇧⌘O` | Attach project folder |
| `⌘,` | Settings |
| `⌥↩` | Line break in the input |

Type `/` in the input for slash commands (`/git`, `/diff`, `/files`, `/agent`, `/clear`).

## Project layout

```
Sources/SwiftCat/
  LLMService.swift          model backends and streaming
  StreamChunkRouter.swift   splits reasoning from answer
  AgentManager.swift        workspace, file reading and safe writes
  TerminalManager.swift     command execution
  MessageRendering.swift    reply parsing and Markdown
  ConversationStore.swift   history persistence
  Views/                    SwiftUI views
Tests/SwiftCatTests/        unit tests
```

## Safety notes

- File proposals are never written until you press Apply, unless you turn on auto-apply.
- Paths from model output are rejected if they resolve outside the attached workspace.
- The terminal runs commands as you, with your permissions. Read a command before running it.

## License

[MIT](LICENSE)
