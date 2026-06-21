import Foundation
import Testing

@testable import NativeContainers

@Suite("Demand-started service")
struct DemandStartedServiceTests {
  @Test
  func doesNotCreateServiceUntilFirstResolve() {
    let probe = DemandStartedFactoryProbe()
    let service = DemandStartedService {
      probe.recordStart()
      return UUID()
    }

    #expect(service.hasStarted == false)
    _ = service.resolve()
    #expect(service.hasStarted)
    #expect(probe.startCount == 1)
  }

  @Test
  func concurrentResolversShareOneService() async {
    let probe = DemandStartedFactoryProbe()
    let expectedID = UUID()
    let service = DemandStartedService {
      probe.recordStart()
      return expectedID
    }

    let resolvedIDs = await withTaskGroup(
      of: UUID.self,
      returning: [UUID].self
    ) { group in
      for _ in 0..<64 {
        group.addTask {
          service.resolve()
        }
      }

      var values: [UUID] = []
      for await value in group {
        values.append(value)
      }
      return values
    }

    #expect(resolvedIDs.count == 64)
    #expect(resolvedIDs.allSatisfy { $0 == expectedID })
    #expect(probe.startCount == 1)
  }
}

private final class DemandStartedFactoryProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var starts = 0

  var startCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return starts
  }

  func recordStart() {
    lock.lock()
    starts += 1
    lock.unlock()
  }
}
