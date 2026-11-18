# Contributing to SwiftCat

Thanks for helping out. Bug reports, ideas and pull requests are all welcome.

## Setup

You need macOS 26 or later and Xcode 26 or later.

```bash
git clone https://github.com/infarmor/SwiftCat.git
cd SwiftCat
swift build
swift test
```

Run the app with `swift run SwiftCat`, or `./build_app.sh` to build a bundle and install it into `~/Applications`.

## Making a change

1. Open an issue first for anything larger than a small fix, so we can agree on the approach.
2. Branch from `main`.
3. Keep the change focused. One concern per pull request.
4. Add or update tests in `Tests/SwiftCatTests` when you change behavior. Parsing, path safety and streaming logic are all covered by unit tests, and new code in those areas should be too.
5. Make sure `swift build` and `swift test` pass. CI runs both.
6. Describe what changed and why in the pull request, and how you checked it.

## Style

- Follow the surrounding code: four-space indentation, Swift 6 concurrency (`@MainActor` for UI-facing state).
- Prefer small, named helpers over long inline closures.
- Comments explain why, not what.

## Things to be careful with

- **File writes.** Anything that writes to disk must go through `AgentManager.resolveWorkspaceURL`, which keeps writes inside the attached workspace.
- **Secrets.** Never commit API keys, and do not log them.
- **Screenshots.** Check that they contain no personal data (chat history, usernames, paths) before adding them to `docs/`.

## Reporting security issues

Do not open a public issue. See [SECURITY.md](SECURITY.md).
