import Foundation

@MainActor
protocol LinuxBoxAutomationRuntime: Sendable {
  func doctor() async throws -> LinuxBoxDoctorResult
  func prepareImage() async throws -> LinuxBoxImagePrepareResult
  func list() async throws -> LinuxBoxListResult
  func create(_ payload: LinuxBoxCreatePayload) async throws -> LinuxBoxChangedResult
  func status(id: UUID) async throws -> LinuxBoxSummary
  func start(id: UUID) async throws -> LinuxBoxVerifiedResult
  func pause(id: UUID) async throws -> LinuxBoxChangedResult
  func resume(id: UUID) async throws -> LinuxBoxChangedResult
  func exec(id: UUID, argv: [String], deadline: ContinuousClock.Instant) async throws -> LinuxBoxExecResult
  func verify(id: UUID) async throws -> LinuxBoxVerifiedResult
  func refresh(id: UUID) async throws -> LinuxBoxVerifiedResult
  func stop(id: UUID) async throws -> LinuxBoxChangedResult
  func destroy(id: UUID) async throws -> LinuxBoxDestroyResult
  func smoke(name: String, profile: LinuxBoxProfile) async throws -> LinuxBoxSmokeResult
}

enum NativeContainersAutomationError: Error, Equatable, Sendable {
  case control(
    NativeContainersControlErrorCode,
    String,
    LinuxBoxExecResult? = nil
  )
  case invalidRequest(String)
  case deadline
  case disconnected

  var code: NativeContainersControlErrorCode {
    switch self {
    case .control(let code, _, _): code
    case .invalidRequest: .invalidArguments
    case .deadline: .operationTimedOut
    case .disconnected: .operationTimedOut
    }
  }

  var safeMessage: String {
    switch self {
    case .control(_, let message, _), .invalidRequest(let message):
      NativeContainersControlRedactor.message(message)
    case .deadline:
      "The operation timed out."
    case .disconnected:
      "The client disconnected before the operation completed."
    }
  }

  var details: LinuxBoxExecResult? {
    guard case .control(_, _, let details) = self else { return nil }
    return details
  }
}


@MainActor
final class LinuxBoxAutomationService: @unchecked Sendable {
  private let runtime: any LinuxBoxAutomationRuntime
  private struct BusyOperation {
    let token: UUID
    let operation: NativeContainersControlOperation
    let cancel: @MainActor @Sendable () -> Void
    let waitForCompletion: @MainActor @Sendable () async -> Void
  }
  private var busyOperations: [UUID: BusyOperation] = [:]

  init(runtime: any LinuxBoxAutomationRuntime) {
    self.runtime = runtime
  }
  func create(_ payload: LinuxBoxCreatePayload) async throws -> LinuxBoxChangedResult {
    do {
      return try await runtime.create(payload)
    } catch let error as NativeContainersAutomationError {
      throw error
    } catch is CancellationError {
      throw NativeContainersAutomationError.disconnected
    } catch {
      throw NativeContainersAutomationError.control(.internalError, error.localizedDescription)
    }
  }


  func execute(_ request: NativeContainersControlRequest) async throws -> Data {
    do {
      switch request.operation {
      case .doctor:
        return try response(request, data: await runtime.doctor())
      case .imagePrepare:
        return try response(request, data: await runtime.prepareImage())
      case .list:
        return try response(request, data: await runtime.list())
      case .create:
        guard case .create(let payload) = request.payload else { throw invalidPayload() }
        return try response(request, data: try await withDeadline(request) { try await self.create(payload) })
      case .status:
        return try response(request, data: try await runtime.status(id: try id(from: request)))
      case .start:
        return try response(
          request,
          data: try await withID(request) { try await self.runtime.start(id: $0) }
        )
      case .pause:
        return try response(
          request,
          data: try await withID(request) { try await self.runtime.pause(id: $0) }
        )
      case .resume:
        return try response(
          request,
          data: try await withID(request) { try await self.runtime.resume(id: $0) }
        )
      case .exec:
        guard case .exec(let payload) = request.payload else { throw invalidPayload() }
        return try response(
          request,
          data: try await withID(
            payload.id.value,
            operation: .exec
          ) { id in
            try await self.withDeadline(request) {
              try await self.runtime.exec(
                id: id,
                argv: payload.argv,
                deadline: ContinuousClock.now.advanced(by: .seconds(request.timeoutSeconds))
              )
            }
          }
        )
      case .verify:
        return try response(
          request,
          data: try await withID(request) { try await self.runtime.verify(id: $0) }
        )
      case .refresh:
        return try response(
          request,
          data: try await withID(request) { try await self.runtime.refresh(id: $0) }
        )
      case .stop:
        return try response(
          request,
          data: try await withID(request, preemptingExec: true) {
            try await self.runtime.stop(id: $0)
          }
        )
      case .destroy:
        return try response(
          request,
          data: try await withID(request, preemptingExec: true) {
            try await self.runtime.destroy(id: $0)
          }
        )
      case .smoke:
        guard case .smoke(let payload) = request.payload else { throw invalidPayload() }
        return try response(
          request,
          data: try await withDeadline(request) {
            try await self.runtime.smoke(name: payload.name, profile: payload.profile)
          }
        )
      }
    } catch let error as NativeContainersAutomationError {
      throw error
    } catch is CancellationError {
      throw NativeContainersAutomationError.disconnected
    } catch {
      throw NativeContainersAutomationError.control(.internalError, error.localizedDescription)
    }
  }

  private func invalidPayload() -> NativeContainersAutomationError {
    .invalidRequest("The request payload does not match its operation.")
  }

  private func response<Value: Codable & Equatable & Sendable>(
    _ request: NativeContainersControlRequest,
    data: Value
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = []
    return try encoder.encode(NativeContainersControlResponse(requestID: request.requestID.value, data: data))
  }

  private func id(from request: NativeContainersControlRequest) throws -> UUID {
    guard case .id(let payload) = request.payload else { throw invalidPayload() }
    return payload.id.value
  }

  private func withID<Value: Codable & Equatable & Sendable>(
    _ request: NativeContainersControlRequest,
    preemptingExec: Bool = false,
    operation: @escaping @MainActor @Sendable (UUID) async throws -> Value
  ) async throws -> Value {
    try await withID(
      id(from: request),
      operation: request.operation,
      preemptingExec: preemptingExec,
      body: operation
    )
  }

  private func withID<Value: Codable & Equatable & Sendable>(
    _ id: UUID,
    operation: NativeContainersControlOperation,
    preemptingExec: Bool = false,
    body: @escaping @MainActor @Sendable (UUID) async throws -> Value
  ) async throws -> Value {
    if let busy = busyOperations[id] {
      guard preemptingExec, busy.operation == .exec else {
        throw busyError()
      }
      busy.cancel()
      await busy.waitForCompletion()
      guard busyOperations[id] == nil else {
        throw busyError()
      }
    }

    let token = UUID()
    let task = Task { @MainActor [weak self] in
      defer { self?.finishOperation(id: id, token: token) }
      try Task.checkCancellation()
      return try await body(id)
    }
    busyOperations[id] = BusyOperation(
      token: token,
      operation: operation,
      cancel: { task.cancel() },
      waitForCompletion: { _ = await task.result }
    )
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func finishOperation(id: UUID, token: UUID) {
    if busyOperations[id]?.token == token {
      busyOperations[id] = nil
    }
  }

  private func busyError() -> NativeContainersAutomationError {
    .control(
      .busy,
      "The virtual machine is already handling another operation."
    )
  }

  private func withDeadline<Value: Sendable>(
    _ request: NativeContainersControlRequest,
    operation: @escaping @MainActor @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(for: .seconds(request.timeoutSeconds))
        throw NativeContainersAutomationError.deadline
      }
      guard let result = try await group.next() else { throw NativeContainersAutomationError.deadline }
      group.cancelAll()
      return result
    }
  }
}
