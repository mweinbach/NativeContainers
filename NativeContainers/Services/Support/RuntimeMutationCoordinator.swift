import Foundation

struct RuntimeMutationCoordinator: Sendable {
  static let shared = RuntimeMutationCoordinator()
  static let imageBuilds = RuntimeMutationCoordinator()

  private let lock = CancellationAwareFIFOAsyncLock()

  func perform<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let lease = try await lock.acquire()
    do {
      try Task.checkCancellation()
      let result = try await operation()
      await lock.release(lease)
      return result
    } catch {
      await lock.release(lease)
      throw error
    }
  }
}

private actor CancellationAwareFIFOAsyncLock {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<UUID, any Error>
  }

  private var holder: UUID?
  private var waiters: [Waiter] = []

  func acquire() async throws -> UUID {
    try Task.checkCancellation()
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if holder == nil {
          holder = id
          continuation.resume(returning: id)
        } else {
          waiters.append(Waiter(id: id, continuation: continuation))
        }
      }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
  }

  func release(_ id: UUID) {
    guard holder == id else { return }
    guard !waiters.isEmpty else {
      holder = nil
      return
    }
    let next = waiters.removeFirst()
    holder = next.id
    next.continuation.resume(returning: next.id)
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(throwing: CancellationError())
  }
}
