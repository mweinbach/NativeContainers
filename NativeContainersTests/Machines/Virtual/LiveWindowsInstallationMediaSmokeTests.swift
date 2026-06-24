import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing
@preconcurrency import Virtualization

@testable import NativeContainers

private let suppliedWindowsISO = FileManager.default.homeDirectoryForCurrentUser
  .appending(path: "Downloads/Win11_25H2_English_Arm64_v2.iso")
private let liveWindowsVirtualMachineRunRequestURL = URL(
  filePath: "/tmp/nativecontainers-live-windows-vm-run-request"
)

@Suite("Live Windows installation media", .serialized)
struct LiveWindowsInstallationMediaSmokeTests {
  private static let expectedByteCount: UInt64 = 7_994_415_104
  private static let expectedSHA256 =
    "638aa2c88e94385b00f4f178d071e3df0b7d9e335577a83bd533b7f2eb65adf0"

  @Test(
    .enabled(
      if: FileManager.default.fileExists(atPath: suppliedWindowsISO.path),
      "Place Win11_25H2_English_Arm64_v2.iso in Downloads to run the live media check."
    )
  )
  func verifiesSuppliedWindows11ARM64ISOWithoutModifyingIt() async throws {
    let original = try suppliedWindowsISO.resourceValues(
      forKeys: [.fileSizeKey, .contentModificationDateKey]
    )
    let digest = try await sha256(of: suppliedWindowsISO)
    let metadata = try await DiskutilWindowsInstallationMediaInspector().inspect(
      installationMediaURL: suppliedWindowsISO,
      sourceFilename: suppliedWindowsISO.lastPathComponent,
      copy: WindowsInstallationMediaCopyResult(
        sha256: digest,
        byteCount: UInt64(try #require(original.fileSize))
      )
    )
    let final = try suppliedWindowsISO.resourceValues(
      forKeys: [.fileSizeKey, .contentModificationDateKey]
    )

    #expect(metadata.sha256 == Self.expectedSHA256)
    #expect(metadata.byteCount == Self.expectedByteCount)
    #expect(metadata.volumeLabel == "CCCOMA_A64FRE_EN-US_DV9")
    #expect(metadata.architecture == .arm64)
    #expect(metadata.efiBootManagerPath == "efi/boot/bootaa64.efi")
    #expect(metadata.bootImagePath == "sources/boot.wim")
    #expect(metadata.installImagePath == "sources/install.wim")
    #expect(final.fileSize == original.fileSize)
    #expect(final.contentModificationDate == original.contentModificationDate)
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment[
        "NATIVECONTAINERS_LIVE_WINDOWS_VM"
      ] == "1"
        || FileManager.default.fileExists(
          atPath: liveWindowsVirtualMachineRunRequestURL.path
        ),
      "Set NATIVECONTAINERS_LIVE_WINDOWS_VM=1 or create the one-shot run request."
    )
  )
  @MainActor
  func bootsSuppliedWindows11ARM64InstallerAndCleansIsolatedBundle() async throws {
    try? FileManager.default.removeItem(at: liveWindowsVirtualMachineRunRequestURL)

    let suffix = UUID().uuidString.lowercased()
    let libraryRoot = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-live-windows-vm-\(suffix)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: libraryRoot,
      withIntermediateDirectories: false
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: libraryRoot.path
    )

    let library = VirtualMachineLibrary(rootURL: libraryRoot)
    let creator = WindowsVirtualMachineCreationService(library: library)
    let runtime = LinuxVirtualMachineRuntimeService(
      leasingStore: library,
      installationStore: library,
      engine: AppleLinuxVirtualMachineRuntimeEngine(),
      savedStateService: LinuxVirtualMachineSavedStateService(
        store: LinuxVirtualMachineSavedStateStore()
      )
    )
    let resources = try VirtualMachineResources(
      cpuCount: min(4, max(2, ProcessInfo.processInfo.processorCount)),
      memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 64 * VirtualMachineResources.bytesPerGiB
    )
    var machineID: UUID?

    do {
      let machine = try await creator.createWindowsVirtualMachine(
        name: "NativeContainers Live Windows \(suffix.prefix(8))",
        resources: resources,
        installationMediaURL: suppliedWindowsISO,
        securityMode: .currentDefault
      )
      machineID = machine.id
      #expect(machine.installState == .readyToInstall)
      #expect(machine.windowsConfiguration?.installationMediaPath != nil)
      #expect(machine.windowsConfiguration?.setupConfigurationMediaPath != nil)
      #expect(machine.windowsConfiguration?.securityMode == .currentDefault)

      try await runtime.start(id: machine.id)
      var snapshot = runtime.snapshot(for: machine.id)
      let target = try #require(snapshot.target)
      #expect(snapshot.state == .running)
      #expect(snapshot.hasInstallationMedia)
      let console = try #require(runtime.console(for: target))
      #expect(console.virtualMachine?.state == .running)

      try await presentVisualConsole(console, seconds: 45)
      snapshot = runtime.snapshot(for: machine.id)
      #expect(snapshot.state == .running)
      #expect(console.virtualMachine?.state == .running)

      try await runtime.pause(target: target)
      #expect(runtime.snapshot(for: machine.id).state == .paused)
      try await runtime.resume(target: target)
      #expect(runtime.snapshot(for: machine.id).state == .running)

      try await runtime.forceStop(target: target)
      #expect(runtime.snapshot(for: machine.id).state == .stopped)
      try await library.discardVirtualMachine(id: machine.id)
      machineID = nil
      #expect(try await library.list().isEmpty)
      try FileManager.default.removeItem(at: libraryRoot)

      print(
        "NATIVECONTAINERS_LIVE_WINDOWS_VM_RESULT id=\(machine.id.uuidString.lowercased()) running=confirmed pause_resume=confirmed visual_hold=45s cleanup=complete"
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

  @MainActor
  private func presentVisualConsole(
    _ console: LinuxVirtualMachineConsole,
    seconds: Int
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
    window.title = "NativeContainers Live Windows Visual"
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.contentView = content
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    NSApplication.shared.activate()
    defer {
      window.orderOut(nil)
      window.close()
    }

    content.layoutSubtreeIfNeeded()
    guard Self.firstDescendant(of: VZVirtualMachineView.self, in: content) != nil else {
      throw LiveWindowsVirtualMachineSmokeError.unableToPresentConsole
    }
    try await Task.sleep(for: .seconds(seconds))
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

  private func sha256(of url: URL) async throws -> String {
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    var hasher = SHA256()
    while let data = try input.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
      try Task.checkCancellation()
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

private enum LiveWindowsVirtualMachineSmokeError: LocalizedError {
  case unableToPresentConsole

  var errorDescription: String? {
    switch self {
    case .unableToPresentConsole:
      "The live Windows virtual-machine console could not be presented."
    }
  }
}
