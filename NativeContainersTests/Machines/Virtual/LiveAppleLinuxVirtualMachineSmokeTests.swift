import CryptoKit
import Foundation
import Testing
@preconcurrency import Virtualization

@testable import NativeContainers

@Suite("Live Apple Linux virtual machine", .serialized)
@MainActor
struct LiveAppleLinuxVirtualMachineSmokeTests {
  private static let outputMarker = "NATIVECONTAINERS_LIVE_LINUX_VM_RESULT "

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_LINUX_VM"
      ] == "1",
      "Set NATIVECONTAINERS_LIVE_LINUX_VM=1 with a reviewed local ISO path and SHA-256."
    )
  )
  func bootsReviewedInstallerAndCleansIsolatedBundle() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard
      let isoPath = environment["NATIVECONTAINERS_LIVE_LINUX_VM_ISO"],
      !isoPath.isEmpty
    else {
      throw LiveLinuxVirtualMachineSmokeError.missingEnvironment(
        "NATIVECONTAINERS_LIVE_LINUX_VM_ISO"
      )
    }
    guard
      let expectedSHA256 =
        environment["NATIVECONTAINERS_LIVE_LINUX_VM_ISO_SHA256"]?
        .lowercased(),
      expectedSHA256.count == 64,
      expectedSHA256.allSatisfy({ $0.isHexDigit })
    else {
      throw LiveLinuxVirtualMachineSmokeError.missingEnvironment(
        "NATIVECONTAINERS_LIVE_LINUX_VM_ISO_SHA256"
      )
    }

    let installationMediaURL = URL(filePath: isoPath).standardizedFileURL
    guard installationMediaURL.pathExtension.lowercased() == "iso" else {
      throw LiveLinuxVirtualMachineSmokeError.invalidISO(installationMediaURL)
    }
    let actualSHA256 = try sha256(of: installationMediaURL)
    guard actualSHA256 == expectedSHA256 else {
      throw LiveLinuxVirtualMachineSmokeError.digestMismatch(
        expected: expectedSHA256,
        actual: actualSHA256
      )
    }

    let suffix = UUID().uuidString.lowercased()
    let libraryRoot = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-live-linux-vm-\(suffix)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: libraryRoot,
      withIntermediateDirectories: false
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: libraryRoot.nativeContainersPOSIXPath
    )
    defer { try? FileManager.default.removeItem(at: libraryRoot) }

    let library = VirtualMachineLibrary(rootURL: libraryRoot)
    let creator = LinuxVirtualMachineCreationService(library: library)
    let runtime = LinuxVirtualMachineRuntimeService(
      leasingStore: library,
      installationStore: library,
      engine: AppleLinuxVirtualMachineRuntimeEngine(),
      savedStateService: LinuxVirtualMachineSavedStateService(
        store: LinuxVirtualMachineSavedStateStore()
      )
    )
    let resources = try VirtualMachineResources(
      cpuCount: min(4, max(1, ProcessInfo.processInfo.processorCount)),
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
    var machineID: UUID?

    do {
      let machine = try await creator.createLinuxVirtualMachine(
        name: "NativeContainers Live Linux \(suffix.prefix(8))",
        resources: resources,
        installationMediaURL: installationMediaURL
      )
      machineID = machine.id
      #expect(machine.installState == .readyToInstall)
      #expect(machine.linuxConfiguration?.installationMediaPath != nil)

      try await runtime.start(id: machine.id)
      var snapshot = runtime.snapshot(for: machine.id)
      let target = try #require(snapshot.target)
      #expect(snapshot.state == .running)
      #expect(snapshot.hasInstallationMedia)
      let console = try #require(runtime.console(for: target))
      #expect(console.virtualMachine.state == .running)

      try await Task.sleep(for: .seconds(10))
      snapshot = runtime.snapshot(for: machine.id)
      #expect(snapshot.state == .running)
      #expect(console.virtualMachine.state == .running)

      try await runtime.pause(target: target)
      #expect(runtime.snapshot(for: machine.id).state == .paused)
      #expect(console.virtualMachine.state == .paused)

      try await runtime.resume(target: target)
      #expect(runtime.snapshot(for: machine.id).state == .running)
      #expect(console.virtualMachine.state == .running)

      let reducedMemory = 4 * VirtualMachineResources.bytesPerGiB
      try runtime.setMemoryBalloonTarget(reducedMemory, for: target)
      #expect(
        runtime.snapshot(for: machine.id).memoryBalloon?.targetMemoryBytes
          == reducedMemory
      )
      try runtime.setMemoryBalloonTarget(resources.memoryBytes, for: target)

      try await runtime.forceStop(target: target)
      snapshot = runtime.snapshot(for: machine.id)
      #expect(snapshot.state == .stopped)
      #expect(snapshot.target == nil)

      try await library.discardVirtualMachine(id: machine.id)
      machineID = nil
      #expect(try await library.list().isEmpty)

      try FileManager.default.removeItem(at: libraryRoot)
      print(
        "\(Self.outputMarker)id=\(machine.id.uuidString.lowercased()) iso_sha256=\(actualSHA256) running=confirmed pause_resume=confirmed balloon=confirmed cleanup=complete"
      )
    } catch {
      if let machineID {
        if let target = runtime.snapshot(for: machineID).target {
          try? await runtime.forceStop(target: target)
        }
        try? await library.discardVirtualMachine(id: machineID)
      }
      try? FileManager.default.removeItem(at: libraryRoot)
      throw error
    }
  }

  private func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var hasher = SHA256()
    while true {
      try Task.checkCancellation()
      guard
        let chunk = try handle.read(upToCount: 8 * 1_024 * 1_024),
        !chunk.isEmpty
      else { break }
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

private enum LiveLinuxVirtualMachineSmokeError: LocalizedError {
  case missingEnvironment(String)
  case invalidISO(URL)
  case digestMismatch(expected: String, actual: String)

  var errorDescription: String? {
    switch self {
    case .missingEnvironment(let name):
      "Set \(name) before running the live Linux virtual-machine smoke."
    case .invalidISO(let url):
      "The live Linux virtual-machine fixture must be a local .iso file, not \(url.lastPathComponent)."
    case .digestMismatch(let expected, let actual):
      "The live Linux virtual-machine ISO SHA-256 changed (expected \(expected), found \(actual))."
    }
  }
}
