import Darwin
import Foundation

@_silgen_name("flock")
private func nativeAdvisoryFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

final class AdvisoryFileLockLease: @unchecked Sendable {
  private let stateLock = NSLock()
  private var descriptor: Int32?

  fileprivate init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  func release() {
    stateLock.withLock {
      guard let descriptor else { return }
      _ = nativeAdvisoryFlock(descriptor, LOCK_UN)
      Darwin.close(descriptor)
      self.descriptor = nil
    }
  }

  deinit {
    release()
  }
}

enum AdvisoryFileLock {
  static func acquire(at url: URL) throws -> AdvisoryFileLockLease? {
    let descriptor = Darwin.open(
      url.path,
      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
      0o600
    )
    guard descriptor >= 0 else {
      throw AdvisoryFileLockError.openFailed(url, errno)
    }

    do {
      var metadata = stat()
      guard Darwin.fstat(descriptor, &metadata) == 0 else {
        throw AdvisoryFileLockError.inspectionFailed(url, errno)
      }
      guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
        throw AdvisoryFileLockError.unsafeFile(url)
      }
      guard metadata.st_uid == geteuid() else {
        throw AdvisoryFileLockError.unsafeFile(url)
      }
      guard Darwin.fchmod(descriptor, 0o600) == 0 else {
        throw AdvisoryFileLockError.permissionUpdateFailed(url, errno)
      }

      while nativeAdvisoryFlock(descriptor, LOCK_EX | LOCK_NB) != 0 {
        let code = errno
        if code == EINTR { continue }
        if code == EWOULDBLOCK || code == EAGAIN {
          Darwin.close(descriptor)
          return nil
        }
        throw AdvisoryFileLockError.lockFailed(url, code)
      }
      return AdvisoryFileLockLease(descriptor: descriptor)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }
}

enum AdvisoryFileLockError: LocalizedError, Equatable, Sendable {
  case openFailed(URL, Int32)
  case inspectionFailed(URL, Int32)
  case unsafeFile(URL)
  case permissionUpdateFailed(URL, Int32)
  case lockFailed(URL, Int32)

  var errorDescription: String? {
    switch self {
    case .openFailed(let url, let code):
      "Could not open the operation lock at \(url.path) (errno \(code))."
    case .inspectionFailed(let url, let code):
      "Could not inspect the operation lock at \(url.path) (errno \(code))."
    case .unsafeFile(let url):
      "The operation lock at \(url.path) is not a private regular file."
    case .permissionUpdateFailed(let url, let code):
      "Could not secure the operation lock at \(url.path) (errno \(code))."
    case .lockFailed(let url, let code):
      "Could not acquire the operation lock at \(url.path) (errno \(code))."
    }
  }
}
