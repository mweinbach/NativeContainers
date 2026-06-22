import Foundation
import Testing

@testable import NativeContainers

@MainActor
@Suite("Terminal workspace model")
struct TerminalWorkspaceModelTests {
  @Test
  func restoresPresetAndStartsOnlyTheSelectedTab() async throws {
    let preset = try TerminalPreset(
      name: "Bash workspace",
      program: .executable("/bin/bash"),
      launchesAsLoginShell: true,
      workingDirectory: "/src"
    )
    let store = EphemeralTerminalPresetStore(presets: [preset])
    let recorder = WorkspaceTerminalRecorder()
    let request = makeWindowRequest()
    let first = TerminalTabDescriptor()
    let selected = TerminalTabDescriptor(presetID: preset.id)
    let snapshot = TerminalWorkspaceSnapshot(
      workspaceID: request.id,
      tabs: [first, selected],
      selectedTabID: selected.id
    )
    let model = makeModel(request: request, store: store, recorder: recorder)

    await model.restore(from: try TerminalWorkspaceSnapshotCodec().encode(snapshot))
    #expect(await recorder.requests.isEmpty)
    await model.startSelectedTabIfNeeded()

    #expect(model.tabs.count == 2)
    #expect(model.selectedTabID == selected.id)
    #expect(model.selectedTab?.title == "Bash workspace")
    #expect(await recorder.requests.count == 1)
    #expect(await recorder.requests.first?.program == .executable("/bin/bash"))
    #expect(await recorder.requests.first?.arguments == ["-l"])
    #expect(await recorder.requests.first?.workingDirectory == "/src")
    await model.closeAll()
  }

  @Test
  func addsSelectsAndClosesTabsWithoutDroppingTheWorkspace() async {
    let store = EphemeralTerminalPresetStore()
    let recorder = WorkspaceTerminalRecorder()
    let request = makeWindowRequest()
    let model = makeModel(request: request, store: store, recorder: recorder)
    await model.restore(from: nil)
    let initialID = model.selectedTabID

    model.addTab()
    let secondID = model.selectedTabID
    model.addTab()
    let thirdID = model.selectedTabID

    #expect(model.tabs.count == 3)
    #expect(initialID != secondID)
    #expect(secondID != thirdID)

    if let thirdID {
      await model.closeTab(id: thirdID)
    }
    #expect(model.tabs.count == 2)
    #expect(model.selectedTabID != thirdID)

    for tab in model.tabs {
      await model.closeTab(id: tab.id)
    }
    #expect(model.tabs.count == 1)
    #expect(model.selectedTabID == model.tabs.first?.id)
  }

  @Test
  func sanitizesRestoredTabCountAndDuplicateIdentity() async throws {
    let store = EphemeralTerminalPresetStore()
    let recorder = WorkspaceTerminalRecorder()
    let request = makeWindowRequest()
    let duplicateID = UUID()
    var descriptors = [
      TerminalTabDescriptor(id: duplicateID),
      TerminalTabDescriptor(id: duplicateID),
    ]
    descriptors.append(
      contentsOf: (0..<TerminalWorkspaceSnapshot.maximumTabCount + 4).map { _ in
        TerminalTabDescriptor()
      }
    )
    let snapshot = TerminalWorkspaceSnapshot(
      workspaceID: request.id,
      tabs: descriptors,
      selectedTabID: duplicateID
    )
    let model = makeModel(request: request, store: store, recorder: recorder)

    await model.restore(from: try TerminalWorkspaceSnapshotCodec().encode(snapshot))

    #expect(model.tabs.count <= TerminalWorkspaceSnapshot.maximumTabCount)
    #expect(Set(model.tabs.map(\.id)).count == model.tabs.count)
    #expect(model.selectedTabID == duplicateID)
  }

  @Test
  func missingRestoredPresetFallsBackToPreferredShell() async throws {
    let store = EphemeralTerminalPresetStore()
    let recorder = WorkspaceTerminalRecorder()
    let request = makeWindowRequest()
    let tab = TerminalTabDescriptor(presetID: UUID())
    let snapshot = TerminalWorkspaceSnapshot(
      workspaceID: request.id,
      tabs: [tab],
      selectedTabID: tab.id
    )
    let model = makeModel(request: request, store: store, recorder: recorder)

    await model.restore(from: try TerminalWorkspaceSnapshotCodec().encode(snapshot))
    await model.startSelectedTabIfNeeded()

    #expect(model.errorMessage?.contains("no longer available") == true)
    #expect(await recorder.requests.first?.program == .preferredShell)
    await model.closeAll()
  }

  @Test
  func linuxWorkspaceDropsContainerOnlyPresetReferences() async throws {
    let store = EphemeralTerminalPresetStore()
    let recorder = WorkspaceTerminalRecorder()
    let identity = LinuxMachineIdentity(
      id: "dev",
      imageReference: "docker.io/library/ubuntu:24.04",
      platform: "linux/arm64",
      createdAt: Date(timeIntervalSince1970: 42)
    )
    let request = TerminalWindowRequest(target: .linuxMachine(identity))
    let descriptor = TerminalTabDescriptor(presetID: UUID())
    let snapshot = TerminalWorkspaceSnapshot(
      workspaceID: request.id,
      tabs: [descriptor],
      selectedTabID: descriptor.id
    )
    let model = makeModel(request: request, store: store, recorder: recorder)

    await model.restore(from: try TerminalWorkspaceSnapshotCodec().encode(snapshot))

    #expect(model.tabs.first?.descriptor.presetID == nil)
    #expect(!model.supportsPresets)
  }

  @Test
  func podWorkspaceRoundTripsPinnedIdentityAndDropsPresetReferences() async throws {
    let identity = KubernetesPodTerminalIdentity(
      machine: LinuxMachineIdentity(
        id: "nativecontainers-kubernetes",
        imageReference: "docker.io/library/alpine:3.22",
        platform: "linux/arm64",
        createdAt: Date(timeIntervalSince1970: 42)
      ),
      podUID: "11111111-1111-4111-8111-111111111111",
      namespace: "default",
      podName: "api-abc",
      containerName: "api"
    )
    let request = TerminalWindowRequest(target: .kubernetesPod(identity))
    let encodedRequest = try JSONEncoder().encode(request)
    let decodedRequest = try JSONDecoder().decode(
      TerminalWindowRequest.self,
      from: encodedRequest
    )
    #expect(decodedRequest == request)

    let descriptor = TerminalTabDescriptor(presetID: UUID())
    let snapshot = TerminalWorkspaceSnapshot(
      workspaceID: request.id,
      tabs: [descriptor],
      selectedTabID: descriptor.id
    )
    let model = makeModel(
      request: request,
      store: EphemeralTerminalPresetStore(),
      recorder: WorkspaceTerminalRecorder()
    )

    await model.restore(from: try TerminalWorkspaceSnapshotCodec().encode(snapshot))

    #expect(model.tabs.first?.descriptor.presetID == nil)
    #expect(!model.supportsPresets)
  }

  private func makeWindowRequest() -> TerminalWindowRequest {
    TerminalWindowRequest(
      target: .container(
        ContainerTerminalTargetIdentity(
          container: ContainerRecord(
            id: "dev",
            imageReference: "docker.io/library/alpine:3.21",
            platform: "linux/arm64",
            state: .running,
            ipAddress: nil,
            createdAt: Date(timeIntervalSince1970: 42),
            startedAt: Date(timeIntervalSince1970: 43),
            cpuCount: 2,
            memoryBytes: 512 * 1_024 * 1_024,
            ports: []
          )
        )
      )
    )
  }

  private func makeModel(
    request: TerminalWindowRequest,
    store: any TerminalPresetManaging,
    recorder: WorkspaceTerminalRecorder
  ) -> TerminalWorkspaceModel {
    TerminalWorkspaceModel(
      windowRequest: request,
      presetStore: store
    ) { target in
      ContainerTerminalModel(containerID: target.id) { _, terminalRequest in
        await recorder.open(request: terminalRequest)
      }
    }
  }
}

private actor WorkspaceTerminalRecorder {
  private(set) var requests: [ContainerTerminalRequest] = []

  func open(request: ContainerTerminalRequest) -> any ContainerTerminalSession {
    requests.append(request)
    return WorkspaceTerminalSession()
  }
}

private actor WorkspaceTerminalSession: ContainerTerminalSession {
  nonisolated let output: AsyncStream<Data>

  private let continuation: AsyncStream<Data>.Continuation
  private var lifecycle: ContainerTerminalLifecycle = .running

  init() {
    let pair = AsyncStream.makeStream(of: Data.self)
    output = pair.stream
    continuation = pair.continuation
  }

  func sendInput(_ data: Data) {}

  func resize(to size: ContainerTerminalSize) {}

  func sendSignal(_ signal: ContainerTerminalSignal) {}

  func snapshot() -> ContainerTerminalSnapshot {
    ContainerTerminalSnapshot(
      lifecycle: lifecycle,
      retainedOutput: Data(),
      outputWasTruncated: false
    )
  }

  func wait() -> Int32 {
    0
  }

  func close() {
    lifecycle = .closed
    continuation.finish()
  }
}
