# Contributing

Contributions are welcome.

## Development

1. Use macOS 13 or later with Xcode Command Line Tools installed.
2. Fork the repository and create a focused branch.
3. Build with `./build.sh`.
4. Test both tile and cascade modes, global shortcuts, restore behavior, and settings persistence.
5. Open a pull request describing the user-visible behavior and verification performed.

## Guidelines

- Keep changes focused and avoid unrelated formatting.
- Use public macOS APIs; do not require disabling SIP or injecting code into other processes.
- Keep Accessibility calls off the main thread where possible.
- Do not add telemetry or network access without an explicit design discussion.
- Update `README.md` when behavior, permissions, or build steps change.

The integration test in `Tests/main.swift` manipulates real windows and requires Accessibility permission. Run it only in a disposable desktop session.
