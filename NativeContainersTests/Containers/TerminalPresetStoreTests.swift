import Foundation
import Testing

@testable import NativeContainers

@Suite("Terminal preset persistence")
struct TerminalPresetStoreTests {
  @Test
  func roundTripsValidatedPresetsThroughNativePreferences() async throws {
    let context = makeStore()
    defer { clear(context) }
    let store = context.store
    let preset = try TerminalPreset(
      name: "Zsh login",
      program: .executable("/bin/zsh"),
      launchesAsLoginShell: true,
      workingDirectory: "/workspace"
    )

    try await store.savePreset(preset)
    let loaded = try await store.listPresets()

    #expect(loaded == [preset])
  }

  @Test
  func replacesByIdentityAndRejectsDuplicateNames() async throws {
    let context = makeStore()
    defer { clear(context) }
    let store = context.store
    let original = try TerminalPreset(name: "Development")
    let replacement = try TerminalPreset(
      id: original.id,
      name: "Development",
      program: .executable("/bin/bash"),
      launchesAsLoginShell: false
    )

    try await store.savePreset(original)
    try await store.savePreset(replacement)
    #expect(try await store.listPresets() == [replacement])

    let duplicate = try TerminalPreset(name: "development")
    await #expect(throws: TerminalWorkspaceError.duplicatePresetName("Development")) {
      try await store.savePreset(duplicate)
    }
  }

  @Test
  func rejectsCorruptOrUnboundedPersistence() async throws {
    let context = makeStore()
    defer { clear(context) }
    let store = context.store
    let defaults = UserDefaults(suiteName: context.suiteName)!
    defaults.set(Data("not-json".utf8), forKey: context.key)

    await #expect(throws: (any Error).self) {
      _ = try await store.listPresets()
    }

    defaults.set(
      Data(repeating: 0, count: TerminalPresetStore.maximumEncodedBytes + 1),
      forKey: context.key
    )
    await #expect(throws: (any Error).self) {
      _ = try await store.listPresets()
    }
  }

  @Test
  func validatesPresetFieldsAndBuildsTypedRequest() throws {
    #expect(throws: TerminalWorkspaceError.invalidPresetName) {
      _ = try TerminalPreset(name: "   ")
    }
    #expect(throws: TerminalWorkspaceError.invalidPresetExecutable) {
      _ = try TerminalPreset(name: "Broken", program: .executable("  "))
    }
    #expect(throws: TerminalWorkspaceError.invalidPresetWorkingDirectory) {
      _ = try TerminalPreset(name: "Broken", workingDirectory: "relative")
    }

    let preset = try TerminalPreset(
      name: "Bash",
      program: .executable(" /bin/bash "),
      launchesAsLoginShell: true,
      workingDirectory: " /src "
    )
    let request = try preset.makeRequest()

    #expect(request.program == .executable("/bin/bash"))
    #expect(request.arguments == ["-l"])
    #expect(request.workingDirectory == "/src")
  }

  @Test
  func restorationCodecPinsWorkspaceIdentityAndBoundsPayload() throws {
    let workspaceID = UUID()
    let snapshot = TerminalWorkspaceSnapshot(
      workspaceID: workspaceID,
      tabs: [TerminalTabDescriptor()],
      selectedTabID: nil
    )
    let codec = TerminalWorkspaceSnapshotCodec()
    let data = try codec.encode(snapshot)

    #expect(try codec.decode(data, workspaceID: workspaceID) == snapshot)
    #expect(throws: TerminalWorkspaceError.invalidRestorationState) {
      _ = try codec.decode(data, workspaceID: UUID())
    }
    #expect(throws: TerminalWorkspaceError.invalidRestorationState) {
      _ = try codec.decode(
        Data(repeating: 0, count: TerminalWorkspaceSnapshotCodec.maximumEncodedBytes + 1),
        workspaceID: workspaceID
      )
    }
  }

  private func makeStore() -> (
    store: TerminalPresetStore,
    suiteName: String,
    key: String
  ) {
    let suiteName = "NativeContainers.TerminalPresetTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let key = "presets"
    return (
      TerminalPresetStore(suiteName: suiteName, key: key),
      suiteName,
      key
    )
  }

  private func clear(
    _ context: (store: TerminalPresetStore, suiteName: String, key: String)
  ) {
    UserDefaults(suiteName: context.suiteName)?
      .removePersistentDomain(forName: context.suiteName)
  }
}
