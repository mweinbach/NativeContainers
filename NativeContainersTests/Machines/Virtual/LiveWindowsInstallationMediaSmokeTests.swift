import CryptoKit
import Foundation
import Testing

@testable import NativeContainers

private let suppliedWindowsISO = FileManager.default.homeDirectoryForCurrentUser
  .appending(path: "Downloads/Win11_25H2_English_Arm64_v2.iso")

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
