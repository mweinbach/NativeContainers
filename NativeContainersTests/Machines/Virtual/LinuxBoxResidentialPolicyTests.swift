import Darwin
import Foundation
import Testing
@testable import NativeContainers

struct LinuxBoxResidentialPolicyTests {
  @Test
  func acceptsOnlyTheStrictResidentialCredentialDescriptor() throws {
    let fixture = try CredentialDirectoryFixture()
    defer { fixture.remove() }
    try fixture.write(
      """
      {"schema":1,"provider":"decodo","product":"residential","scheme":"socks5","host":"gate.decodo.com","port":7000,"username":"account","password":"password"}
      """
    )
    try LinuxBoxResidentialPolicy.validateCredentialFile(at: fixture.url)
  }

  @Test
  func rejectsDuplicateKeysExtraFilesLinksModesAndOversizedContent() throws {
    let duplicate = try CredentialDirectoryFixture()
    defer { duplicate.remove() }
    try duplicate.write(
      """
      {"schema":1,"schema":1,"provider":"decodo","product":"residential","scheme":"socks5","host":"gate.decodo.com","port":7000,"username":"account","password":"password"}
      """
    )
    #expect(throws: LinuxBoxResidentialPolicyError.credentialsRequired) {
      try LinuxBoxResidentialPolicy.validateCredentialFile(at: duplicate.url)
    }

    let extra = try CredentialDirectoryFixture()
    defer { extra.remove() }
    try extra.write(validCredential)
    try Data().write(to: extra.url.appending(path: "unexpected"))
    #expect(throws: LinuxBoxResidentialPolicyError.credentialsRequired) {
      try LinuxBoxResidentialPolicy.validateCredentialFile(at: extra.url)
    }

    let linked = try CredentialDirectoryFixture()
    defer { linked.remove() }
    let target = linked.url.appending(path: "target.json")
    try Data(validCredential.utf8).write(to: target)
    chmod(target.path, 0o600)
    try FileManager.default.createSymbolicLink(
      at: linked.url.appending(path: "credentials.json"),
      withDestinationURL: target
    )
    #expect(throws: LinuxBoxResidentialPolicyError.credentialsRequired) {
      try LinuxBoxResidentialPolicy.validateCredentialFile(at: linked.url)
    }

    let wrongMode = try CredentialDirectoryFixture()
    defer { wrongMode.remove() }
    try wrongMode.write(validCredential, mode: 0o644)
    #expect(throws: LinuxBoxResidentialPolicyError.credentialsRequired) {
      try LinuxBoxResidentialPolicy.validateCredentialFile(at: wrongMode.url)
    }

    let oversized = try CredentialDirectoryFixture()
    defer { oversized.remove() }
    try oversized.write(String(repeating: "x", count: 65_537))
    #expect(throws: LinuxBoxResidentialPolicyError.credentialsRequired) {
      try LinuxBoxResidentialPolicy.validateCredentialFile(at: oversized.url)
    }
  }

  @Test
  func stickyUsernameUsesLowercaseUUIDAndCloneIdentity() throws {
    let original = UUID(uuidString: "01234567-89ab-cdef-8123-456789abcdef")!
    let clone = UUID(uuidString: "11234567-89ab-cdef-8123-456789abcdef")!
    let first = try LinuxBoxResidentialPolicy.effectiveUsername(
      base: "account",
      vmID: original
    )
    let renamed = try LinuxBoxResidentialPolicy.effectiveUsername(
      base: "account",
      vmID: original
    )
    let cloned = try LinuxBoxResidentialPolicy.effectiveUsername(
      base: "account",
      vmID: clone
    )
    #expect(first == "account-session-07dd73c4a7664537-sessionduration-1440")
    #expect(renamed == first)
    #expect(cloned != first)
  }

  private var validCredential: String {
    """
    {"schema":1,"provider":"decodo","product":"residential","scheme":"socks5","host":"gate.decodo.com","port":7000,"username":"account","password":"password"}
    """
  }
}

private struct CredentialDirectoryFixture {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appending(path: "NativeContainers-Credentials-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    chmod(url.path, 0o700)
  }

  func write(_ text: String, mode: mode_t = 0o600) throws {
    let file = url.appending(path: "credentials.json")
    try Data(text.utf8).write(to: file, options: .withoutOverwriting)
    chmod(file.path, mode)
  }

  func remove() {
    try? FileManager.default.removeItem(at: url)
  }
}
