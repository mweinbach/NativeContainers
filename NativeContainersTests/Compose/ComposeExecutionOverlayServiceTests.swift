import CryptoKit
import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite("Compose execution overlay")
struct ComposeExecutionOverlayServiceTests {
  @Test
  func convertsEveryReviewedResourceToAnExactExternalReference() throws {
    let canonical = canonicalConfiguration()
    let plan = overlayPlan(canonicalConfiguration: canonical)
    let result = try ComposeExecutionOverlayService().prepare(
      canonicalConfiguration: canonical,
      plan: plan
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: result.data) as? [String: Any]
    )
    let volumes = try #require(object["volumes"] as? [String: Any])
    let networks = try #require(object["networks"] as? [String: Any])
    let volume = try #require(volumes["data"] as? [String: Any])
    let network = try #require(networks["default"] as? [String: Any])

    #expect(volume.count == 2)
    #expect(volume["external"] as? Bool == true)
    #expect(volume["name"] as? String == "demo_data")
    #expect(network.count == 2)
    #expect(network["external"] as? Bool == true)
    #expect(network["name"] as? String == "demo_default")
    #expect(result.sha256 == overlaySHA256(result.data))
  }

  @Test
  func rejectsAnActiveResourceWithoutItsFrozenExecutionAction() throws {
    let canonical = canonicalConfiguration()
    let plan = overlayPlan(
      canonicalConfiguration: canonical,
      includeNetworkAction: false
    )

    #expect(throws: ComposeProjectLifecycleError.observedStateChanged) {
      _ = try ComposeExecutionOverlayService().prepare(
        canonicalConfiguration: canonical,
        plan: plan
      )
    }
  }

  @Test
  func rejectsUserLabelsReservedForInputSealing() {
    let canonical = Data(
      """
      {"name":"demo","services":{"web":{"image":"nginx:1.27","labels":{"com.nativecontainers.compose.input-seal":"forged"}}}}
      """.utf8
    )
    let plan = overlayPlan(
      canonicalConfiguration: canonical,
      includeResources: false
    )

    #expect(throws: ComposeProjectLifecycleError.self) {
      _ = try ComposeExecutionOverlayService().prepare(
        canonicalConfiguration: canonical,
        plan: plan
      )
    }
  }

  @Test
  func escapesCanonicalDollarTokensBeforeTheExecutionReplay() throws {
    let canonical = Data(
      """
      {"name":"demo","services":{"web":{"image":"nginx:1.27","command":"echo ${HOME} $$"}}}
      """.utf8
    )
    let result = try ComposeExecutionOverlayService().prepare(
      canonicalConfiguration: canonical,
      plan: overlayPlan(canonicalConfiguration: canonical, includeResources: false)
    )
    let object = try #require(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
    let services = try #require(object["services"] as? [String: Any])
    let web = try #require(services["web"] as? [String: Any])

    #expect(web["command"] as? String == "echo $${HOME} $$$$")
  }

  @Test
  func rewritesReviewedFileInputsAndAddsOpaqueServiceSeals() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "compose-input-overlay-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let configURL = root.appending(path: "app.conf")
    try Data("enabled=true\n".utf8).write(to: configURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)

    let canonical = Data(
      """
      {
        "name":"demo",
        "services":{"web":{"image":"nginx:1.27","configs":[{"source":"app","target":"/etc/app.conf","uid":"1000","mode":"0440"}],"secrets":[{"source":"token","target":"api-token"}]}},
        "configs":{"app":{"file":"\(configURL.path)"}},
        "secrets":{"token":{"environment":"DEMO_API_TOKEN"}}
      }
      """.utf8
    )
    let rendered = inputRenderedConfiguration(canonical)
    let source = inputSourceLease(root: root, byteCount: canonical.count)
    let vault = ComposeProjectInputVault(
      sealer: HMACComposeInputSealer(keyData: Data(repeating: 7, count: 32))
    )
    let requirements = try await vault.discover(
      source: source,
      options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
      rendered: rendered
    )
    #expect(requirements.requiredEnvironmentVariables == ["DEMO_API_TOKEN"])
    #expect(requirements.inputs.map(\.sourceKind) == [.file, .environment])
    #expect(requirements.issues.contains { $0.severity == .warning && $0.code == .inputPolicy })

    let prepared = try await vault.prepare(
      requirementsID: requirements.id,
      inputs: ComposeProjectReviewInputs(
        requirementsID: requirements.id,
        environmentValues: ["DEMO_API_TOKEN": "super-secret-value"]
      ),
      source: source,
      options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
      rendered: rendered
    )
    let inputSeal = try #require(prepared.serviceSeals["web"])
    let plan = overlayPlan(
      canonicalConfiguration: canonical,
      inputSeal: inputSeal,
      includeResources: false
    )
    try await vault.bind(token: prepared.token, to: plan.id)
    let payload = try await vault.consume(for: plan)
    let workspace = FileComposeExecutionWorkspace(
      rootURL: root.appending(path: "execution", directoryHint: .isDirectory)
    )
    let staged = try workspace.stageInputs(projectName: "demo", files: payload.files)
    let result = try ComposeExecutionOverlayService().prepare(
      canonicalConfiguration: canonical,
      plan: plan,
      reviewedInputs: payload,
      stagedFileURLs: staged
    )
    let object = try #require(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
    let services = try #require(object["services"] as? [String: Any])
    let web = try #require(services["web"] as? [String: Any])
    let labels = try #require(web["labels"] as? [String: Any])
    let configs = try #require(object["configs"] as? [String: Any])
    let app = try #require(configs["app"] as? [String: Any])
    let secrets = try #require(object["secrets"] as? [String: Any])
    let token = try #require(secrets["token"] as? [String: Any])

    #expect(labels[ComposeLabelKey.inputSeal] as? String == inputSeal)
    #expect(
      labels[ComposeLabelKey.reviewedConfigHash] as? String
        == rendered.serviceConfigurationHashes["web"]
    )
    #expect((app["file"] as? String)?.hasPrefix(root.path) == true)
    #expect(token["environment"] as? String == "DEMO_API_TOKEN")
    #expect(!String(decoding: result.data, as: UTF8.self).contains("super-secret-value"))
    let stagedURL = try #require(staged.values.first)
    #expect(try Data(contentsOf: stagedURL) == Data("enabled=true\n".utf8))
    let attributes = try FileManager.default.attributesOfItem(atPath: stagedURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o400)
    #expect(!stagedURL.lastPathComponent.contains("app"))
  }

  @Test
  func rejectsAStoredInputWhoseModeIsNoLongerReadOnly() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "compose-input-mode-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let data = Data("secret".utf8)
    let digest = overlaySHA256(data)
    let file = ComposeExecutionInputFile(
      id: String(repeating: "a", count: 64),
      data: data,
      sha256: digest
    )
    let workspace = FileComposeExecutionWorkspace(rootURL: root)
    let staged = try workspace.stageInputs(projectName: "demo", files: [file])
    let url = try #require(staged[file.id])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

    #expect(throws: ComposeProjectLifecycleError.self) {
      _ = try workspace.stageInputs(projectName: "demo", files: [file])
    }
  }

  @Test
  func rejectsEnvironmentValuesThatWereNotDiscovered() async throws {
    let canonical = Data(
      """
      {"name":"demo","services":{"web":{"image":"nginx:1.27","secrets":[{"source":"token"}]}},"secrets":{"token":{"environment":"DEMO_TOKEN"}}}
      """.utf8
    )
    let root = FileManager.default.temporaryDirectory.appending(
      path: "compose-input-values-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let rendered = inputRenderedConfiguration(canonical)
    let source = inputSourceLease(root: root, byteCount: canonical.count)
    let vault = ComposeProjectInputVault(
      sealer: HMACComposeInputSealer(keyData: Data(repeating: 8, count: 32))
    )
    let requirements = try await vault.discover(
      source: source,
      options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
      rendered: rendered
    )

    await #expect(throws: ComposeProjectLifecycleError.unexpectedInputValue("EXTRA")) {
      _ = try await vault.prepare(
        requirementsID: requirements.id,
        inputs: ComposeProjectReviewInputs(
          requirementsID: requirements.id,
          environmentValues: ["DEMO_TOKEN": "value", "EXTRA": "must-not-pass"]
        ),
        source: source,
        options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
        rendered: rendered
      )
    }
  }

  @Test
  func rejectsEnvironmentInputNamesThatCouldControlComposeExecution() async throws {
    let canonical = Data(
      """
      {"name":"demo","services":{"web":{"image":"nginx:1.27","secrets":[{"source":"token"}]}},"secrets":{"token":{"environment":"DOCKER_HOST"}}}
      """.utf8
    )
    let root = FileManager.default.temporaryDirectory.appending(
      path: "compose-input-environment-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = ComposeProjectInputVault(
      sealer: HMACComposeInputSealer(keyData: Data(repeating: 13, count: 32))
    )

    await #expect(throws: ComposeProjectLifecycleError.self) {
      _ = try await vault.discover(
        source: inputSourceLease(root: root, byteCount: canonical.count),
        options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
        rendered: inputRenderedConfiguration(canonical)
      )
    }
  }

  @Test
  func rejectsReviewedEnvironmentVariablesReusedByServiceInterpolationOrPassthrough()
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "compose-input-reuse-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    for serviceEnvironment in [
      "\"LEAK\":\"${DEMO_TOKEN}\"",
      "\"DEMO_TOKEN\":null",
    ] {
      let canonical = Data(
        """
        {"name":"demo","services":{"web":{"image":"nginx:1.27","environment":{\(serviceEnvironment)},"secrets":[{"source":"token"}]}},"secrets":{"token":{"environment":"DEMO_TOKEN"}}}
        """.utf8
      )
      let vault = ComposeProjectInputVault(
        sealer: HMACComposeInputSealer(keyData: Data(repeating: 16, count: 32))
      )

      await #expect(throws: ComposeProjectLifecycleError.self) {
        _ = try await vault.discover(
          source: inputSourceLease(root: root, byteCount: canonical.count),
          options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
          rendered: inputRenderedConfiguration(canonical)
        )
      }
    }
  }

  @Test
  func permitsAnEscapedLiteralReferenceToAReviewedEnvironmentVariable() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "compose-input-escaped-reference-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let canonical = Data(
      """
      {"name":"demo","services":{"web":{"image":"nginx:1.27","command":"echo $${DEMO_TOKEN}","secrets":[{"source":"token"}]}},"secrets":{"token":{"environment":"DEMO_TOKEN"}}}
      """.utf8
    )
    let requirements = try await ComposeProjectInputVault(
      sealer: HMACComposeInputSealer(keyData: Data(repeating: 17, count: 32))
    ).discover(
      source: inputSourceLease(root: root, byteCount: canonical.count),
      options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
      rendered: inputRenderedConfiguration(canonical)
    )

    #expect(requirements.requiredEnvironmentVariables == ["DEMO_TOKEN"])
  }

  @Test
  func rejectsInputFilesOutsideProjectAndSymlinkSources() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "compose-input-paths-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = FileManager.default.temporaryDirectory.appending(
      path: "outside-\(UUID().uuidString).secret"
    )
    try Data("secret".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }
    let link = root.appending(path: "linked.secret")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let writable = root.appending(path: "writable.secret")
    try Data("secret".utf8).write(to: writable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o666],
      ofItemAtPath: writable.path
    )
    let linkedFile = root.appending(path: "hard-linked.secret")
    let secondLink = root.appending(path: "hard-linked-copy.secret")
    try Data("secret".utf8).write(to: linkedFile)
    try FileManager.default.linkItem(at: linkedFile, to: secondLink)
    let vault = ComposeProjectInputVault(
      sealer: HMACComposeInputSealer(keyData: Data(repeating: 9, count: 32))
    )
    let source = inputSourceLease(root: root, byteCount: 1)

    for path in [outside.path, link.path, writable.path, linkedFile.path] {
      let canonical = Data(
        """
        {"name":"demo","services":{"web":{"image":"nginx:1.27","secrets":[{"source":"token"}]}},"secrets":{"token":{"file":"\(path)"}}}
        """.utf8
      )
      await #expect(throws: ComposeProjectLifecycleError.inputSourceUnsafe("token")) {
        _ = try await vault.discover(
          source: source,
          options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
          rendered: inputRenderedConfiguration(canonical)
        )
      }
    }
  }

  @Test
  func enforcesEnvironmentSecretLimitBeforeSealing() async throws {
    let canonical = Data(
      """
      {"name":"demo","services":{"web":{"image":"nginx:1.27","secrets":[{"source":"token"}]}},"secrets":{"token":{"environment":"DEMO_TOKEN"}}}
      """.utf8
    )
    let root = FileManager.default.temporaryDirectory.appending(
      path: "compose-input-limit-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let rendered = inputRenderedConfiguration(canonical)
    let source = inputSourceLease(root: root, byteCount: canonical.count)
    let vault = ComposeProjectInputVault(
      sealer: HMACComposeInputSealer(keyData: Data(repeating: 10, count: 32))
    )
    let requirements = try await vault.discover(
      source: source,
      options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
      rendered: rendered
    )

    await #expect(throws: ComposeProjectLifecycleError.inputSourceTooLarge("token")) {
      _ = try await vault.prepare(
        requirementsID: requirements.id,
        inputs: ComposeProjectReviewInputs(
          requirementsID: requirements.id,
          environmentValues: [
            "DEMO_TOKEN": String(
              repeating: "x",
              count: ContainerBuildSecretLimits.maximumSecretBytes + 1
            )
          ]
        ),
        source: source,
        options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
        rendered: rendered
      )
    }
  }

  @Test
  func rejectsAFileInputChangedAfterDiscovery() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "compose-input-stale-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "settings.conf")
    try Data("first".utf8).write(to: file)
    let canonical = Data(
      """
      {"name":"demo","services":{"web":{"image":"nginx:1.27","configs":[{"source":"settings"}]}},"configs":{"settings":{"file":"\(file.path)"}}}
      """.utf8
    )
    let rendered = inputRenderedConfiguration(canonical)
    let source = inputSourceLease(root: root, byteCount: canonical.count)
    let vault = ComposeProjectInputVault(
      sealer: HMACComposeInputSealer(keyData: Data(repeating: 12, count: 32))
    )
    let requirements = try await vault.discover(
      source: source,
      options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
      rendered: rendered
    )
    try Data("second".utf8).write(to: file, options: .atomic)

    await #expect(throws: ComposeProjectLifecycleError.inputRequirementsMismatch) {
      _ = try await vault.prepare(
        requirementsID: requirements.id,
        inputs: ComposeProjectReviewInputs(requirementsID: requirements.id),
        source: source,
        options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
        rendered: rendered
      )
    }
  }

  @Test
  func supportsLiteralConfigsWithoutPersistingAFilePayload() async throws {
    let canonical = Data(
      """
      {"name":"demo","services":{"web":{"image":"nginx:1.27","configs":[{"source":"settings","target":"/settings"}]}},"configs":{"settings":{"content":"feature=true\\n"}}}
      """.utf8
    )
    let root = FileManager.default.temporaryDirectory.appending(
      path: "compose-input-literal-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let rendered = inputRenderedConfiguration(canonical)
    let source = inputSourceLease(root: root, byteCount: canonical.count)
    let vault = ComposeProjectInputVault(
      sealer: HMACComposeInputSealer(keyData: Data(repeating: 11, count: 32))
    )

    let prepared = try await vault.prepareImmediate(
      source: source,
      options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
      rendered: rendered
    )
    let seal = try #require(prepared.serviceSeals["web"])
    let plan = overlayPlan(
      canonicalConfiguration: canonical,
      inputSeal: seal,
      includeResources: false
    )
    try await vault.bind(token: prepared.token, to: plan.id)
    let payload = try await vault.consume(for: plan)

    #expect(payload.files.isEmpty)
    #expect(payload.environmentValues.isEmpty)
    #expect(payload.bindings.map(\.sourceKind) == [.literal])
    let changedCanonical = Data(
      """
      {"name":"demo","services":{"web":{"image":"nginx:1.27","configs":[{"source":"settings","target":"/settings"}]}},"configs":{"settings":{"content":"feature=false\\n"}}}
      """.utf8
    )
    let changedPrepared = try await ComposeProjectInputVault(
      sealer: HMACComposeInputSealer(keyData: Data(repeating: 11, count: 32))
    ).prepareImmediate(
      source: inputSourceLease(root: root, byteCount: changedCanonical.count),
      options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
      rendered: inputRenderedConfiguration(changedCanonical)
    )
    #expect(changedPrepared.serviceSeals["web"] != seal)
    await #expect(throws: ComposeProjectLifecycleError.inputRequirementsUnavailable) {
      _ = try await vault.consume(for: plan)
    }
  }

  @Test
  func composeExecutionSuppressesDiagnosticsWhenReviewedInputsArePresent() async throws {
    let canonical = Data(
      """
      {"name":"demo","services":{"web":{"image":"nginx:1.27","secrets":[{"source":"token"}]}},"secrets":{"token":{"environment":"DEMO_TOKEN"}}}
      """.utf8
    )
    let root = FileManager.default.temporaryDirectory.appending(
      path: "compose-input-redaction-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let executor = InputRedactionCommandExecutor()
    let service = ComposeUpCommandService(
      commandExecutor: executor,
      executionWorkspace: FileComposeExecutionWorkspace(rootURL: root)
    )
    let plan = overlayPlan(
      canonicalConfiguration: canonical,
      inputSeal: String(repeating: "e", count: 64),
      includeResources: false
    )
    let request = ComposeProjectMutationRequest(
      plan: plan,
      operationID: UUID(),
      canonicalConfiguration: canonical,
      composeExecutableURL: URL(filePath: "/tmp/docker-compose"),
      commandEnvironment: ComposeCommandEnvironment(processEnvironment: [:]),
      reviewedInputs: ComposeReviewedInputPayload(
        bindings: [
          ComposeProjectInputBinding(
            kind: .secret,
            name: "token",
            sourceKind: .environment,
            stagedFileID: nil
          )
        ],
        files: [],
        environmentValues: ["DEMO_TOKEN": "super-secret-value"]
      )
    )

    do {
      try await service.execute(request)
      Issue.record("Expected Compose execution to fail.")
    } catch {
      #expect(!error.localizedDescription.contains("super-secret-value"))
      #expect(error.localizedDescription.contains("diagnostics were suppressed"))
    }
    #expect(await executor.environment?["DEMO_TOKEN"] == "super-secret-value")
  }

  @Test
  func exactReviewedExecutionHashRejectsADriftedFinalInputOverlay() async throws {
    let canonical = Data(
      """
      {"name":"demo","services":{"web":{"image":"nginx:1.27","secrets":[{"source":"token"}]}},"secrets":{"token":{"environment":"DEMO_TOKEN"}}}
      """.utf8
    )
    let root = FileManager.default.temporaryDirectory.appending(
      path: "compose-input-exact-hash-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let executor = ExactInputHashCommandExecutor(
      hash: String(repeating: "b", count: 64)
    )
    let service = ComposeUpCommandService(
      commandExecutor: executor,
      executionWorkspace: FileComposeExecutionWorkspace(rootURL: root)
    )
    let plan = overlayPlan(
      canonicalConfiguration: canonical,
      inputSeal: String(repeating: "e", count: 64),
      executionHash: String(repeating: "a", count: 64),
      includeResources: false
    )
    let request = ComposeProjectMutationRequest(
      plan: plan,
      operationID: UUID(),
      canonicalConfiguration: canonical,
      composeExecutableURL: URL(filePath: "/tmp/docker-compose"),
      commandEnvironment: ComposeCommandEnvironment(processEnvironment: [:]),
      reviewedInputs: ComposeReviewedInputPayload(
        bindings: [
          ComposeProjectInputBinding(
            kind: .secret,
            name: "token",
            sourceKind: .environment,
            stagedFileID: nil
          )
        ],
        files: [],
        environmentValues: ["DEMO_TOKEN": "reviewed-value"]
      )
    )

    await #expect(throws: ComposeProjectLifecycleError.stalePlan) {
      try await service.validate(request)
    }
  }

  private func canonicalConfiguration() -> Data {
    Data(
      """
      {
        "name": "demo",
        "services": {
          "web": {
            "image": "nginx:1.27",
            "volumes": [{"type": "volume", "source": "data", "target": "/data"}],
            "networks": {"default": {}}
          }
        },
        "volumes": {"data": {"name": "demo_data", "driver": "local"}},
        "networks": {"default": {"name": "demo_default", "driver": "bridge"}}
      }
      """.utf8
    )
  }

  private func overlayPlan(
    canonicalConfiguration: Data,
    inputSeal: String? = nil,
    executionHash: String? = nil,
    includeResources: Bool = true,
    includeNetworkAction: Bool = true
  ) -> ComposeProjectPlan {
    let desired = ComposeDesiredState(
      projectName: "demo",
      declaredServiceNames: ["web"],
      serviceDependencies: ["web": []],
      activeServices: [
        ComposeDesiredService(
          name: "web",
          imageReference: "nginx:1.27",
          replicaCount: 1,
          profiles: [],
          dependencyNames: [],
          configurationHash: String(repeating: "a", count: 64),
          inputSeal: inputSeal,
          volumeNames: includeResources ? ["data"] : [],
          networkNames: includeResources ? ["default"] : [],
          publishedPortCount: 0
        )
      ],
      volumes: includeResources
        ? [
          ComposeDesiredResource(
            kind: .volume,
            logicalName: "data",
            runtimeName: "demo_data",
            isExternal: false,
            isActive: true
          )
        ] : [],
      networks: includeResources
        ? [
          ComposeDesiredResource(
            kind: .network,
            logicalName: "default",
            runtimeName: "demo_default",
            isExternal: false,
            isActive: true
          )
        ] : []
    )
    return ComposeProjectPlan(
      id: UUID(),
      generatedAt: Date(timeIntervalSince1970: 1),
      options: ComposeProjectReviewOptions(action: .up, projectName: "demo"),
      source: ComposeProjectSourceSummary(
        directoryName: "demo",
        fileName: "compose.yaml",
        fileIdentity: ComposeProjectSourceFileIdentity(
          device: 1,
          inode: 2,
          owner: 501,
          permissions: 0o600,
          byteCount: Int64(canonicalConfiguration.count),
          modificationSeconds: 1,
          modificationNanoseconds: 0,
          changeSeconds: 1,
          changeNanoseconds: 0,
          sha256: overlaySHA256(canonicalConfiguration)
        )
      ),
      desiredState: desired,
      fullConfigurationSHA256: overlaySHA256(canonicalConfiguration),
      activeConfigurationSHA256: String(repeating: "b", count: 64),
      composeReleaseVersion: DockerComposeRelease.pinned.version,
      composeBinarySHA256: DockerComposeRelease.pinned.binarySHA256,
      composeSourceRevision: DockerComposeRelease.pinned.sourceRevision,
      environmentSHA256: String(repeating: "c", count: 64),
      serviceConfigurationHashes: ["web": String(repeating: "a", count: 64)],
      executionServiceConfigurationHashes: executionHash.map { ["web": $0] },
      observedIdentity: .empty,
      issues: [],
      containerActions: [
        ComposeProjectContainerAction(
          stepID: .container(1),
          operation: .create,
          serviceName: "web",
          replicaNumber: 1,
          expectedIdentity: nil
        )
      ],
      volumeActions: includeResources
        ? [
          ComposeProjectVolumeAction(
            stepID: .volume(1),
            operation: .createManaged,
            logicalName: "data",
            runtimeName: "demo_data",
            expectedIdentity: nil
          )
        ] : [],
      networkActions: includeResources && includeNetworkAction
        ? [
          ComposeProjectNetworkAction(
            stepID: .network(1),
            operation: .createManaged,
            logicalName: "default",
            runtimeName: "demo_default",
            expectedIdentity: nil
          )
        ] : [],
      orphanContainers: [],
      preservedResources: []
    )
  }

  private func inputRenderedConfiguration(_ canonical: Data) -> ComposeRenderedConfiguration {
    ComposeRenderedConfiguration(
      fullConfiguration: canonical,
      activeConfiguration: canonical,
      fullConfigurationSHA256: overlaySHA256(canonical),
      activeConfigurationSHA256: overlaySHA256(canonical),
      composeReleaseVersion: DockerComposeRelease.pinned.version,
      composeBinarySHA256: DockerComposeRelease.pinned.binarySHA256,
      composeSourceRevision: DockerComposeRelease.pinned.sourceRevision,
      environmentSHA256: ComposeCommandEnvironment(processEnvironment: [:]).sha256,
      serviceConfigurationHashes: ["web": String(repeating: "a", count: 64)]
    )
  }

  private func inputSourceLease(root: URL, byteCount: Int) -> ComposeProjectSourceLease {
    ComposeProjectSourceLease(
      id: UUID(),
      directoryURL: root,
      composeFileURL: root.appending(path: "compose.yaml"),
      summary: ComposeProjectSourceSummary(
        directoryName: root.lastPathComponent,
        fileName: "compose.yaml",
        fileIdentity: ComposeProjectSourceFileIdentity(
          device: 1,
          inode: 2,
          owner: UInt32(geteuid()),
          permissions: 0o600,
          byteCount: Int64(byteCount),
          modificationSeconds: 1,
          modificationNanoseconds: 0,
          changeSeconds: 1,
          changeNanoseconds: 0,
          sha256: String(repeating: "f", count: 64)
        )
      )
    )
  }
}

private func overlaySHA256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private actor InputRedactionCommandExecutor: HostCommandExecuting {
  private(set) var environment: [String: String]?

  func execute(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]?,
    timeout: Duration
  ) async throws -> HostCommandResult {
    self.environment = environment
    return HostCommandResult(
      exitCode: 1,
      standardOutput: "",
      standardError: "operation failed: super-secret-value",
      outputWasTruncated: false
    )
  }
}

private actor ExactInputHashCommandExecutor: HostCommandExecuting {
  private let hash: String

  init(hash: String) {
    self.hash = hash
  }

  func execute(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]?,
    timeout: Duration
  ) async throws -> HostCommandResult {
    HostCommandResult(
      exitCode: 0,
      standardOutput: "web \(hash)\n",
      standardError: "",
      outputWasTruncated: false
    )
  }
}
