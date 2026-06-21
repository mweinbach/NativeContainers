import Darwin
import Foundation

protocol VirtualMachineBundleTransferring: Sendable {
  func copyBundle(from sourceURL: URL, to destinationURL: URL) async throws
}

struct CopyfileVirtualMachineBundleTransfer: VirtualMachineBundleTransferring {
  func copyBundle(from sourceURL: URL, to destinationURL: URL) async throws {
    let cancellation = VirtualMachineBundleCopyCancellation()
    try await withTaskCancellationHandler {
      try await Task.detached(priority: .utility) {
        try cancellation.checkCancellation()
        try Self.copyBundle(
          from: sourceURL,
          to: destinationURL,
          cancellation: cancellation
        )
        try cancellation.checkCancellation()
      }.value
    } onCancel: {
      cancellation.cancel()
    }
  }

  private static func copyBundle(
    from sourceURL: URL,
    to destinationURL: URL,
    cancellation: VirtualMachineBundleCopyCancellation
  ) throws {
    guard let state = copyfile_state_alloc() else {
      throw POSIXError(.ENOMEM)
    }
    defer { copyfile_state_free(state) }

    let callback = unsafeBitCast(
      virtualMachineBundleCopyCallback,
      to: UnsafeRawPointer.self
    )
    guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), callback) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    let context = Unmanaged.passUnretained(cancellation).toOpaque()
    guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), context) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    var forbidCrossMount = true
    guard
      withUnsafePointer(to: &forbidCrossMount, {
        copyfile_state_set(state, UInt32(COPYFILE_STATE_FORBID_CROSS_MOUNT), $0)
      }) == 0
    else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    var forbidDestinationSymlinks: UInt32 = 1
    guard
      withUnsafePointer(to: &forbidDestinationSymlinks, {
        copyfile_state_set(
          state,
          UInt32(COPYFILE_STATE_FORBID_DST_EXISTING_SYMLINKS),
          $0
        )
      }) == 0
    else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    let flags =
      copyfile_flags_t(COPYFILE_ALL)
      | copyfile_flags_t(COPYFILE_RECURSIVE)
      | copyfile_flags_t(COPYFILE_CLONE)
      | copyfile_flags_t(COPYFILE_DATA_SPARSE)
      | copyfile_flags_t(COPYFILE_NOFOLLOW)

    let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
      destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
        copyfile(sourcePath, destinationPath, state, flags)
      }
    }
    guard result == 0 else {
      if cancellation.isCancelled || errno == ECANCELED {
        throw CancellationError()
      }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}

final class VirtualMachineBundleCopyCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.withLock { cancelled }
  }

  func cancel() {
    lock.withLock {
      cancelled = true
    }
  }

  func checkCancellation() throws {
    if isCancelled {
      throw CancellationError()
    }
  }
}

let virtualMachineBundleCopyCallback: copyfile_callback_t = {
  _, _, _, _, _, context in
  guard let context else { return COPYFILE_QUIT }
  let cancellation = Unmanaged<VirtualMachineBundleCopyCancellation>
    .fromOpaque(context)
    .takeUnretainedValue()
  return cancellation.isCancelled ? COPYFILE_QUIT : COPYFILE_CONTINUE
}
