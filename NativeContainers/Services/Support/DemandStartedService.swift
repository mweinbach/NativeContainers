import Foundation

/// Owns a service graph that should not be allocated until one of its facades is used.
///
/// The factory runs once while the lock is held. Factories must not recursively resolve
/// the same holder.
final class DemandStartedService<Service: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var service: Service?
  private var factory: (@Sendable () -> Service)?

  init(factory: @escaping @Sendable () -> Service) {
    self.factory = factory
  }

  var hasStarted: Bool {
    lock.lock()
    defer { lock.unlock() }
    return service != nil
  }

  func resolve() -> Service {
    lock.lock()
    defer { lock.unlock() }

    if let service {
      return service
    }

    guard let factory else {
      preconditionFailure("Demand-started service factory was released before initialization.")
    }

    let service = factory()
    self.service = service
    self.factory = nil
    return service
  }
}
