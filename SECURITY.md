# Security policy

## Reporting a vulnerability

Please report security problems privately through GitHub:
**[Report a vulnerability](https://github.com/infarmor/SwiftCat/security/advisories/new)**.

Include what you found, how to reproduce it, and the version or commit. You will get a reply as soon as possible, and a fix will be published before the details are.

Please do not open a public issue for a security problem.

## What is in scope

SwiftCat runs on your Mac, writes files and runs shell commands on your behalf, so these matter most:

- writing or reading files outside the attached workspace
- running commands without the user pressing Run
- leaking API keys or conversation history

## Known limitations

- The OpenRouter API key is stored in the app's preferences (UserDefaults), not the Keychain. This is on the [roadmap](README.md#roadmap).
- The integrated terminal runs commands with your user's permissions.
