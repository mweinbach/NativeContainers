import Foundation

@MainActor
final class NativeContainersLinuxBoxAutomationRuntime: LinuxBoxAutomationRuntime, @unchecked Sendable {
  private let library: any VirtualMachineLibraryProtocol
  private let runtime: LinuxVirtualMachineRuntimeService
  private let imageService: LinuxBoxImageService
  private let fileManager: FileManager

  init(
    library: any VirtualMachineLibraryProtocol,
    runtime: LinuxVirtualMachineRuntimeService,
    imageService: LinuxBoxImageService,
    fileManager: FileManager = .default
  ) {
    self.library = library
    self.runtime = runtime
    self.imageService = imageService
    self.fileManager = fileManager
  }

  func doctor() async throws -> LinuxBoxDoctorResult {
    var checks: [LinuxBoxCheck] = []
    do {
      try imageService.catalog.validate()
      checks.append(LinuxBoxCheck(name: "embedded_image_catalog", ok: true, code: nil, details: nil))
    } catch {
      checks.append(LinuxBoxCheck(name: "embedded_image_catalog", ok: false, code: "image_integrity", details: redacted(error)))
    }
    do {
      try await imageService.recover()
      checks.append(LinuxBoxCheck(name: "image_cache_recovery", ok: true, code: nil, details: nil))
    } catch {
      checks.append(LinuxBoxCheck(name: "image_cache_recovery", ok: false, code: "image_integrity", details: redacted(error)))
    }
    do {
      _ = try await library.list()
      checks.append(LinuxBoxCheck(name: "virtual_machine_library", ok: true, code: nil, details: nil))
    } catch {
      checks.append(LinuxBoxCheck(name: "virtual_machine_library", ok: false, code: "internal_error", details: redacted(error)))
    }
    return LinuxBoxDoctorResult(checks: checks)
  }

  func prepareImage() async throws -> LinuxBoxImagePrepareResult {
    let image = try firstImage()
    let cachedBefore = cachedTemplateExists(image)
    do {
      _ = try await imageService.cache.prepare(image: image)
    } catch {
      throw map(error)
    }
    return LinuxBoxImagePrepareResult(
      imageID: image.imageID,
      cached: cachedBefore,
      compressedSHA256: image.compressedSHA256,
      rawSHA512: image.rawSHA512
    )
  }

  func list() async throws -> LinuxBoxListResult {
    let manifests = try await library.list()
    var boxes: [LinuxBoxSummary] = []
    for manifest in manifests where manifest.guest == .linux && manifest.linuxConfiguration?.linuxBoxDescriptor != nil {
      boxes.append(try await summary(for: manifest))
    }
    return LinuxBoxListResult(boxes: boxes.sorted {
      let left = $0.name.lowercased()
      let right = $1.name.lowercased()
      return left == right ? $0.id.value.uuidString < $1.id.value.uuidString : left < right
    })
  }

  func create(_ payload: LinuxBoxCreatePayload) async throws -> LinuxBoxChangedResult {
    let request: LinuxBoxManagedCreationRequest
    do {
      request = try LinuxBoxManagedCreationRequest(
        name: payload.name,
        cpuCount: payload.cpuCount,
        memoryBytes: payload.memoryBytes,
        diskBytes: payload.diskBytes,
        profile: payload.profile
      )
    } catch {
      throw map(error)
    }
    let image = try firstImage()
    do {
      let result = try await library.createManagedLinuxBox(
        request: request,
        image: image,
        operationID: UUID()
      )
      return LinuxBoxChangedResult(box: try await summary(for: result.manifest), changed: true)
    } catch {
      throw map(error)
    }
  }

  func status(id: UUID) async throws -> LinuxBoxSummary {
    try await summary(for: managedManifest(id: id))
  }

  func start(id: UUID) async throws -> LinuxBoxVerifiedResult {
    _ = try await managedManifest(id: id)
    let current = runtime.snapshot(for: id)
    guard current.state == .stopped, current.target == nil else {
      throw stateError(id: id, snapshot: current)
    }
    do {
      try await runtime.start(id: id)
      let snapshot = runtime.snapshot(for: id)
      guard let target = snapshot.target else {
        throw NativeContainersAutomationError.control(.agentUnavailable, "The Linux box did not publish a runtime session.")
      }
      let verification: LinuxBoxVerification
      if let existing = runtime.lastLinuxBoxVerification(target: target) {
        verification = existing
      } else {
        verification = try await runtime.verifyLinuxBox(target: target)
      }
      return LinuxBoxVerifiedResult(
        box: try await summary(for: managedManifest(id: id)),
        verification: verification
      )
    } catch {
      throw map(error)
    }
  }

  func pause(id: UUID) async throws -> LinuxBoxChangedResult {
    let manifest = try await managedManifest(id: id)
    let snapshot = runtime.snapshot(for: id)
    guard let target = snapshot.target else { return LinuxBoxChangedResult(box: try await summary(for: manifest), changed: false) }
    do {
      try await runtime.pause(target: target)
      return LinuxBoxChangedResult(box: try await summary(for: manifest), changed: true)
    } catch { throw map(error) }
  }

  func resume(id: UUID) async throws -> LinuxBoxChangedResult {
    _ = try await managedManifest(id: id)
    let snapshot = runtime.snapshot(for: id)
    guard let target = snapshot.target else { throw stateError(id: id, snapshot: snapshot) }
    do {
      try await runtime.resume(target: target)
      return LinuxBoxChangedResult(box: try await summary(for: managedManifest(id: id)), changed: true)
    } catch { throw map(error) }
  }

  func exec(
    id: UUID,
    argv: [String],
    deadline: ContinuousClock.Instant
  ) async throws -> LinuxBoxExecResult {
    _ = try await managedManifest(id: id)
    guard let target = runtime.snapshot(for: id).target else {
      throw NativeContainersAutomationError.control(
        .agentUnavailable,
        "The Linux box is not connected to its guest agent."
      )
    }
    let remaining = max(
      1,
      Int(ContinuousClock.now.duration(to: deadline).components.seconds)
    )
    do {
      let guest = try await runtime.executeLinuxBox(
        target: target,
        argv: argv,
        timeoutSeconds: remaining
      )
      let result = LinuxBoxExecResult(
        id: CanonicalUUID(id),
        exitCode: guest.exitCode,
        stdoutBase64: guest.stdoutBase64,
        stderrBase64: guest.stderrBase64
      )
      guard result.exitCode == 0 else {
        throw NativeContainersAutomationError.control(
          .guestExit,
          "The guest command exited with code \(result.exitCode).",
          result
        )
      }
      return result
    } catch {
      throw map(error, execID: id)
    }
  }

  func verify(id: UUID) async throws -> LinuxBoxVerifiedResult {
    _ = try await managedManifest(id: id)
    guard let target = runtime.snapshot(for: id).target else { throw NativeContainersAutomationError.control(.agentUnavailable, "The Linux box is not connected to its guest agent.") }
    do {
      let verification = try await runtime.verifyLinuxBox(target: target)
      return LinuxBoxVerifiedResult(box: try await summary(for: managedManifest(id: id)), verification: verification)
    } catch { throw map(error) }
  }

  func refresh(id: UUID) async throws -> LinuxBoxVerifiedResult {
    _ = try await managedManifest(id: id)
    guard let target = runtime.snapshot(for: id).target else { throw NativeContainersAutomationError.control(.agentUnavailable, "The Linux box is not connected to its guest agent.") }
    do {
      let verification = try await runtime.refreshLinuxBox(target: target)
      return LinuxBoxVerifiedResult(box: try await summary(for: managedManifest(id: id)), verification: verification)
    } catch { throw map(error) }
  }

  func stop(id: UUID) async throws -> LinuxBoxChangedResult {
    let manifest = try await managedManifest(id: id)
    let snapshot = runtime.snapshot(for: id)
    guard let target = snapshot.target else { return LinuxBoxChangedResult(box: try await summary(for: manifest), changed: false) }
    do {
      try await runtime.stop(target: target)
      return LinuxBoxChangedResult(box: try await summary(for: manifest), changed: true)
    } catch { throw map(error) }
  }

  func destroy(id: UUID) async throws -> LinuxBoxDestroyResult {
    guard let manifest = try await findManifest(id: id) else {
      return LinuxBoxDestroyResult(id: CanonicalUUID(id), state: "absent", changed: false)
    }
    guard manifest.linuxConfiguration?.linuxBoxDescriptor != nil else {
      throw NativeContainersAutomationError.control(.wrongKind, "The requested machine is not a managed Linux box.")
    }
    let snapshot = runtime.snapshot(for: id)
    do {
      if let target = snapshot.target {
        try await runtime.stop(target: target)
        try await waitUntilStopped(id: id)
      }
      try await library.discardVirtualMachine(id: id)
      return LinuxBoxDestroyResult(id: CanonicalUUID(id), state: "absent", changed: true)
    } catch { throw map(error) }
  }

  func smoke(name: String, profile: LinuxBoxProfile) async throws -> LinuxBoxSmokeResult {
    let created = try await create(LinuxBoxCreatePayload(name: name, cpuCount: LinuxBoxManagedCreationRequest.defaultCPUCount, memoryBytes: LinuxBoxManagedCreationRequest.defaultMemoryBytes, diskBytes: LinuxBoxManagedCreationRequest.defaultDiskBytes, profile: profile))
    let id = created.box.id.value
    var verification: LinuxBoxVerification?
    var cleanup: [LinuxBoxCheck] = []
    do {
      verification = try await start(id: id).verification
    } catch {
      _ = try? await destroy(id: id)
      throw error
    }
    do {
      _ = try await destroy(id: id)
      cleanup.append(LinuxBoxCheck(name: "destroy", ok: true, code: nil, details: nil))
    } catch {
      cleanup.append(LinuxBoxCheck(name: "destroy", ok: false, code: "cleanup_failed", details: redacted(error)))
      throw NativeContainersAutomationError.control(.cleanupFailed, "The smoke-test box could not be destroyed.")
    }
    guard let verification else { throw NativeContainersAutomationError.control(.verificationFailed, "The smoke test did not produce verification.") }
    return LinuxBoxSmokeResult(id: CanonicalUUID(id), state: "absent", verification: verification, cleanup: cleanup)
  }


  private func firstImage() throws -> LinuxBoxImageRecord {
    guard let image = imageService.catalog.images.first else {
      throw NativeContainersAutomationError.control(.imageUnavailable, "No prepared Linux box image is available.")
    }
    return image
  }

  private func cachedTemplateExists(_ image: LinuxBoxImageRecord) -> Bool {
    let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let url = caches
      .appending(path: LinuxBoxImageCache.applicationCacheDirectoryName, directoryHint: .isDirectory)
      .appending(path: LinuxBoxImageCache.imageDirectoryName, directoryHint: .isDirectory)
      .appending(path: image.imageID, directoryHint: .isDirectory)
      .appending(path: "template.raw")
    return fileManager.fileExists(atPath: url.path)
  }

  private func managedManifest(id: UUID) async throws -> VirtualMachineManifest {
    guard let manifest = try await findManifest(id: id) else {
      throw NativeContainersAutomationError.control(.notFound, "The requested Linux box was not found.")
    }
    guard manifest.guest == .linux else {
      throw NativeContainersAutomationError.control(.wrongKind, "The requested machine is not a Linux box.")
    }
    guard manifest.linuxConfiguration?.linuxBoxDescriptor != nil else {
      throw NativeContainersAutomationError.control(.wrongKind, "The requested Linux machine is not managed.")
    }
    return manifest
  }

  private func findManifest(id: UUID) async throws -> VirtualMachineManifest? {
    try await library.list().first { $0.id == id }
  }

  private func summary(for manifest: VirtualMachineManifest) async throws -> LinuxBoxSummary {
    guard let descriptor = manifest.linuxConfiguration?.linuxBoxDescriptor else {
      throw NativeContainersAutomationError.control(.wrongKind, "The requested machine is not a managed Linux box.")
    }
    let snapshot = runtime.snapshot(for: manifest.id)
    return LinuxBoxSummary(
      id: CanonicalUUID(manifest.id),
      name: manifest.name,
      state: state(for: snapshot),
      ready: snapshot.state == .running && snapshot.isReady,
      imageID: descriptor.imageID,
      agentProtocol: descriptor.guestAgentProtocolVersion,
      cpuCount: manifest.resources.cpuCount,
      memoryBytes: manifest.resources.memoryBytes,
      diskBytes: manifest.resources.diskBytes,
      profile: descriptor.profile
    )
  }

  private func state(for snapshot: LinuxVirtualMachineRuntimeSnapshot) -> LinuxBoxState {
    switch snapshot.state {
    case .stopped, .inspectingSavedState, .discardingSavedState: .stopped
    case .starting, .resuming, .restoring: .starting
    case .running: .running
    case .pausing, .saving: .paused
    case .paused: .paused
    case .stopping, .ejectingInstallationMedia: .stopping
    case .ownedElsewhere: .failed
    }
  }

  private func stateError(id: UUID, snapshot: LinuxVirtualMachineRuntimeSnapshot) -> NativeContainersAutomationError {
    if snapshot.state == .running || snapshot.state == .paused {
      return .control(.invalidState, "The Linux box is already in state \(state(for: snapshot).rawValue).")
    }
    return .control(.invalidState, "The Linux box cannot perform this operation from state \(state(for: snapshot).rawValue).")
  }

  private func waitUntilStopped(id: UUID) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while ContinuousClock.now < deadline {
      if runtime.snapshot(for: id).state == .stopped { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw NativeContainersAutomationError.control(.cleanupFailed, "The Linux box did not reach stopped state.")
  }

  private func redacted(_ error: Error) -> String {
    NativeContainersControlRedactor.message(error.localizedDescription)
  }

  private func map(
    _ error: Error,
    execID: UUID? = nil
  ) -> NativeContainersAutomationError {
    if let error = error as? NativeContainersAutomationError { return error }
    if let error = error as? LinuxBoxResidentialPolicyError {
      switch error {
      case .credentialsRequired:
        return .control(.residentialCredentialsRequired, redacted(error))
      case .proxyUnreachable:
        return .control(.residentialProxyUnreachable, redacted(error))
      case .proxiedDNSUnavailable:
        return .control(.proxiedDNSUnavailable, redacted(error))
      case .directIdentityUnavailable:
        return .control(.verificationFailed, redacted(error))
      case .cancelled, .operationTimedOut:
        return .control(.operationTimedOut, redacted(error))
      }
    }
    if let error = error as? LinuxBoxImageCacheError {
      switch error {
      case .imageNotPublished, .downloadFailed:
        return .control(.imageUnavailable, redacted(error))
      case .sizeLimitExceeded, .compressedSizeMismatch, .compressedDigestMismatch,
        .logicalSizeMismatch, .rawDigestMismatch, .invalidCacheDirectory,
        .invalidCachedArtifact, .partialCreationFailed, .decompressionFailed,
        .decompressionOverrun, .trailingCompressedData, .decompressionSizeMismatch,
        .alreadyPromoted, .syncFailed:
        return .control(.imageIntegrity, redacted(error))
      }
    }
    if error is LinuxBoxImageCatalogError {
      return .control(.imageIntegrity, redacted(error))
    }
    if error is LinuxBoxImageServiceError {
      return .control(.imageUnavailable, redacted(error))
    }
    if let error = error as? LinuxBoxManagedCreationError {
      switch error {
      case .unavailable:
        return .control(.imageUnavailable, redacted(error))
      case .diskBelowTemplate:
        return .control(.invalidArguments, redacted(error))
      case .destinationExists:
        return .control(.busy, redacted(error))
      case .diskCopyFailed, .invalidIdentity, .syncFailed:
        return .control(.cleanupFailed, redacted(error))
      }
    }
    if let error = error as? LinuxVirtualMachineRuntimeError {
      switch error {
      case .operationInProgress, .duplicateSession:
        return .control(.busy, redacted(error))
      case .noActiveSession, .ownedElsewhere, .staleTarget, .unavailable:
        return .control(.agentUnavailable, redacted(error))
      case .invalidState, .diskReplacementPending, .diskResizePending,
        .operationUnavailable, .installationMediaNotAttached:
        return .control(.invalidState, redacted(error))
      case .saveRestoreUnsupported:
        return .control(.securityInvariantFailed, redacted(error))
      }
    }
    if let error = error as? LinuxVirtualMachineAgentClientError {
      switch error {
      case .connectionClosed:
        return .control(.agentUnavailable, redacted(error))
      case .timedOut:
        return .control(.operationTimedOut, redacted(error))
      case .identityMismatch:
        return .control(.agentIdentityMismatch, redacted(error))
      case .protocolViolation:
        return .control(.protocolMismatch, redacted(error))
      case .securityInvariant:
        return .control(.securityInvariantFailed, redacted(error))
      case .guest(let code, let message, let guestDetails):
        let details: LinuxBoxExecResult? =
          if let execID, let guestDetails {
            LinuxBoxExecResult(
              id: CanonicalUUID(execID),
              exitCode: guestDetails.exitCode,
              stdoutBase64: guestDetails.stdoutBase64,
              stderrBase64: guestDetails.stderrBase64
            )
          } else {
            nil
          }
        switch code {
        case .invalidRequest, .protocolMismatch:
          return .control(.protocolMismatch, redacted(error))
        case .invalidState:
          return .control(.invalidState, redacted(error))
        case .busy:
          return .control(.busy, redacted(error))
        case .configurationInvalid:
          let mapped: NativeContainersControlErrorCode =
            message == "chromium sandbox unavailable"
            ? .chromiumSandboxUnavailable
            : .verificationFailed
          return .control(mapped, redacted(error))
        case .notReady:
          return .control(.guestNotReady, redacted(error))
        case .execFailed:
          return .control(.guestExit, redacted(error), details)
        case .outputLimit:
          return .control(.outputLimit, redacted(error), details)
        case .operationTimedOut:
          return .control(.operationTimedOut, redacted(error), details)
        case .internalError:
          return .control(.internalError, redacted(error))
        }
      }
    }
    if error is CancellationError {
      return .control(.operationTimedOut, "The operation was cancelled.")
    }
    return .control(.internalError, redacted(error))
  }
}

@MainActor
final class NativeContainersLinuxRuntimeLifecycleAdapter: NativeContainersLinuxRuntimeLifecycle, @unchecked Sendable {
  private let library: any VirtualMachineLibraryProtocol
  private let runtime: LinuxVirtualMachineRuntimeService

  init(library: any VirtualMachineLibraryProtocol, runtime: LinuxVirtualMachineRuntimeService) {
    self.library = library
    self.runtime = runtime
  }

  func reconcileLaunchOwnership() async throws {
    for manifest in try await library.list() where manifest.guest == .linux {
      await runtime.refreshSavedState(id: manifest.id)
    }
  }

  func activeGenerations() async throws -> [NativeContainersLinuxRuntimeGeneration] {
    try await library.list().compactMap { manifest in
      guard let target = runtime.snapshot(for: manifest.id).target else { return nil }
      return NativeContainersLinuxRuntimeGeneration(id: manifest.id, generation: target.generation)
    }
  }

  func quiesceAndStop(
    _ generation: NativeContainersLinuxRuntimeGeneration,
    deadline: ContinuousClock.Instant
  ) async throws -> Bool {
    guard let target = target(for: generation) else { return true }
    try await runtime.stop(target: target)
    while ContinuousClock.now < deadline {
      if runtime.snapshot(for: generation.id).state == .stopped { return true }
      try await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  func forceStop(
    _ generation: NativeContainersLinuxRuntimeGeneration,
    deadline: ContinuousClock.Instant
  ) async -> Bool {
    guard let target = target(for: generation) else { return true }
    do {
      try await runtime.forceStop(target: target)
    } catch {
      return false
    }
    while ContinuousClock.now < deadline {
      if runtime.snapshot(for: generation.id).state == .stopped { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return runtime.snapshot(for: generation.id).state == .stopped
  }

  private func target(for generation: NativeContainersLinuxRuntimeGeneration) -> LinuxVirtualMachineRuntimeTarget? {
    guard let target = runtime.snapshot(for: generation.id).target,
      target.generation == generation.generation
    else { return nil }
    return target
  }
}
