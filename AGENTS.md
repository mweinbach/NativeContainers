# NativeContainers agent instructions

- Use Xcode MCP for every Xcode project action: scheme and destination changes,
  project settings, capabilities, builds, tests, launches, logs, and debugger
  work.
- Never invoke `xcodebuild`, launch the built app from a shell, or substitute a
  shell build/test loop when Xcode MCP is unavailable. Record the MCP failure
  and continue with work that does not require Xcode.
- Shell commands remain appropriate for source inspection, `swift-format`, Git,
  and diagnostics that do not build, test, configure, or launch the Xcode
  project.
