import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct KubernetesClusterDescriptorStoreTests {
  @Test
  func storesLoadsAndRemovesOnePrivateDescriptorWithoutLosingIdentityPrecision() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    let store = KubernetesClusterDescriptorStore(rootURL: root)
    let descriptor = makeDescriptor()
    try await store.save(descriptor)

    let loaded = try await store.load()
    #expect(loaded == descriptor)
    #expect(
      loaded?.machine.createdAt?.timeIntervalSinceReferenceDate.bitPattern
        == descriptor.machine.createdAt?.timeIntervalSinceReferenceDate.bitPattern
    )

    var rootMetadata = stat()
    #expect(Darwin.lstat(root.nativeContainersPOSIXPath, &rootMetadata) == 0)
    #expect(rootMetadata.st_mode & mode_t(0o777) == mode_t(0o700))

    let file = root.appending(path: "Cluster.json", directoryHint: .notDirectory)
    var fileMetadata = stat()
    #expect(Darwin.lstat(file.nativeContainersPOSIXPath, &fileMetadata) == 0)
    #expect(fileMetadata.st_mode & mode_t(0o777) == mode_t(0o600))
    #expect(fileMetadata.st_nlink == 1)

    try await store.remove()
    #expect(try await store.load() == nil)
  }

  @Test
  func rejectsSymbolicRootWithoutChangingItsTarget() async throws {
    let parent = temporaryRoot().deletingLastPathComponent()
    let root = parent.appending(path: "Kubernetes", directoryHint: .isDirectory)
    let target = parent.appending(path: "target", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: parent) }

    try FileManager.default.createDirectory(
      at: target,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755]
    )
    let sentinel = target.appending(path: "sentinel", directoryHint: .notDirectory)
    try Data("unchanged".utf8).write(to: sentinel)
    try FileManager.default.createSymbolicLink(
      at: root,
      withDestinationURL: target
    )

    let store = KubernetesClusterDescriptorStore(rootURL: root)
    await #expect(throws: KubernetesClusterError.descriptorUnsafe) {
      try await store.save(makeDescriptor())
    }

    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "unchanged")
    let attributes = try FileManager.default.attributesOfItem(
      atPath: target.nativeContainersPOSIXPath
    )
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
  }

  @Test
  func rejectsCorruptAndOverPermissiveDescriptors() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )

    let file = root.appending(path: "Cluster.json", directoryHint: .notDirectory)
    try Data("{not-json}".utf8).write(to: file)
    #expect(Darwin.chmod(file.nativeContainersPOSIXPath, mode_t(0o600)) == 0)

    let store = KubernetesClusterDescriptorStore(rootURL: root)
    await #expect(throws: KubernetesClusterError.descriptorInvalid) {
      _ = try await store.load()
    }

    #expect(Darwin.chmod(file.nativeContainersPOSIXPath, mode_t(0o644)) == 0)
    await #expect(throws: KubernetesClusterError.descriptorUnsafe) {
      _ = try await store.load()
    }
  }

  @Test
  func rejectsDescriptorsForUnstableOrUnapprovedDistributions() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = KubernetesClusterDescriptorStore(rootURL: root)

    let unstable = KubernetesClusterDescriptor(
      operationID: UUID(),
      machine: LinuxMachineIdentity(
        id: "nativecontainers-kubernetes",
        imageReference: "alpine:3.22",
        platform: "linux/arm64",
        createdAt: nil
      ),
      distribution: .current,
      phase: .provisioning,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    await #expect(throws: KubernetesClusterError.descriptorInvalid) {
      try await store.save(unstable)
    }

    let unapproved = KubernetesClusterDescriptor(
      operationID: UUID(),
      machine: makeDescriptor().machine,
      distribution: KubernetesDistribution(
        version: "v9.9.9+k3s1",
        installScriptURL: URL(string: "https://example.com/install.sh")!,
        installScriptSHA256: String(repeating: "a", count: 64)
      ),
      phase: .provisioning,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    await #expect(throws: KubernetesClusterError.descriptorInvalid) {
      try await store.save(unapproved)
    }
  }

  private func makeDescriptor() -> KubernetesClusterDescriptor {
    let observedMachineCreationInterval = Double(bitPattern: 4_740_025_905_049_789_417)

    return KubernetesClusterDescriptor(
      operationID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      machine: LinuxMachineIdentity(
        id: "nativecontainers-kubernetes",
        imageReference: "docker.io/library/alpine:3.22",
        platform: "linux/arm64",
        createdAt: Date(timeIntervalSinceReferenceDate: observedMachineCreationInterval)
      ),
      distribution: .current,
      phase: .ready,
      createdAt: Date(timeIntervalSince1970: 1_782_099_100.123_456_7)
    )
  }

  private func temporaryRoot() -> URL {
    let parent = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainers-KubernetesStoreTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    return parent.appending(path: "Kubernetes", directoryHint: .isDirectory)
  }
}
