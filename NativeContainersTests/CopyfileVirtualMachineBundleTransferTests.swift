import Darwin
import Foundation
import Testing

@testable import NativeContainers

struct CopyfileVirtualMachineBundleTransferTests {
  @Test
  func recursivelyCopiesBundleWithCloneAndSparseFallbackFlags() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "Source", directoryHint: .isDirectory)
    let destination = root.appending(path: "Destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: source.appending(path: "Nested", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
    try Data("payload".utf8).write(
      to: source.appending(path: "Nested/payload.data")
    )
    let sparse = source.appending(path: "Sparse.img")
    #expect(FileManager.default.createFile(atPath: sparse.path, contents: nil))
    let sparseHandle = try FileHandle(forWritingTo: sparse)
    try sparseHandle.truncate(atOffset: 64 * 1_024 * 1_024)
    try sparseHandle.close()

    try await CopyfileVirtualMachineBundleTransfer().copyBundle(
      from: source,
      to: destination
    )

    #expect(
      try Data(contentsOf: destination.appending(path: "Nested/payload.data"))
        == Data("payload".utf8)
    )
    let attributes = try FileManager.default.attributesOfItem(
      atPath: destination.appending(path: "Sparse.img").path
    )
    #expect((attributes[.size] as? NSNumber)?.uint64Value == 64 * 1_024 * 1_024)
  }

  @Test
  func callbackReturnsQuitAsSoonAsCancellationIsRequested() throws {
    let cancellation = VirtualMachineBundleCopyCancellation()
    let callback = try #require(virtualMachineBundleCopyCallback)
    let context = Unmanaged.passUnretained(cancellation).toOpaque()

    #expect(
      callback(
        COPYFILE_COPY_DATA,
        COPYFILE_PROGRESS,
        nil,
        nil,
        nil,
        context
      ) == COPYFILE_CONTINUE
    )

    cancellation.cancel()

    #expect(
      callback(
        COPYFILE_COPY_DATA,
        COPYFILE_PROGRESS,
        nil,
        nil,
        nil,
        context
      ) == COPYFILE_QUIT
    )
  }

  @Test
  func alreadyCancelledTransferDoesNotPublishDestination() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "Source", directoryHint: .isDirectory)
    let destination = root.appending(path: "Destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("payload".utf8).write(to: source.appending(path: "payload.data"))

    let transfer = CopyfileVirtualMachineBundleTransfer()
    let task = Task {
      await Task.yield()
      try await transfer.copyBundle(from: source, to: destination)
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  }
}
