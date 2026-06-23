import AppKit
import CryptoKit
import Darwin
import Foundation
import SwiftUI
import Testing
@preconcurrency import Virtualization

@testable import NativeContainers

private let liveLinuxVirtualMachineRunRequestURL =
  FileManager.default.temporaryDirectory.appending(
    path: "nativecontainers-live-linux-vm-run-request.json",
    directoryHint: .notDirectory
  )

@Suite("Live Apple Linux virtual machine", .serialized)
@MainActor
struct LiveAppleLinuxVirtualMachineSmokeTests {
  private static let outputMarker = "NATIVECONTAINERS_LIVE_LINUX_VM_RESULT "
  private static let inputProbeActivationDelaySeconds = 4
  private static let inputProbeObservationSeconds = 30
  private static let inputProbeDurationSeconds =
    inputProbeActivationDelaySeconds + inputProbeObservationSeconds
  private static let inputCommandMaximumBytes = 4 * 1_024
  private static let inputTextMaximumCharacters = 256
  private static let runRequestMaximumBytes = 8 * 1_024
  private static let runRequestMaximumSharedDirectoryCount = 8
  private static let visualHoldMaximumSeconds = 2 * 60 * 60

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_LINUX_VM"
      ] == "1"
        || FileManager.default.fileExists(
          atPath: liveLinuxVirtualMachineRunRequestURL.nativeContainersPOSIXPath
        ),
      "Set NATIVECONTAINERS_LIVE_LINUX_VM=1 or create the owner-only one-shot run request."
    )
  )
  func bootsReviewedInstallerAndCleansIsolatedBundle() async throws {
    let environment = ProcessInfo.processInfo.environment
    let configuration = try Self.runConfiguration(environment)
    let visualHoldSeconds = configuration.visualHoldSeconds
    let probesGuestInput = configuration.probesGuestInput
    if probesGuestInput && visualHoldSeconds < Self.inputProbeDurationSeconds {
      throw LiveLinuxVirtualMachineSmokeError.inputProbeRequiresVisualHold(
        minimumSeconds: Self.inputProbeDurationSeconds
      )
    }
    if configuration.requiresInstallationMediaEjection && !probesGuestInput {
      throw LiveLinuxVirtualMachineSmokeError.mediaEjectionRequiresInputChannel
    }
    let isoPath = configuration.isoPath
    let expectedSHA256 = configuration.isoSHA256.lowercased()
    guard
      !isoPath.isEmpty,
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
    let savedStateService = LinuxVirtualMachineSavedStateService(
      store: LinuxVirtualMachineSavedStateStore()
    )
    let runtime = LinuxVirtualMachineRuntimeService(
      leasingStore: library,
      installationStore: library,
      engine: AppleLinuxVirtualMachineRuntimeEngine(),
      savedStateService: savedStateService
    )
    let sharedDirectoryService = LinuxVirtualMachineSharedDirectoryService(
      leasingStore: library,
      persistence: library,
      savedStateService: savedStateService
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

      var sharedDirectoryConfiguration =
        LinuxVirtualMachineSharedDirectoryConfiguration.empty
      for directory in configuration.sharedDirectories {
        sharedDirectoryConfiguration = try await sharedDirectoryService.add(
          to: machine.id,
          request: LinuxVirtualMachineSharedDirectoryRequest(
            sourceURL: URL(
              filePath: directory.sourcePath,
              directoryHint: .isDirectory
            ),
            guestName: directory.guestName,
            readOnly: directory.readOnly
          )
        )
      }
      #expect(
        sharedDirectoryConfiguration.directories.count
          == configuration.sharedDirectories.count
      )
      #expect(
        sharedDirectoryConfiguration.directories.filter(\.readOnly).count
          == configuration.sharedDirectories.filter(\.readOnly).count
      )

      try await runtime.start(id: machine.id)
      var snapshot = runtime.snapshot(for: machine.id)
      let target = try #require(snapshot.target)
      #expect(snapshot.state == .running)
      #expect(snapshot.hasInstallationMedia)
      let console = try #require(runtime.console(for: target))
      #expect(console.virtualMachine.state == .running)

      var installationMediaWasEjected = false
      if visualHoldSeconds > 0 {
        try await presentVisualConsole(
          console,
          seconds: visualHoldSeconds,
          probesGuestInput: probesGuestInput,
          onEjectInstallationMedia: {
            let manifest = try await runtime.ejectInstallationMedia(
              target: target
            )
            guard manifest.installState == .stopped,
              manifest.linuxConfiguration?.installationMediaPath == nil,
              !runtime.snapshot(for: machine.id).hasInstallationMedia
            else {
              throw LiveLinuxVirtualMachineSmokeError.mediaEjectionDidNotPersist
            }
            installationMediaWasEjected = true
          }
        )
      } else {
        try await Task.sleep(for: .seconds(10))
      }
      snapshot = runtime.snapshot(for: machine.id)
      #expect(snapshot.state == .running)
      #expect(console.virtualMachine.state == .running)
      #expect(snapshot.hasInstallationMedia == !installationMediaWasEjected)
      if configuration.requiresInstallationMediaEjection,
        !installationMediaWasEjected
      {
        throw LiveLinuxVirtualMachineSmokeError.requiredMediaEjectionMissing
      }

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
      let installationMediaResult =
        installationMediaWasEjected ? "ejected" : "attached"
      let virtioFSResult =
        sharedDirectoryConfiguration.directories.isEmpty
        ? "not_requested" : "attached"
      print(
        "\(Self.outputMarker)id=\(machine.id.uuidString.lowercased()) iso_sha256=\(actualSHA256) installation_media=\(installationMediaResult) virtiofs=\(virtioFSResult) shared_directories=\(sharedDirectoryConfiguration.directories.count) running=confirmed pause_resume=confirmed balloon=confirmed cleanup=complete"
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

  @Test("Live input protocol accepts installation-media ejection")
  func inputProtocolAcceptsInstallationMediaEjection() throws {
    let command = try Self.parseInputCommand(
      Data("install-finished\teject-media\t-\n".utf8)
    )
    #expect(command.id == "install-finished")
    #expect(command.summary == "eject-media")
  }

  @Test("Live input protocol accepts terminal mount controls")
  func inputProtocolAcceptsTerminalMountControls() throws {
    let shortcut = try Self.parseInputCommand(
      Data("terminal\tkey\topen-terminal\n".utf8)
    )
    let mountCommand =
      "sudo mount -t virtiofs nativecontainers /mnt/nativecontainers"
    let encodedMountCommand = Data(mountCommand.utf8).base64EncodedString()
    let text = try Self.parseInputCommand(
      Data("mount\ttext\t\(encodedMountCommand)\n".utf8)
    )

    #expect(shortcut.summary == "key:open-terminal")
    #expect(text.summary == "text:\(mountCommand.count)-characters")
    #expect(LiveLinuxVirtualMachineTypingKey("/") != nil)
    let transitions = Self.guestModifierTransitions(
      for: [.control, .option]
    )
    #expect(
      transitions.presses.map {
        $0.modifierFlags.intersection(.deviceIndependentFlagsMask)
      } == [
        [.control], [.control, .option],
      ])
    #expect(
      transitions.releases.map {
        $0.modifierFlags.intersection(.deviceIndependentFlagsMask)
      } == [
        [.control], [],
      ])
    #expect(
      transitions.presses.map(\.modifierFlags.rawValue) == [
        0x0004_0001, 0x000C_0021,
      ])
    #expect(
      transitions.releases.map(\.modifierFlags.rawValue) == [
        0x0004_0001, 0,
      ])
  }

  @Test("Live input command rejects symbolic and hard links")
  func liveInputCommandRejectsLinkedFiles() throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-live-input-test-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let regularURL = rootURL.appending(
      path: "regular.command",
      directoryHint: .notDirectory
    )
    let symbolicLinkURL = rootURL.appending(
      path: "symbolic.command",
      directoryHint: .notDirectory
    )
    let hardLinkURL = rootURL.appending(
      path: "hard.command",
      directoryHint: .notDirectory
    )
    try Data("linked\tfinish\t-\n".utf8).write(to: regularURL)
    try FileManager.default.createSymbolicLink(
      at: symbolicLinkURL,
      withDestinationURL: regularURL
    )

    #expect(throws: LiveLinuxVirtualMachineSmokeError.self) {
      _ = try Self.readInputCommand(at: symbolicLinkURL)
    }

    try FileManager.default.linkItem(at: regularURL, to: hardLinkURL)
    #expect(throws: LiveLinuxVirtualMachineSmokeError.self) {
      _ = try Self.readInputCommand(at: hardLinkURL)
    }
  }

  @Test("Owner-only live run request is consumed once")
  func ownerOnlyRunRequestIsConsumedOnce() throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-live-request-test-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: rootURL.nativeContainersPOSIXPath
    )
    let requestURL = rootURL.appending(
      path: "request.json",
      directoryHint: .notDirectory
    )
    let request = LiveLinuxVirtualMachineRunRequest(
      isoPath: "/private/tmp/reviewed.iso",
      isoSHA256: String(repeating: "a", count: 64),
      visualHoldSeconds: Self.visualHoldMaximumSeconds,
      probesGuestInput: true,
      requiresInstallationMediaEjection: true,
      sharedDirectories: [
        LiveLinuxVirtualMachineSharedDirectoryRequest(
          sourcePath: "/private/tmp/reviewed-read-only",
          guestName: "Reference",
          readOnly: true
        ),
        LiveLinuxVirtualMachineSharedDirectoryRequest(
          sourcePath: "/private/tmp/reviewed-read-write",
          guestName: "Workspace",
          readOnly: false
        ),
      ]
    )
    try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: requestURL.nativeContainersPOSIXPath
    )

    let configuration = try Self.loadRunRequest(at: requestURL)

    #expect(configuration.isoPath == request.isoPath)
    #expect(configuration.isoSHA256 == request.isoSHA256)
    #expect(
      configuration.visualHoldSeconds == Self.visualHoldMaximumSeconds
    )
    #expect(configuration.probesGuestInput)
    #expect(configuration.requiresInstallationMediaEjection)
    #expect(configuration.sharedDirectories.count == 2)
    #expect(configuration.sharedDirectories[0].guestName == "Reference")
    #expect(configuration.sharedDirectories[0].readOnly)
    #expect(configuration.sharedDirectories[1].guestName == "Workspace")
    #expect(!configuration.sharedDirectories[1].readOnly)
    #expect(
      !FileManager.default.fileExists(
        atPath: requestURL.nativeContainersPOSIXPath
      )
    )
  }

  @Test("Legacy live run request defaults to no shared directories")
  func legacyRunRequestDefaultsToNoSharedDirectories() throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-live-request-test-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let requestURL = rootURL.appending(
      path: "request.json",
      directoryHint: .notDirectory
    )
    let request = """
      {
        "isoPath": "/private/tmp/reviewed.iso",
        "isoSHA256": "\(String(repeating: "a", count: 64))",
        "visualHoldSeconds": 0,
        "probesGuestInput": false,
        "requiresInstallationMediaEjection": false
      }
      """
    try Data(request.utf8).write(to: requestURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: requestURL.nativeContainersPOSIXPath
    )

    let configuration = try Self.loadRunRequest(at: requestURL)

    #expect(configuration.sharedDirectories.isEmpty)
    #expect(
      !FileManager.default.fileExists(
        atPath: requestURL.nativeContainersPOSIXPath
      )
    )
  }

  @Test("Live run request rejects relative shared-directory paths")
  func liveRunRequestRejectsRelativeSharedDirectoryPaths() throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-live-request-test-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let requestURL = rootURL.appending(
      path: "request.json",
      directoryHint: .notDirectory
    )
    let request = LiveLinuxVirtualMachineRunRequest(
      isoPath: "/private/tmp/reviewed.iso",
      isoSHA256: String(repeating: "a", count: 64),
      visualHoldSeconds: 0,
      probesGuestInput: false,
      requiresInstallationMediaEjection: false,
      sharedDirectories: [
        LiveLinuxVirtualMachineSharedDirectoryRequest(
          sourcePath: "relative/path",
          guestName: "Workspace",
          readOnly: false
        )
      ]
    )
    try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: requestURL.nativeContainersPOSIXPath
    )

    #expect(throws: LiveLinuxVirtualMachineSmokeError.self) {
      try Self.loadRunRequest(at: requestURL)
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: requestURL.nativeContainersPOSIXPath
      )
    )
  }

  @Test("Unsafe live run request is rejected without deletion")
  func unsafeRunRequestIsRejectedWithoutDeletion() throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-live-request-test-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let requestURL = rootURL.appending(
      path: "request.json",
      directoryHint: .notDirectory
    )
    try Data("{}".utf8).write(to: requestURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: requestURL.nativeContainersPOSIXPath
    )

    #expect(throws: LiveLinuxVirtualMachineSmokeError.self) {
      try Self.loadRunRequest(at: requestURL)
    }
    #expect(
      FileManager.default.fileExists(
        atPath: requestURL.nativeContainersPOSIXPath
      )
    )
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

  private static func runConfiguration(
    _ environment: [String: String]
  ) throws -> LiveLinuxVirtualMachineRunConfiguration {
    if environment["NATIVECONTAINERS_LIVE_LINUX_VM"] != "1" {
      return try loadRunRequest(at: liveLinuxVirtualMachineRunRequestURL)
    }
    guard
      let isoPath = environment["NATIVECONTAINERS_LIVE_LINUX_VM_ISO"],
      !isoPath.isEmpty
    else {
      throw LiveLinuxVirtualMachineSmokeError.missingEnvironment(
        "NATIVECONTAINERS_LIVE_LINUX_VM_ISO"
      )
    }
    guard
      let isoSHA256 = environment[
        "NATIVECONTAINERS_LIVE_LINUX_VM_ISO_SHA256"
      ]
    else {
      throw LiveLinuxVirtualMachineSmokeError.missingEnvironment(
        "NATIVECONTAINERS_LIVE_LINUX_VM_ISO_SHA256"
      )
    }
    return LiveLinuxVirtualMachineRunConfiguration(
      isoPath: isoPath,
      isoSHA256: isoSHA256,
      visualHoldSeconds: try visualHoldSeconds(environment),
      probesGuestInput: environment[
        "NATIVECONTAINERS_LIVE_LINUX_VM_INPUT_PROBE"
      ] == "1",
      requiresInstallationMediaEjection: environment[
        "NATIVECONTAINERS_LIVE_LINUX_VM_REQUIRE_MEDIA_EJECTION"
      ] == "1",
      sharedDirectories: []
    )
  }

  private static func visualHoldSeconds(
    _ environment: [String: String]
  ) throws -> Int {
    guard
      let value = environment[
        "NATIVECONTAINERS_LIVE_LINUX_VM_VISUAL_SECONDS"
      ]
    else { return 0 }
    guard let seconds = Int(value),
      (1...Self.visualHoldMaximumSeconds).contains(seconds)
    else {
      throw LiveLinuxVirtualMachineSmokeError.invalidVisualHold(value)
    }
    return seconds
  }

  private static func loadRunRequest(
    at url: URL
  ) throws -> LiveLinuxVirtualMachineRunConfiguration {
    var metadata = stat()
    guard
      url.nativeContainersPOSIXPath.withCString({
        Darwin.lstat($0, &metadata)
      }) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == getuid(),
      metadata.st_nlink == 1,
      metadata.st_mode & 0o077 == 0
    else {
      throw LiveLinuxVirtualMachineSmokeError.invalidRunRequestFile
    }
    defer { try? FileManager.default.removeItem(at: url) }
    guard metadata.st_size > 0,
      metadata.st_size <= Self.runRequestMaximumBytes
    else {
      throw LiveLinuxVirtualMachineSmokeError.invalidRunRequestSize(
        Int(metadata.st_size)
      )
    }
    let request = try JSONDecoder().decode(
      LiveLinuxVirtualMachineRunRequest.self,
      from: Data(contentsOf: url)
    )
    guard
      (0...Self.visualHoldMaximumSeconds).contains(
        request.visualHoldSeconds
      )
    else {
      throw LiveLinuxVirtualMachineSmokeError.invalidVisualHold(
        String(request.visualHoldSeconds)
      )
    }
    let sharedDirectories = request.sharedDirectories ?? []
    guard
      sharedDirectories.count <= Self.runRequestMaximumSharedDirectoryCount
    else {
      throw LiveLinuxVirtualMachineSmokeError.invalidSharedDirectories(
        "at most \(Self.runRequestMaximumSharedDirectoryCount) folders may be requested"
      )
    }
    for directory in sharedDirectories {
      guard
        NSString(string: directory.sourcePath).isAbsolutePath,
        !directory.guestName.trimmingCharacters(
          in: .whitespacesAndNewlines
        ).isEmpty
      else {
        throw LiveLinuxVirtualMachineSmokeError.invalidSharedDirectories(
          "each folder needs an absolute source path and a guest name"
        )
      }
    }
    return LiveLinuxVirtualMachineRunConfiguration(
      isoPath: request.isoPath,
      isoSHA256: request.isoSHA256,
      visualHoldSeconds: request.visualHoldSeconds,
      probesGuestInput: request.probesGuestInput,
      requiresInstallationMediaEjection:
        request.requiresInstallationMediaEjection,
      sharedDirectories: sharedDirectories
    )
  }

  private func presentVisualConsole(
    _ console: LinuxVirtualMachineConsole,
    seconds: Int,
    probesGuestInput: Bool,
    onEjectInstallationMedia: @escaping () async throws -> Void
  ) async throws {
    let content = NSHostingView(
      rootView: VirtualMachineConsoleView(
        console: console,
        capturesSystemKeys: false,
        automaticallyReconfiguresDisplay: true
      )
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 800),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "NativeContainers Live Linux Visual"
    window.isReleasedWhenClosed = false
    window.contentView = content
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    NSApplication.shared.activate()

    let readyURL = FileManager.default.temporaryDirectory.appending(
      path:
        "nativecontainers-live-linux-vm-visual-ready-\(ProcessInfo.processInfo.processIdentifier).txt",
      directoryHint: .notDirectory
    )
    let inputChannel =
      probesGuestInput ? try Self.makeInputCommandChannel() : nil
    defer {
      window.orderOut(nil)
      window.close()
      try? FileManager.default.removeItem(at: readyURL)
      if let inputChannel {
        try? FileManager.default.removeItem(at: inputChannel.rootURL)
      }
    }
    try Self.writeVisualReadyMarker(
      at: readyURL,
      windowNumber: window.windowNumber,
      stage: "ready",
      commandURL: inputChannel?.commandURL
    )
    print(
      "NATIVECONTAINERS_LIVE_LINUX_VM_VISUAL_READY window=\(window.windowNumber) seconds=\(seconds)"
    )

    if probesGuestInput {
      try await performGuestInputProbe(
        in: content,
        window: window,
        readyURL: readyURL,
        commandURL: inputChannel?.commandURL
      )
    }
    let remainingSeconds =
      seconds - (probesGuestInput ? Self.inputProbeDurationSeconds : 0)
    if remainingSeconds > 0 {
      if let inputChannel {
        try await processGuestInputCommands(
          for: remainingSeconds,
          channel: inputChannel,
          content: content,
          window: window,
          readyURL: readyURL,
          onEjectInstallationMedia: onEjectInstallationMedia
        )
      } else {
        try await Task.sleep(for: .seconds(remainingSeconds))
      }
    }
  }

  private func performGuestInputProbe(
    in content: NSView,
    window: NSWindow,
    readyURL: URL,
    commandURL: URL?
  ) async throws {
    try await Task.sleep(
      for: .seconds(Self.inputProbeActivationDelaySeconds)
    )
    content.layoutSubtreeIfNeeded()
    guard
      let virtualMachineView = Self.firstDescendant(
        of: VZVirtualMachineView.self,
        in: content
      )
    else {
      throw LiveLinuxVirtualMachineSmokeError.missingVirtualMachineView
    }
    guard window.makeFirstResponder(virtualMachineView) else {
      throw LiveLinuxVirtualMachineSmokeError.virtualMachineViewRejectedFocus
    }

    try Self.sendGuestKey(.downArrow, to: virtualMachineView, in: window)
    try Self.writeVisualReadyMarker(
      at: readyURL,
      windowNumber: window.windowNumber,
      stage: "down-arrow",
      commandURL: commandURL
    )
    print(
      "NATIVECONTAINERS_LIVE_LINUX_VM_INPUT_READY window=\(window.windowNumber) key=down-arrow seconds=\(Self.inputProbeObservationSeconds)"
    )
    try await Task.sleep(
      for: .seconds(Self.inputProbeObservationSeconds)
    )

    try Self.sendGuestKey(.upArrow, to: virtualMachineView, in: window)
    try Self.sendGuestKey(.carriageReturn, to: virtualMachineView, in: window)
    try Self.writeVisualReadyMarker(
      at: readyURL,
      windowNumber: window.windowNumber,
      stage: "boot",
      commandURL: commandURL
    )
    print(
      "NATIVECONTAINERS_LIVE_LINUX_VM_INPUT_SENT window=\(window.windowNumber) keys=down-arrow,up-arrow,return"
    )
  }

  private func processGuestInputCommands(
    for seconds: Int,
    channel: LiveLinuxVirtualMachineInputChannel,
    content: NSView,
    window: NSWindow,
    readyURL: URL,
    onEjectInstallationMedia: @escaping () async throws -> Void
  ) async throws {
    content.layoutSubtreeIfNeeded()
    guard
      let virtualMachineView = Self.firstDescendant(
        of: VZVirtualMachineView.self,
        in: content
      )
    else {
      throw LiveLinuxVirtualMachineSmokeError.missingVirtualMachineView
    }
    guard window.makeFirstResponder(virtualMachineView) else {
      throw LiveLinuxVirtualMachineSmokeError.virtualMachineViewRejectedFocus
    }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(seconds))
    while clock.now < deadline {
      try Task.checkCancellation()
      if FileManager.default.fileExists(
        atPath: channel.commandURL.nativeContainersPOSIXPath
      ) {
        let command = try Self.readInputCommand(at: channel.commandURL)
        try FileManager.default.removeItem(at: channel.commandURL)
        if case .finish = command.action {
          try Self.writeVisualReadyMarker(
            at: readyURL,
            windowNumber: window.windowNumber,
            stage: "command-\(command.id)",
            commandURL: channel.commandURL
          )
          print(
            "NATIVECONTAINERS_LIVE_LINUX_VM_COMMAND id=\(command.id) action=\(command.summary)"
          )
          return
        }
        try await Self.executeGuestInputCommand(
          command,
          in: virtualMachineView,
          window: window,
          onEjectInstallationMedia: onEjectInstallationMedia
        )
        try Self.writeVisualReadyMarker(
          at: readyURL,
          windowNumber: window.windowNumber,
          stage: "command-\(command.id)",
          commandURL: channel.commandURL
        )
        print(
          "NATIVECONTAINERS_LIVE_LINUX_VM_COMMAND id=\(command.id) action=\(command.summary)"
        )
      }

      let remaining = clock.now.duration(to: deadline)
      if remaining > .zero {
        try await Task.sleep(
          for: min(remaining, .milliseconds(200))
        )
      }
    }
  }

  private static func makeInputCommandChannel() throws
    -> LiveLinuxVirtualMachineInputChannel
  {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path:
        "nativecontainers-live-linux-vm-input-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: rootURL.nativeContainersPOSIXPath
    )
    return LiveLinuxVirtualMachineInputChannel(rootURL: rootURL)
  }

  private static func parseInputCommand(_ data: Data) throws
    -> LiveLinuxVirtualMachineInputCommand
  {
    guard data.count <= inputCommandMaximumBytes,
      let value = String(data: data, encoding: .utf8)
    else {
      throw LiveLinuxVirtualMachineSmokeError.invalidInputCommand(
        "encoding"
      )
    }
    let fields = value.trimmingCharacters(in: .newlines).split(
      separator: "\t",
      omittingEmptySubsequences: false
    )
    guard fields.count >= 3 else {
      throw LiveLinuxVirtualMachineSmokeError.invalidInputCommand(
        "field-count"
      )
    }
    let identifier = String(fields[0])
    guard (1...64).contains(identifier.count),
      identifier.allSatisfy({
        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
      })
    else {
      throw LiveLinuxVirtualMachineSmokeError.invalidInputCommand(
        "identifier"
      )
    }

    let action: LiveLinuxVirtualMachineInputCommand.Action
    switch fields[1] {
    case "key":
      guard fields.count == 3,
        let key = LiveLinuxVirtualMachineInputKey(
          commandValue: String(fields[2])
        )
      else {
        throw LiveLinuxVirtualMachineSmokeError.invalidInputCommand("key")
      }
      action = .key(key)
    case "click":
      guard fields.count == 4,
        let x = Double(fields[2]), x.isFinite,
        let y = Double(fields[3]), y.isFinite
      else {
        throw LiveLinuxVirtualMachineSmokeError.invalidInputCommand("click")
      }
      action = .click(x: x, y: y)
    case "text":
      guard fields.count == 3,
        let encoded = Data(base64Encoded: String(fields[2])),
        let text = String(data: encoded, encoding: .utf8),
        text.count <= inputTextMaximumCharacters
      else {
        throw LiveLinuxVirtualMachineSmokeError.invalidInputCommand("text")
      }
      action = .text(text)
    case "eject-media":
      guard fields.count == 3, fields[2] == "-" else {
        throw LiveLinuxVirtualMachineSmokeError.invalidInputCommand(
          "eject-media"
        )
      }
      action = .ejectInstallationMedia
    case "finish":
      guard fields.count == 3, fields[2] == "-" else {
        throw LiveLinuxVirtualMachineSmokeError.invalidInputCommand("finish")
      }
      action = .finish
    default:
      throw LiveLinuxVirtualMachineSmokeError.invalidInputCommand("action")
    }
    return LiveLinuxVirtualMachineInputCommand(
      id: identifier,
      action: action
    )
  }

  private static func readInputCommand(
    at url: URL
  ) throws -> LiveLinuxVirtualMachineInputCommand {
    var metadata = stat()
    guard
      url.nativeContainersPOSIXPath.withCString({
        Darwin.lstat($0, &metadata)
      }) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == getuid(),
      metadata.st_nlink == 1
    else {
      throw LiveLinuxVirtualMachineSmokeError.invalidInputCommandFile
    }
    guard metadata.st_size >= 0,
      metadata.st_size <= Self.inputCommandMaximumBytes
    else {
      throw LiveLinuxVirtualMachineSmokeError.inputCommandTooLarge(
        Int(metadata.st_size)
      )
    }
    return try parseInputCommand(Data(contentsOf: url))
  }

  private static func executeGuestInputCommand(
    _ command: LiveLinuxVirtualMachineInputCommand,
    in view: VZVirtualMachineView,
    window: NSWindow,
    onEjectInstallationMedia: @escaping () async throws -> Void
  ) async throws {
    switch command.action {
    case .key(let key):
      try sendGuestKey(key, to: view, in: window)
    case .click(let x, let y):
      try sendGuestClick(x: x, y: y, to: view, in: window)
    case .text(let text):
      for character in text {
        try sendGuestCharacter(character, to: view, in: window)
        try await Task.sleep(for: .milliseconds(20))
      }
    case .ejectInstallationMedia:
      try await onEjectInstallationMedia()
    case .finish:
      break
    }
  }

  private static func firstDescendant<View: NSView>(
    of type: View.Type,
    in root: NSView
  ) -> View? {
    if let match = root as? View { return match }
    for subview in root.subviews {
      if let match = firstDescendant(of: type, in: subview) {
        return match
      }
    }
    return nil
  }

  private static func sendGuestKey(
    _ key: LiveLinuxVirtualMachineInputKey,
    to view: VZVirtualMachineView,
    in window: NSWindow
  ) throws {
    try sendGuestKeyEvents(
      characters: key.characters,
      charactersIgnoringModifiers: key.charactersIgnoringModifiers,
      modifierFlags: key.modifierFlags,
      keyCode: key.keyCode,
      description: key.description,
      to: view,
      in: window
    )
  }

  private static func sendGuestCharacter(
    _ character: Character,
    to view: VZVirtualMachineView,
    in window: NSWindow
  ) throws {
    guard let typingKey = LiveLinuxVirtualMachineTypingKey(character) else {
      throw LiveLinuxVirtualMachineSmokeError.unsupportedInputCharacter(
        character
      )
    }
    try sendGuestKeyEvents(
      characters: String(character),
      charactersIgnoringModifiers: String(typingKey.characterIgnoringModifiers),
      modifierFlags: typingKey.modifierFlags,
      keyCode: typingKey.keyCode,
      description: "text-character",
      to: view,
      in: window
    )
  }

  private static func sendGuestKeyEvents(
    characters: String,
    charactersIgnoringModifiers: String,
    modifierFlags: NSEvent.ModifierFlags,
    keyCode: UInt16,
    description: String,
    to view: VZVirtualMachineView,
    in window: NSWindow
  ) throws {
    let modifierTransitions = guestModifierTransitions(for: modifierFlags)
    let guestModifierFlags =
      modifierTransitions.presses.last?.modifierFlags ?? []
    let modifierPressEvents = modifierTransitions.presses.compactMap {
      guestFlagsChangedEvent(
        transition: $0,
        windowNumber: window.windowNumber
      )
    }
    let modifierReleaseEvents = modifierTransitions.releases.compactMap {
      guestFlagsChangedEvent(
        transition: $0,
        windowNumber: window.windowNumber
      )
    }
    guard
      modifierPressEvents.count == modifierTransitions.presses.count,
      modifierReleaseEvents.count == modifierTransitions.releases.count,
      let down = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: guestModifierFlags,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        isARepeat: false,
        keyCode: keyCode
      ),
      let up = NSEvent.keyEvent(
        with: .keyUp,
        location: .zero,
        modifierFlags: guestModifierFlags,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        isARepeat: false,
        keyCode: keyCode
      )
    else {
      throw LiveLinuxVirtualMachineSmokeError.couldNotCreateKeyEvent(
        description
      )
    }
    for event in modifierPressEvents {
      view.flagsChanged(with: event)
    }
    view.keyDown(with: down)
    view.keyUp(with: up)
    for event in modifierReleaseEvents {
      view.flagsChanged(with: event)
    }
  }

  private static func guestModifierTransitions(
    for modifierFlags: NSEvent.ModifierFlags
  ) -> (
    presses: [LiveLinuxVirtualMachineModifierTransition],
    releases: [LiveLinuxVirtualMachineModifierTransition]
  ) {
    // VZVirtualMachineView needs AppKit's left-device bits as well as the
    // device-independent flags to turn synthetic changes into guest keypresses.
    let modifierKeys:
      [(
        flag: NSEvent.ModifierFlags,
        deviceFlag: NSEvent.ModifierFlags,
        keyCode: UInt16
      )] = [
        (.shift, NSEvent.ModifierFlags(rawValue: 0x0000_0002), 0x38),
        (.control, NSEvent.ModifierFlags(rawValue: 0x0000_0001), 0x3B),
        (.option, NSEvent.ModifierFlags(rawValue: 0x0000_0020), 0x3A),
      ]
    var activeFlags: NSEvent.ModifierFlags = []
    var presses: [LiveLinuxVirtualMachineModifierTransition] = []
    for modifier in modifierKeys where modifierFlags.contains(modifier.flag) {
      activeFlags.insert(modifier.flag)
      activeFlags.insert(modifier.deviceFlag)
      presses.append(
        LiveLinuxVirtualMachineModifierTransition(
          keyCode: modifier.keyCode,
          modifierFlags: activeFlags
        )
      )
    }

    var releases: [LiveLinuxVirtualMachineModifierTransition] = []
    for modifier in modifierKeys.reversed()
    where modifierFlags.contains(modifier.flag) {
      activeFlags.remove(modifier.flag)
      activeFlags.remove(modifier.deviceFlag)
      releases.append(
        LiveLinuxVirtualMachineModifierTransition(
          keyCode: modifier.keyCode,
          modifierFlags: activeFlags
        )
      )
    }
    return (presses, releases)
  }

  private static func guestFlagsChangedEvent(
    transition: LiveLinuxVirtualMachineModifierTransition,
    windowNumber: Int
  ) -> NSEvent? {
    NSEvent.keyEvent(
      with: .flagsChanged,
      location: .zero,
      modifierFlags: transition.modifierFlags,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: windowNumber,
      context: nil,
      characters: "",
      charactersIgnoringModifiers: "",
      isARepeat: false,
      keyCode: transition.keyCode
    )
  }

  private static func sendGuestClick(
    x: Double,
    y: Double,
    to view: VZVirtualMachineView,
    in window: NSWindow
  ) throws {
    guard x >= 0, x <= view.bounds.width,
      y >= 0, y <= view.bounds.height
    else {
      throw LiveLinuxVirtualMachineSmokeError.inputClickOutsideDisplay(
        x: x,
        y: y,
        width: view.bounds.width,
        height: view.bounds.height
      )
    }
    let viewLocation = NSPoint(x: x, y: view.bounds.height - y)
    let windowLocation = view.convert(viewLocation, to: nil)
    guard
      let moved = NSEvent.mouseEvent(
        with: .mouseMoved,
        location: windowLocation,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0
      ),
      let down = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: windowLocation,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
      ),
      let up = NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: windowLocation,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 0
      )
    else {
      throw LiveLinuxVirtualMachineSmokeError.couldNotCreateMouseEvent
    }
    view.mouseMoved(with: moved)
    view.mouseDown(with: down)
    view.mouseUp(with: up)
  }

  private static func writeVisualReadyMarker(
    at url: URL,
    windowNumber: Int,
    stage: String,
    commandURL: URL?
  ) throws {
    var marker = "window=\(windowNumber)\nstage=\(stage)\n"
    if let commandURL {
      marker += "command=\(commandURL.nativeContainersPOSIXPath)\n"
    }
    try Data(marker.utf8).write(
      to: url,
      options: .atomic
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.nativeContainersPOSIXPath
    )
  }
}

private struct LiveLinuxVirtualMachineRunRequest: Codable {
  let isoPath: String
  let isoSHA256: String
  let visualHoldSeconds: Int
  let probesGuestInput: Bool
  let requiresInstallationMediaEjection: Bool
  let sharedDirectories: [LiveLinuxVirtualMachineSharedDirectoryRequest]?
}

private struct LiveLinuxVirtualMachineRunConfiguration {
  let isoPath: String
  let isoSHA256: String
  let visualHoldSeconds: Int
  let probesGuestInput: Bool
  let requiresInstallationMediaEjection: Bool
  let sharedDirectories: [LiveLinuxVirtualMachineSharedDirectoryRequest]
}

private struct LiveLinuxVirtualMachineSharedDirectoryRequest: Codable {
  let sourcePath: String
  let guestName: String
  let readOnly: Bool
}

private struct LiveLinuxVirtualMachineInputChannel {
  let rootURL: URL

  var commandURL: URL {
    rootURL.appending(path: "command", directoryHint: .notDirectory)
  }
}

private struct LiveLinuxVirtualMachineInputCommand {
  enum Action {
    case key(LiveLinuxVirtualMachineInputKey)
    case click(x: Double, y: Double)
    case text(String)
    case ejectInstallationMedia
    case finish
  }

  let id: String
  let action: Action

  var summary: String {
    switch action {
    case .key(let key): "key:\(key.description)"
    case .click(let x, let y): "click:\(Int(x)),\(Int(y))"
    case .text(let value): "text:\(value.count)-characters"
    case .ejectInstallationMedia: "eject-media"
    case .finish: "finish"
    }
  }
}

private struct LiveLinuxVirtualMachineModifierTransition {
  let keyCode: UInt16
  let modifierFlags: NSEvent.ModifierFlags
}

private enum LiveLinuxVirtualMachineInputKey: CustomStringConvertible {
  case tab
  case shiftTab
  case escape
  case space
  case leftArrow
  case rightArrow
  case downArrow
  case upArrow
  case carriageReturn
  case openTerminal

  init?(commandValue: String) {
    switch commandValue {
    case "tab": self = .tab
    case "shift-tab": self = .shiftTab
    case "escape": self = .escape
    case "space": self = .space
    case "left": self = .leftArrow
    case "right": self = .rightArrow
    case "down": self = .downArrow
    case "up": self = .upArrow
    case "return": self = .carriageReturn
    case "open-terminal": self = .openTerminal
    default: return nil
    }
  }

  var keyCode: UInt16 {
    switch self {
    case .tab, .shiftTab: 0x30
    case .escape: 0x35
    case .space: 0x31
    case .leftArrow: 0x7B
    case .rightArrow: 0x7C
    case .downArrow: 0x7D
    case .upArrow: 0x7E
    case .carriageReturn: 0x24
    case .openTerminal: 0x11
    }
  }

  var characters: String {
    switch self {
    case .tab, .shiftTab: "\t"
    case .escape: "\u{1B}"
    case .space: " "
    case .leftArrow: String(NSEvent.SpecialKey.leftArrow.unicodeScalar)
    case .rightArrow: String(NSEvent.SpecialKey.rightArrow.unicodeScalar)
    case .downArrow: String(NSEvent.SpecialKey.downArrow.unicodeScalar)
    case .upArrow: String(NSEvent.SpecialKey.upArrow.unicodeScalar)
    case .carriageReturn:
      String(NSEvent.SpecialKey.carriageReturn.unicodeScalar)
    case .openTerminal: "t"
    }
  }

  var charactersIgnoringModifiers: String { characters }

  var modifierFlags: NSEvent.ModifierFlags {
    switch self {
    case .shiftTab: .shift
    case .openTerminal: [.control, .option]
    default: []
    }
  }

  var description: String {
    switch self {
    case .tab: "tab"
    case .shiftTab: "shift-tab"
    case .escape: "escape"
    case .space: "space"
    case .leftArrow: "left-arrow"
    case .rightArrow: "right-arrow"
    case .downArrow: "down-arrow"
    case .upArrow: "up-arrow"
    case .carriageReturn: "return"
    case .openTerminal: "open-terminal"
    }
  }
}

private struct LiveLinuxVirtualMachineTypingKey {
  let keyCode: UInt16
  let characterIgnoringModifiers: Character
  let modifierFlags: NSEvent.ModifierFlags

  init?(_ character: Character) {
    let lowercased = Character(String(character).lowercased())
    let letterKeyCodes: [Character: UInt16] = [
      "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E,
      "f": 0x03, "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26,
      "k": 0x28, "l": 0x25, "m": 0x2E, "n": 0x2D, "o": 0x1F,
      "p": 0x23, "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11,
      "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07, "y": 0x10,
      "z": 0x06,
    ]
    if let keyCode = letterKeyCodes[lowercased] {
      self.keyCode = keyCode
      characterIgnoringModifiers = lowercased
      modifierFlags = character.isUppercase ? .shift : []
      return
    }
    let digitKeyCodes: [Character: UInt16] = [
      "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
      "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19,
    ]
    if let keyCode = digitKeyCodes[character] {
      self.keyCode = keyCode
      characterIgnoringModifiers = character
      modifierFlags = []
      return
    }
    switch character {
    case " ":
      keyCode = 0x31
      characterIgnoringModifiers = " "
      modifierFlags = []
    case "-":
      keyCode = 0x1B
      characterIgnoringModifiers = "-"
      modifierFlags = []
    case "_":
      keyCode = 0x1B
      characterIgnoringModifiers = "-"
      modifierFlags = .shift
    case ".":
      keyCode = 0x2F
      characterIgnoringModifiers = "."
      modifierFlags = []
    case "/":
      keyCode = 0x2C
      characterIgnoringModifiers = "/"
      modifierFlags = []
    default:
      return nil
    }
  }
}

private enum LiveLinuxVirtualMachineSmokeError: LocalizedError {
  case missingEnvironment(String)
  case invalidISO(URL)
  case digestMismatch(expected: String, actual: String)
  case invalidVisualHold(String)
  case inputProbeRequiresVisualHold(minimumSeconds: Int)
  case missingVirtualMachineView
  case virtualMachineViewRejectedFocus
  case couldNotCreateKeyEvent(String)
  case couldNotCreateMouseEvent
  case inputCommandTooLarge(Int)
  case invalidInputCommandFile
  case invalidInputCommand(String)
  case invalidRunRequestFile
  case invalidRunRequestSize(Int)
  case invalidSharedDirectories(String)
  case mediaEjectionRequiresInputChannel
  case mediaEjectionDidNotPersist
  case requiredMediaEjectionMissing
  case unsupportedInputCharacter(Character)
  case inputClickOutsideDisplay(
    x: Double,
    y: Double,
    width: Double,
    height: Double
  )

  var errorDescription: String? {
    switch self {
    case .missingEnvironment(let name):
      "Set \(name) before running the live Linux virtual-machine smoke."
    case .invalidISO(let url):
      "The live Linux virtual-machine fixture must be a local .iso file, not \(url.lastPathComponent)."
    case .digestMismatch(let expected, let actual):
      "The live Linux virtual-machine ISO SHA-256 changed (expected \(expected), found \(actual))."
    case .invalidVisualHold(let value):
      "The live visual hold must be between 1 and 7,200 seconds, not \(value)."
    case .inputProbeRequiresVisualHold(let minimumSeconds):
      "The live guest-input probe requires a visual hold of at least \(minimumSeconds) seconds."
    case .missingVirtualMachineView:
      "The live visual console did not create its VZVirtualMachineView."
    case .virtualMachineViewRejectedFocus:
      "The live VZVirtualMachineView refused first-responder focus."
    case .couldNotCreateKeyEvent(let key):
      "AppKit could not create the live guest \(key) key event."
    case .couldNotCreateMouseEvent:
      "AppKit could not create the live guest mouse event."
    case .inputCommandTooLarge(let byteCount):
      "The live guest-input command is too large (\(byteCount) bytes)."
    case .invalidInputCommandFile:
      "The live guest-input command must be a single-link regular file owned by this user."
    case .invalidInputCommand(let reason):
      "The live guest-input command is invalid (\(reason))."
    case .invalidRunRequestFile:
      "The one-shot live run request must be a single-link regular file owned by this user with no group or other access."
    case .invalidRunRequestSize(let byteCount):
      "The one-shot live run request has an invalid size (\(byteCount) bytes)."
    case .invalidSharedDirectories(let reason):
      "The one-shot live run request has invalid shared folders (\(reason))."
    case .mediaEjectionRequiresInputChannel:
      "Required installation-media ejection needs the live guest-input command channel."
    case .mediaEjectionDidNotPersist:
      "The production runtime detached the installer, but the completed-installation manifest did not persist."
    case .requiredMediaEjectionMissing:
      "The live run required installation-media ejection, but no eject-media command completed."
    case .unsupportedInputCharacter(let character):
      "The live guest-input command cannot type \(String(reflecting: character))."
    case .inputClickOutsideDisplay(let x, let y, let width, let height):
      "The live guest click (\(x), \(y)) is outside the \(width)×\(height) display."
    }
  }
}
