import ContainerizationExtras

struct RuntimeMutationCoordinator: Sendable {
  private let lock = AsyncLock()

  func perform<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await lock.withLock { _ in
      try Task.checkCancellation()
      return try await operation()
    }
  }
}
