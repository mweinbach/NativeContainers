import Foundation
import Observation

@MainActor
@Observable
final class ContainerTerminalModel {
  nonisolated let output: AsyncStream<Data>

  let containerID: String
  private(set) var lifecycle: ContainerTerminalLifecycle = .closed
  private(set) var errorMessage: String?
  private(set) var terminalTitle: String?
  private(set) var currentDirectory: String?
  private(set) var displayWasTruncated = false

  private let openSession:
    @Sendable (String, ContainerTerminalRequest) async throws -> any ContainerTerminalSession
  private var outputContinuation: AsyncStream<Data>.Continuation?
  private var session: (any ContainerTerminalSession)?
  private var eventTask: Task<Void, Never>?
  private var resizeTask: Task<Void, Never>?
  private var inputPumpTask: Task<Void, Never>?
  private var pendingInput: [Data] = []
  private var activeSessionID: UUID?
  private var latestSize = ContainerTerminalSize.standard
  private var lastSentSize: ContainerTerminalSize?
  private var hasOpenedSession = false

  init(containerID: String, service: any ContainerManaging) {
    self.containerID = containerID
    self.openSession = { id, request in
      try await service.openTerminal(in: id, request: request)
    }
    let pair = AsyncStream.makeStream(
      of: Data.self,
      bufferingPolicy: .bufferingOldest(1)
    )
    output = pair.stream
    outputContinuation = pair.continuation
  }

  init(
    containerID: String,
    openSession:
      @escaping @Sendable (
        String,
        ContainerTerminalRequest
      ) async throws -> any ContainerTerminalSession
  ) {
    self.containerID = containerID
    self.openSession = openSession
    let pair = AsyncStream.makeStream(
      of: Data.self,
      bufferingPolicy: .bufferingOldest(1)
    )
    output = pair.stream
    outputContinuation = pair.continuation
  }

  var isConnecting: Bool {
    lifecycle == .starting
  }

  var isRunning: Bool {
    lifecycle == .running
  }

  var hasActiveSession: Bool {
    session != nil
  }

  var statusLabel: String {
    switch lifecycle {
    case .starting: "Connecting"
    case .running: "Connected"
    case .exited(let code): "Exited \(code)"
    case .closed: "Closed"
    case .failed: "Failed"
    }
  }

  func connect(request: ContainerTerminalRequest? = nil) async {
    guard lifecycle != .starting, lifecycle != .running else { return }
    if session != nil, !(await close()) {
      return
    }
    eventTask?.cancel()
    eventTask = nil

    lifecycle = .starting
    errorMessage = nil
    terminalTitle = nil
    currentDirectory = nil
    displayWasTruncated = false

    do {
      if hasOpenedSession {
        await receive(Data("\u{1B}c\r\n\u{1B}[90m— new shell —\u{1B}[0m\r\n".utf8))
      }
      let request = try request ?? ContainerTerminalRequest(initialSize: latestSize)
      let session = try await openSession(containerID, request)
      self.session = session
      try Task.checkCancellation()

      let sessionID = UUID()
      activeSessionID = sessionID
      lifecycle = (await session.snapshot()).lifecycle
      hasOpenedSession = true
      lastSentSize = nil
      do {
        try await session.resize(to: latestSize)
        lastSentSize = latestSize
      } catch ContainerTerminalError.sessionNotRunning {
        // A short-lived command can exit before the post-open resize retry.
      } catch {
        errorMessage = error.localizedDescription
      }
      observe(session, sessionID: sessionID)
    } catch is CancellationError {
      await session?.close()
      session = nil
      lifecycle = .closed
      errorMessage = nil
    } catch {
      lifecycle = .failed(error.localizedDescription)
      errorMessage = error.localizedDescription
    }
  }

  func sendInput(_ data: Data) async {
    guard let session else { return }
    do {
      try await session.sendInput(data)
    } catch is CancellationError {
      // Closing a terminal cancels queued input.
    } catch {
      guard !Task.isCancelled else { return }
      errorMessage = error.localizedDescription
    }
  }

  func enqueueInput(_ data: Data) {
    guard !data.isEmpty else { return }
    pendingInput.append(data)
    guard inputPumpTask == nil else { return }
    inputPumpTask = Task { [weak self] in
      await self?.drainInput()
    }
  }

  func resize(columns: Int, rows: Int) async {
    do {
      let size = try ContainerTerminalSize(columns: columns, rows: rows)
      latestSize = size
      await sendResize(size)
    } catch ContainerTerminalError.sessionNotRunning {
      // Layout can race a clean process exit; there is nothing left to resize.
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func scheduleResize(columns: Int, rows: Int) {
    do {
      let size = try ContainerTerminalSize(columns: columns, rows: rows)
      latestSize = size
      resizeTask?.cancel()
      resizeTask = Task { [weak self] in
        do {
          try await Task.sleep(for: .milliseconds(50))
          await self?.sendResize(size)
        } catch {
          // A newer geometry superseded this resize.
        }
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func sendSignal(_ signal: ContainerTerminalSignal) async {
    guard let session else { return }
    do {
      try await session.sendSignal(signal)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @discardableResult
  func close() async -> Bool {
    let session = self.session
    let inputPumpTask = self.inputPumpTask
    inputPumpTask?.cancel()
    self.inputPumpTask = nil
    pendingInput.removeAll()
    eventTask?.cancel()
    eventTask = nil
    resizeTask?.cancel()
    resizeTask = nil

    guard let session else {
      activeSessionID = nil
      lifecycle = .closed
      return true
    }

    await session.close()
    await inputPumpTask?.value
    let snapshot = await session.snapshot()
    if case .failed(let message) = snapshot.lifecycle {
      lifecycle = .failed(message)
      errorMessage = message
      return false
    }

    self.session = nil
    activeSessionID = nil
    lifecycle = .closed
    return true
  }

  func updateTerminalTitle(_ title: String) {
    terminalTitle = title.isEmpty ? nil : title
  }

  func updateCurrentDirectory(_ directory: String?) {
    currentDirectory = directory
  }

  func clearError() {
    errorMessage = nil
  }

  private func observe(
    _ session: any ContainerTerminalSession,
    sessionID: UUID
  ) {
    eventTask = Task { [weak self] in
      for await data in session.output {
        guard !Task.isCancelled else { return }
        await self?.receive(data)
      }
      guard !Task.isCancelled else { return }

      do {
        let exitCode = try await session.wait()
        guard self?.activeSessionID == sessionID else { return }
        self?.lifecycle = .exited(exitCode)
        self?.session = nil
        self?.activeSessionID = nil
        let snapshot = await session.snapshot()
        self?.displayWasTruncated =
          self?.displayWasTruncated == true || snapshot.outputWasTruncated
      } catch is CancellationError {
        // Explicit close owns the final state.
      } catch {
        guard self?.activeSessionID == sessionID else { return }
        self?.lifecycle = .failed(error.localizedDescription)
        self?.errorMessage = error.localizedDescription
      }
    }
  }

  private func receive(_ data: Data) async {
    guard !data.isEmpty else { return }
    while !Task.isCancelled {
      guard let outputContinuation else { return }
      switch outputContinuation.yield(data) {
      case .enqueued:
        return
      case .dropped:
        try? await Task.sleep(for: .milliseconds(1))
      case .terminated:
        return
      @unknown default:
        return
      }
    }
  }

  private func sendResize(_ size: ContainerTerminalSize) async {
    guard let session, lifecycle == .running, lastSentSize != size else { return }
    do {
      try await session.resize(to: size)
      lastSentSize = size
    } catch ContainerTerminalError.sessionNotRunning {
      // Layout can race a clean process exit; there is nothing left to resize.
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func drainInput() async {
    while !Task.isCancelled, !pendingInput.isEmpty {
      let data = pendingInput.removeFirst()
      await sendInput(data)
    }
    inputPumpTask = nil
  }
}
