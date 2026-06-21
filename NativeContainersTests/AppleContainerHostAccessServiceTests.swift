import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite("Apple host access service")
struct AppleContainerHostAccessServiceTests {
  @Test
  func discoversOnlyCompleteOnDiskHostRedirects() throws {
    let fixture = try HostAccessFixture()
    defer { fixture.remove() }
    try fixture.writeCompleteConfiguration()

    let catalog = fixture.service.loadCatalog()

    #expect(
      catalog.configurations == [
        try ContainerHostAccessConfiguration(
          domain: "host.container.internal",
          redirectIPv4Address: "203.0.113.113"
        )
      ]
    )
    #expect(catalog.warnings.isEmpty)
  }

  @Test
  func rejectsResolverOnlyAndOrdinaryContainerDNSDomains() throws {
    let fixture = try HostAccessFixture()
    defer { fixture.remove() }
    try fixture.writeResolver(port: "1053")
    try fixture.writePacketFilterConfiguration()
    try fixture.writePacketFilterAnchor("")

    var catalog = fixture.service.loadCatalog()
    #expect(catalog.configurations.isEmpty)
    #expect(catalog.warnings.contains { $0.contains("no matching packet-filter rule") })

    try fixture.writeResolver(port: "2053")
    catalog = fixture.service.loadCatalog()
    #expect(catalog.configurations.isEmpty)
    #expect(catalog.warnings.contains { $0.contains("exact localhost redirect") })
  }

  @Test
  func rejectsUnsafeOrSymlinkedResolverFiles() throws {
    let fixture = try HostAccessFixture()
    defer { fixture.remove() }
    try fixture.writeCompleteConfiguration()

    let resolver = fixture.resolverFileURL
    try FileManager.default.removeItem(at: resolver)
    try FileManager.default.createSymbolicLink(
      at: resolver,
      withDestinationURL: fixture.packetFilterAnchorURL
    )

    let catalog = fixture.service.loadCatalog()

    #expect(catalog.configurations.isEmpty)
    #expect(catalog.warnings.contains { $0.contains("secure regular system file") })
  }

  @Test
  func revalidationFailsClosedAfterConfigurationChanges() throws {
    let fixture = try HostAccessFixture()
    defer { fixture.remove() }
    try fixture.writeCompleteConfiguration()
    let configuration = try #require(fixture.service.loadCatalog().configurations.first)

    try fixture.writePacketFilterAnchor("")

    #expect(throws: ContainerAttachmentValidationError.unavailableHostAccess) {
      try fixture.service.validate(configuration)
    }
  }
}

private struct HostAccessFixture {
  let rootURL: URL
  let resolverDirectoryURL: URL
  let resolverFileURL: URL
  let packetFilterConfigurationURL: URL
  let packetFilterAnchorURL: URL
  let service: AppleContainerHostAccessService

  init() throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "NativeContainersHostAccess-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let resolverDirectoryURL = rootURL.appending(
      path: "resolver",
      directoryHint: .isDirectory
    )
    let packetFilterConfigurationURL = rootURL.appending(
      path: "pf.conf",
      directoryHint: .notDirectory
    )
    let packetFilterAnchorURL = rootURL.appending(
      path: "com.apple.container",
      directoryHint: .notDirectory
    )
    try FileManager.default.createDirectory(
      at: resolverDirectoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755]
    )
    guard chmod(resolverDirectoryURL.path(), 0o755) == 0 else {
      throw CocoaError(.fileWriteNoPermission)
    }

    self.rootURL = rootURL
    self.resolverDirectoryURL = resolverDirectoryURL
    self.resolverFileURL = resolverDirectoryURL.appending(
      path: "containerization.host.container.internal",
      directoryHint: .notDirectory
    )
    self.packetFilterConfigurationURL = packetFilterConfigurationURL
    self.packetFilterAnchorURL = packetFilterAnchorURL
    self.service = AppleContainerHostAccessService(
      resolverDirectoryURL: resolverDirectoryURL,
      packetFilterConfigurationURL: packetFilterConfigurationURL,
      packetFilterAnchorURL: packetFilterAnchorURL,
      expectedOwnerUID: getuid()
    )
  }

  func writeCompleteConfiguration() throws {
    try writeResolver(port: "1053")
    try writePacketFilterConfiguration()
    try writePacketFilterAnchor(
      "rdr inet from any to 203.0.113.113 -> 127.0.0.1 # host.container.internal\n"
    )
  }

  func writeResolver(port: String) throws {
    try write(
      """
      domain host.container.internal
      search host.container.internal
      nameserver 127.0.0.1
      port \(port)
      options localhost:203.0.113.113

      """,
      to: resolverFileURL
    )
  }

  func writePacketFilterConfiguration() throws {
    try write(
      """
      rdr-anchor "com.apple.container"
      load anchor "com.apple.container" from "\(packetFilterAnchorURL.path())"

      """,
      to: packetFilterConfigurationURL
    )
  }

  func writePacketFilterAnchor(_ contents: String) throws {
    try write(contents, to: packetFilterAnchorURL)
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }

  private func write(_ contents: String, to url: URL) throws {
    try contents.write(to: url, atomically: true, encoding: .utf8)
    guard chmod(url.path(), 0o644) == 0 else {
      throw CocoaError(.fileWriteNoPermission)
    }
  }
}
