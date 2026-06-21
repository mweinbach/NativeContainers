import Foundation
import Testing

@testable import NativeContainers

struct MacGuestProvisioningTests {
  @Test
  func requestNormalizesNamesWithoutChangingTheSecret() throws {
    let request = try MacGuestProvisioningRequest(
      fullName: "  Ada Lovelace  ",
      username: "  ada  ",
      password: " password with spaces ",
      logsInAutomatically: true,
      enablesRemoteLogin: true
    )

    #expect(request.fullName == "Ada Lovelace")
    #expect(request.username == "ada")
    #expect(request.password == " password with spaces ")
    #expect(request.logsInAutomatically)
    #expect(request.enablesRemoteLogin)
  }

  @Test
  func requestRejectsMissingRequiredCredentials() {
    #expect(throws: MacGuestProvisioningError.emptyFullName) {
      _ = try MacGuestProvisioningRequest(
        fullName: " ",
        username: "ada",
        password: "secret",
        logsInAutomatically: false,
        enablesRemoteLogin: false
      )
    }
    #expect(throws: MacGuestProvisioningError.emptyUsername) {
      _ = try MacGuestProvisioningRequest(
        fullName: "Ada",
        username: "\n",
        password: "secret",
        logsInAutomatically: false,
        enablesRemoteLogin: false
      )
    }
    #expect(throws: MacGuestProvisioningError.emptyPassword) {
      _ = try MacGuestProvisioningRequest(
        fullName: "Ada",
        username: "ada",
        password: "",
        logsInAutomatically: false,
        enablesRemoteLogin: false
      )
    }
  }

  @Test
  func policyRequiresSupportedHostGuestAndUnclaimedFirstBoot() throws {
    var manifest = try makeManifest()
    manifest.macOSGuestOperatingSystem = MacGuestOperatingSystemIdentity(
      buildVersion: "TEST",
      majorVersion: 27,
      minorVersion: 0,
      patchVersion: 0
    )
    manifest.macOSFirstBootState = .pending

    try MacGuestProvisioningPolicy(
      hostSupportsProvisioning: true
    ).validate(
      manifest: manifest,
      resumesSavedState: false
    )

    #expect(throws: MacGuestProvisioningError.hostUnsupported) {
      try MacGuestProvisioningPolicy(
        hostSupportsProvisioning: false
      ).validate(
        manifest: manifest,
        resumesSavedState: false
      )
    }

    manifest.macOSGuestOperatingSystem = nil
    #expect(throws: MacGuestProvisioningError.guestVersionUnknown) {
      try MacGuestProvisioningPolicy(
        hostSupportsProvisioning: true
      ).validate(
        manifest: manifest,
        resumesSavedState: false
      )
    }

    manifest.macOSGuestOperatingSystem = MacGuestOperatingSystemIdentity(
      buildVersion: "OLD",
      majorVersion: 26,
      minorVersion: 4,
      patchVersion: 0
    )
    #expect(
      throws: MacGuestProvisioningError.guestUnsupported("26.4.0")
    ) {
      try MacGuestProvisioningPolicy(
        hostSupportsProvisioning: true
      ).validate(
        manifest: manifest,
        resumesSavedState: false
      )
    }

    manifest.macOSGuestOperatingSystem = MacGuestOperatingSystemIdentity(
      buildVersion: "TEST",
      majorVersion: 27,
      minorVersion: 0,
      patchVersion: 0
    )
    manifest.macOSFirstBootState = .started
    #expect(throws: MacGuestProvisioningError.firstBootUnavailable) {
      try MacGuestProvisioningPolicy(
        hostSupportsProvisioning: true
      ).validate(
        manifest: manifest,
        resumesSavedState: false
      )
    }

    manifest.macOSFirstBootState = .pending
    #expect(throws: MacGuestProvisioningError.savedStateConflict) {
      try MacGuestProvisioningPolicy(
        hostSupportsProvisioning: true
      ).validate(
        manifest: manifest,
        resumesSavedState: true
      )
    }
  }

  @Test
  func firstBootServiceUsesExplicitStateTransitions() async throws {
    var manifest = try makeManifest()
    manifest.macOSFirstBootState = .pending
    let lease = makeLease(manifest: manifest)
    defer { lease.release() }
    let persistence = ProvisioningTransitionRecorder()
    let service = MacVirtualMachineFirstBootService(
      persistence: persistence
    )

    let attempt = try #require(try await service.begin(for: lease))
    try await service.complete(attempt, for: lease)

    #expect(
      await persistence.transitions
        == [
          ProvisioningTransition(from: .pending, to: .launching),
          ProvisioningTransition(from: .launching, to: .started),
        ]
    )
  }

  @Test
  func firstBootServiceIgnoresAlreadyClaimedMachines() async throws {
    var manifest = try makeManifest()
    manifest.macOSFirstBootState = .started
    let lease = makeLease(manifest: manifest)
    defer { lease.release() }
    let persistence = ProvisioningTransitionRecorder()
    let service = MacVirtualMachineFirstBootService(
      persistence: persistence
    )

    #expect(try await service.begin(for: lease) == nil)
    #expect(await persistence.transitions.isEmpty)
  }

  @Test
  @MainActor
  func formModelRequiresMatchingPasswordsAndClearsSecrets() throws {
    let model = MacGuestProvisioningFormModel()
    model.fullName = "Ada Lovelace"
    model.username = "ada"
    model.password = "secret"
    model.passwordConfirmation = "different"

    #expect(!model.canSubmit)
    #expect(throws: MacGuestProvisioningError.passwordsDoNotMatch) {
      _ = try model.makeRequest()
    }

    model.passwordConfirmation = "secret"
    #expect(model.canSubmit)
    #expect(try model.makeRequest().username == "ada")

    model.clearSecrets()
    #expect(model.password.isEmpty)
    #expect(model.passwordConfirmation.isEmpty)
    #expect(!model.canSubmit)
  }

  private func makeManifest() throws -> VirtualMachineManifest {
    try VirtualMachineManifest(
      name: "Provisioning Test",
      guest: .macOS,
      installState: .stopped,
      resources: VirtualMachineResources(
        cpuCount: 4,
        memoryBytes: 8 * VirtualMachineResources.bytesPerGiB,
        diskBytes: 64 * VirtualMachineResources.bytesPerGiB
      )
    )
  }

  private func makeLease(
    manifest: VirtualMachineManifest
  ) -> MacVirtualMachineRuntimeLease {
    let bundleURL = URL(
      filePath: "/tmp/\(manifest.id.uuidString).nativevm",
      directoryHint: .isDirectory
    )
    let machine = ResolvedMacVirtualMachine(
      manifest: manifest,
      bundleURL: bundleURL,
      diskImageURL: bundleURL.appending(path: "Disk.img"),
      auxiliaryStorageURL: bundleURL.appending(path: "AuxiliaryStorage"),
      hardwareModelURL: bundleURL.appending(path: "HardwareModel"),
      machineIdentifierURL: bundleURL.appending(path: "MachineIdentifier")
    )
    return MacVirtualMachineRuntimeLease(
      machine: machine,
      target: MacVirtualMachineRuntimeTarget(
        machineID: manifest.id,
        generation: UUID()
      ),
      release: {}
    )
  }
}

private struct ProvisioningTransition: Equatable, Sendable {
  let from: MacVirtualMachineFirstBootState
  let to: MacVirtualMachineFirstBootState
}

private actor ProvisioningTransitionRecorder:
  MacVirtualMachineFirstBootPersisting
{
  private(set) var transitions: [ProvisioningTransition] = []

  func transitionMacOSFirstBootState(
    from expectedState: MacVirtualMachineFirstBootState,
    to newState: MacVirtualMachineFirstBootState,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws {
    transitions.append(
      ProvisioningTransition(from: expectedState, to: newState)
    )
  }
}
