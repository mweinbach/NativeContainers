import Foundation
import Observation

@MainActor
@Observable
final class TerminalWorkspaceTabModel: Identifiable {
  nonisolated let id: UUID
  let descriptor: TerminalTabDescriptor
  let title: String
  let terminal: ContainerTerminalModel
  let request: ContainerTerminalRequest?
  private(set) var hasStarted = false

  init(
    descriptor: TerminalTabDescriptor,
    title: String,
    terminal: ContainerTerminalModel,
    request: ContainerTerminalRequest?
  ) {
    id = descriptor.id
    self.descriptor = descriptor
    self.title = title
    self.terminal = terminal
    self.request = request
  }

  func startIfNeeded() async {
    guard !hasStarted else { return }
    hasStarted = true
    await terminal.connect(request: request)
  }

  @discardableResult
  func close() async -> Bool {
    await terminal.close()
  }
}

@MainActor
@Observable
final class TerminalWorkspaceModel {
  private(set) var tabs: [TerminalWorkspaceTabModel] = []
  var selectedTabID: UUID?
  private(set) var presets: [TerminalPreset] = []
  private(set) var isLoading = false
  private(set) var errorMessage: String?

  let windowRequest: TerminalWindowRequest

  private let presetStore: any TerminalPresetManaging
  private let snapshotCodec: TerminalWorkspaceSnapshotCodec
  private let makeTerminal: @MainActor @Sendable (TerminalTargetIdentity) -> ContainerTerminalModel
  private var hasRestored = false

  init(
    windowRequest: TerminalWindowRequest,
    presetStore: any TerminalPresetManaging,
    snapshotCodec: TerminalWorkspaceSnapshotCodec = TerminalWorkspaceSnapshotCodec(),
    makeTerminal:
      @escaping @MainActor @Sendable (TerminalTargetIdentity) -> ContainerTerminalModel
  ) {
    self.windowRequest = windowRequest
    self.presetStore = presetStore
    self.snapshotCodec = snapshotCodec
    self.makeTerminal = makeTerminal
  }

  var selectedTab: TerminalWorkspaceTabModel? {
    guard let selectedTabID else { return tabs.first }
    return tabs.first { $0.id == selectedTabID } ?? tabs.first
  }

  var supportsPresets: Bool {
    windowRequest.target.supportsContainerPresets
  }

  var snapshot: TerminalWorkspaceSnapshot {
    TerminalWorkspaceSnapshot(
      workspaceID: windowRequest.id,
      tabs: tabs.map(\.descriptor),
      selectedTabID: selectedTab?.id
    )
  }

  func restore(from encodedSnapshot: Data?) async {
    guard !hasRestored else { return }
    hasRestored = true
    isLoading = true
    defer { isLoading = false }

    await reloadPresets()

    let descriptors: [TerminalTabDescriptor]
    let restoredSelection: UUID?
    if let encodedSnapshot {
      do {
        let restored = try snapshotCodec.decode(
          encodedSnapshot,
          workspaceID: windowRequest.id
        )
        descriptors = sanitize(restored.tabs)
        restoredSelection = restored.selectedTabID
      } catch {
        errorMessage = error.localizedDescription
        descriptors = [TerminalTabDescriptor()]
        restoredSelection = nil
      }
    } else {
      descriptors = [TerminalTabDescriptor()]
      restoredSelection = nil
    }

    tabs = descriptors.enumerated().map { index, descriptor in
      makeTab(descriptor: descriptor, ordinal: index + 1)
    }
    if tabs.isEmpty {
      tabs = [makeTab(descriptor: TerminalTabDescriptor(), ordinal: 1)]
    }
    selectedTabID =
      restoredSelection.flatMap { candidate in
        tabs.contains(where: { $0.id == candidate }) ? candidate : nil
      } ?? tabs.first?.id
  }

  func encodeSnapshot() -> Data? {
    do {
      return try snapshotCodec.encode(snapshot)
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func addTab(presetID: UUID? = nil) {
    guard tabs.count < TerminalWorkspaceSnapshot.maximumTabCount else {
      errorMessage = String(
        localized:
          "A terminal window can keep up to \(TerminalWorkspaceSnapshot.maximumTabCount) tabs."
      )
      return
    }
    let descriptor = TerminalTabDescriptor(
      presetID: supportsPresets ? presetID : nil
    )
    let tab = makeTab(descriptor: descriptor, ordinal: tabs.count + 1)
    tabs.append(tab)
    selectedTabID = tab.id
  }

  func closeTab(id: UUID) async {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    let tab = tabs[index]
    guard await tab.close() else {
      errorMessage = tab.terminal.errorMessage
      return
    }

    tabs.remove(at: index)
    if tabs.isEmpty {
      let replacement = makeTab(
        descriptor: TerminalTabDescriptor(),
        ordinal: 1
      )
      tabs = [replacement]
      selectedTabID = replacement.id
      return
    }
    if selectedTabID == id {
      selectedTabID = tabs[min(index, tabs.count - 1)].id
    }
  }

  func closeAll() async {
    for tab in tabs {
      _ = await tab.close()
    }
  }

  func startSelectedTabIfNeeded() async {
    await selectedTab?.startIfNeeded()
  }

  @discardableResult
  func savePreset(_ preset: TerminalPreset) async -> Bool {
    do {
      try await presetStore.savePreset(preset)
      await reloadPresets()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func deletePreset(id: UUID) async -> Bool {
    do {
      try await presetStore.deletePreset(id: id)
      await reloadPresets()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func clearError() {
    errorMessage = nil
  }

  private func reloadPresets() async {
    do {
      presets = try await presetStore.listPresets()
    } catch {
      presets = []
      errorMessage = error.localizedDescription
    }
  }

  private func sanitize(_ descriptors: [TerminalTabDescriptor])
    -> [TerminalTabDescriptor]
  {
    var identifiers: Set<UUID> = []
    return descriptors.prefix(TerminalWorkspaceSnapshot.maximumTabCount).compactMap {
      descriptor in
      guard identifiers.insert(descriptor.id).inserted else { return nil }
      if supportsPresets {
        return descriptor
      }
      return TerminalTabDescriptor(id: descriptor.id)
    }
  }

  private func makeTab(
    descriptor: TerminalTabDescriptor,
    ordinal: Int
  ) -> TerminalWorkspaceTabModel {
    let preset = descriptor.presetID.flatMap { presetID in
      presets.first { $0.id == presetID }
    }
    if descriptor.presetID != nil, preset == nil {
      errorMessage = String(
        localized:
          "A restored terminal preset is no longer available. The preferred shell will be used."
      )
    }

    let request: ContainerTerminalRequest?
    if supportsPresets, let preset {
      do {
        request = try preset.makeRequest()
      } catch {
        errorMessage = error.localizedDescription
        request = nil
      }
    } else {
      request = nil
    }

    return TerminalWorkspaceTabModel(
      descriptor: descriptor,
      title: preset?.name ?? String(localized: "Shell \(ordinal)"),
      terminal: makeTerminal(windowRequest.target),
      request: request
    )
  }
}
