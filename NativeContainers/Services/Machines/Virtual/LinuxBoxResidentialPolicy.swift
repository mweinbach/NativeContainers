import CryptoKit
import Darwin
import Foundation

struct LinuxBoxResidentialPreflightResult: Sendable {
  let configuration: LinuxBoxGuestResidentialConfiguration
  let hostDirectIP: String
  let hostProxyIP: String
  let isp: String
  let country: String
}

enum LinuxBoxResidentialPolicyError: LocalizedError, Equatable, Sendable {
  case credentialsRequired
  case proxyUnreachable
  case proxiedDNSUnavailable
  case directIdentityUnavailable
  case cancelled
  case operationTimedOut

  var errorDescription: String? {
    switch self {
    case .credentialsRequired:
      "Valid Decodo residential SOCKS5 credentials are required."
    case .proxyUnreachable:
      "The Decodo residential SOCKS5 gateway is unreachable."
    case .proxiedDNSUnavailable:
      "No pinned DNS-over-HTTPS endpoint passed through the residential gateway."
    case .directIdentityUnavailable:
      "The host direct IPv4 identity is unavailable."
    case .cancelled:
      "Residential proxy preflight was cancelled."
    case .operationTimedOut:
      "Residential proxy preflight exceeded its deadline."
    }
  }
}

struct LinuxBoxResidentialPolicy: Sendable {
  private struct Credentials: Sendable {
    let username: String
    let password: String
  }

  private struct Identity: Equatable, Sendable {
    let ip: String
    let isp: String
    let country: String
  }

  private struct DoH: Sendable {
    let address: String
    let serverName: String
  }

  private let credentialDirectoryURL: URL

  init(
    credentialDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/decodo/residential", directoryHint: .isDirectory)
  ) {
    self.credentialDirectoryURL = credentialDirectoryURL
  }

  static func validateCredentialFile(
    at directoryURL: URL
  ) throws {
    _ = try readCredentials(from: directoryURL)
  }

  func prepare(
    vmID: UUID,
    timeoutSeconds: Int
  ) async throws -> LinuxBoxResidentialPreflightResult {
    guard (5...3_600).contains(timeoutSeconds) else {
      throw LinuxBoxResidentialPolicyError.proxyUnreachable
    }
    let credentials = try Self.readCredentials(from: credentialDirectoryURL)
    let effectiveUsername = try Self.effectiveUsername(
      base: credentials.username,
      vmID: vmID
    )
    guard let allowed = Self.resolveGateways(), !allowed.isEmpty else {
      throw LinuxBoxResidentialPolicyError.proxyUnreachable
    }
    let runner = LinuxBoxCurlRunner()
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
    return try await withTaskCancellationHandler {
      let directTimeout = try Self.remainingSeconds(
        until: deadline,
        clock: clock
      )
      guard let direct = try await Self.directHostIP(
        runner: runner,
        timeoutSeconds: directTimeout
      ) else {
        throw LinuxBoxResidentialPolicyError.directIdentityUnavailable
      }

      var authenticated = false
      for gateway in allowed {
        try Task.checkCancellation()
        let identityTimeout = try Self.remainingSeconds(
          until: deadline,
          clock: clock
        )
        guard let identity = try await Self.proxyIdentity(
          gateway: gateway,
          username: effectiveUsername,
          password: credentials.password,
          runner: runner,
          timeoutSeconds: identityTimeout
        ), identity.ip != direct
        else { continue }
        authenticated = true
        guard let doh = try await Self.probeDoH(
          gateway: gateway,
          username: effectiveUsername,
          password: credentials.password,
          runner: runner,
          deadline: deadline,
          clock: clock
        ) else { continue }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let configuration = LinuxBoxGuestResidentialConfiguration(
          schema: 1,
          credentials: LinuxBoxGuestResidentialCredentials(
            schema: 1,
            provider: "decodo",
            product: "residential",
            scheme: "socks5",
            host: "gate.decodo.com",
            port: 7_000,
            username: effectiveUsername,
            password: credentials.password
          ),
          endpoints: LinuxBoxGuestResidentialEndpoints(
            schema: 1,
            host: "gate.decodo.com",
            port: 7_000,
            selected: gateway,
            allowed: allowed,
            doh: LinuxBoxGuestDoHEndpoint(
              address: doh.address,
              port: 443,
              serverName: doh.serverName,
              path: "/dns-query"
            ),
            resolvedAt: timestamp
          )
        )
        return LinuxBoxResidentialPreflightResult(
          configuration: configuration,
          hostDirectIP: direct,
          hostProxyIP: identity.ip,
          isp: identity.isp,
          country: identity.country
        )
      }
      throw authenticated
        ? LinuxBoxResidentialPolicyError.proxiedDNSUnavailable
        : LinuxBoxResidentialPolicyError.proxyUnreachable
    } onCancel: {
      runner.cancel()
    }
  }

  private static func readCredentials(from directoryURL: URL) throws -> Credentials {
    let directory = open(
      directoryURL.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard directory >= 0 else {
      throw LinuxBoxResidentialPolicyError.credentialsRequired
    }
    defer { Darwin.close(directory) }

    var metadata = stat()
    guard fstat(directory, &metadata) == 0,
      metadata.st_uid == getuid(),
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_mode & 0o7777 == 0o700,
      try directoryEntries(directory) == ["credentials.json"]
    else {
      throw LinuxBoxResidentialPolicyError.credentialsRequired
    }

    let descriptor = openat(
      directory,
      "credentials.json",
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw LinuxBoxResidentialPolicyError.credentialsRequired
    }
    defer { Darwin.close(descriptor) }

    var fileMetadata = stat()
    guard fstat(descriptor, &fileMetadata) == 0,
      fileMetadata.st_mode & S_IFMT == S_IFREG,
      fileMetadata.st_uid == getuid(),
      fileMetadata.st_mode & 0o7777 == 0o600,
      fileMetadata.st_nlink == 1,
      fileMetadata.st_size >= 0,
      fileMetadata.st_size <= 65_536
    else {
      throw LinuxBoxResidentialPolicyError.credentialsRequired
    }

    var content = Data()
    content.reserveCapacity(Int(fileMetadata.st_size))
    var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
    while content.count <= 65_536 {
      let count = Darwin.read(descriptor, &buffer, min(buffer.count, 65_537 - content.count))
      if count < 0 {
        if errno == EINTR { continue }
        throw LinuxBoxResidentialPolicyError.credentialsRequired
      }
      if count == 0 { break }
      content.append(buffer, count: count)
    }
    guard content.count <= 65_536 else {
      throw LinuxBoxResidentialPolicyError.credentialsRequired
    }

    do {
      let root = try StrictJSONDocument.parse(content)
      let object = try root.object(
        exactKeys: [
          "schema", "provider", "product", "scheme", "host", "port", "username",
          "password",
        ]
      )
      guard object["schema"]?.integer(as: Int.self) == 1,
        object["provider"]?.string == "decodo",
        object["product"]?.string == "residential",
        object["scheme"]?.string == "socks5",
        object["host"]?.string == "gate.decodo.com",
        object["port"]?.integer(as: Int.self) == 7_000,
        let username = object["username"]?.string,
        let password = object["password"]?.string,
        (1...4_050).contains(username.utf8.count),
        (1...4_096).contains(password.utf8.count),
        username.utf8.allSatisfy({ (0x21...0x7e).contains($0) }),
        password.utf8.allSatisfy({ (0x21...0x7e).contains($0) }),
        !username.contains(":"),
        !username.contains("-session-"),
        !username.contains("-sessionduration-")
      else {
        throw LinuxBoxResidentialPolicyError.credentialsRequired
      }
      return Credentials(username: username, password: password)
    } catch {
      throw LinuxBoxResidentialPolicyError.credentialsRequired
    }
  }

  private static func directoryEntries(_ descriptor: Int32) throws -> [String] {
    let duplicate = dup(descriptor)
    guard duplicate >= 0, let directory = fdopendir(duplicate) else {
      if duplicate >= 0 { Darwin.close(duplicate) }
      throw LinuxBoxResidentialPolicyError.credentialsRequired
    }
    defer { closedir(directory) }
    var names: [String] = []
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(cString: $0)
        }
      }
      if name != "." && name != ".." { names.append(name) }
    }
    return names.sorted()
  }

  static func effectiveUsername(base: String, vmID: UUID) throws -> String {
    let input = Data(vmID.uuidString.lowercased().utf8)
    let digest = SHA256.hash(data: input)
    let session = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    let value = "\(base)-session-\(session)-sessionduration-1440"
    guard (47...4_096).contains(value.utf8.count) else {
      throw LinuxBoxResidentialPolicyError.credentialsRequired
    }
    return value
  }

  private static func resolveGateways() -> [String]? {
    var hints = addrinfo(
      ai_flags: AI_ADDRCONFIG,
      ai_family: AF_INET,
      ai_socktype: SOCK_STREAM,
      ai_protocol: IPPROTO_TCP,
      ai_addrlen: 0,
      ai_canonname: nil,
      ai_addr: nil,
      ai_next: nil
    )
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo("gate.decodo.com", "7000", &hints, &result) == 0,
      let first = result
    else { return nil }
    defer { freeaddrinfo(first) }

    var addresses = Set<UInt32>()
    var cursor: UnsafeMutablePointer<addrinfo>? = first
    while let current = cursor {
      cursor = current.pointee.ai_next
      guard current.pointee.ai_family == AF_INET,
        current.pointee.ai_addrlen >= socklen_t(MemoryLayout<sockaddr_in>.size),
        let addressPointer = current.pointee.ai_addr
      else { continue }
      let socketAddress = UnsafeRawPointer(addressPointer)
        .assumingMemoryBound(to: sockaddr_in.self).pointee
      let value = UInt32(bigEndian: socketAddress.sin_addr.s_addr)
      guard isGlobalIPv4(value) else { continue }
      addresses.insert(value)
    }
    return addresses.sorted().compactMap(ipv4String)
  }

  private static func directHostIP(
    runner: LinuxBoxCurlRunner,
    timeoutSeconds: Int
  ) async throws -> String? {
    let output = try await runner.run(
      configuration: curlConfiguration(
        lines: [
          "ipv4",
          configLine("url", "https://api.ipify.org"),
        ],
        timeoutSeconds: timeoutSeconds
      ),
      timeoutSeconds: timeoutSeconds
    )
    guard output.exitCode == 0,
      let body = httpBody(output.stdout),
      let address = canonicalGlobalIPv4(
        String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      )
    else { return nil }
    return address
  }

  private static func proxyIdentity(
    gateway: String,
    username: String,
    password: String,
    runner: LinuxBoxCurlRunner,
    timeoutSeconds: Int
  ) async throws -> Identity? {
    let output = try await runner.run(
      configuration: curlConfiguration(
        lines: [
          configLine("proxy", "socks5h://\(gateway):7000"),
          configLine("proxy-user", "\(username):\(password)"),
          configLine("url", "https://ip.decodo.com/json"),
        ],
        timeoutSeconds: timeoutSeconds
      ),
      timeoutSeconds: timeoutSeconds
    )
    guard output.exitCode == 0, let body = httpBody(output.stdout) else { return nil }
    return identity(body)
  }

  private static func probeDoH(
    gateway: String,
    username: String,
    password: String,
    runner: LinuxBoxCurlRunner,
    deadline: ContinuousClock.Instant,
    clock: ContinuousClock
  ) async throws -> DoH? {
    for candidate in [
      DoH(address: "1.1.1.1", serverName: "cloudflare-dns.com"),
      DoH(address: "8.8.8.8", serverName: "dns.google"),
    ] {
      let timeoutSeconds = try remainingSeconds(until: deadline, clock: clock)
      let output = try await runner.run(
        configuration: curlConfiguration(
          lines: [
            configLine("proxy", "socks5://\(gateway):7000"),
            configLine("proxy-user", "\(username):\(password)"),
            configLine("resolve", "\(candidate.serverName):443:\(candidate.address)"),
            configLine("header", "Accept: application/dns-json"),
            configLine(
              "url",
              "https://\(candidate.serverName)/dns-query?name=example.com&type=A"
            ),
          ],
          timeoutSeconds: timeoutSeconds
        ),
        timeoutSeconds: timeoutSeconds
      )
      if output.exitCode == 0,
        let body = httpBody(output.stdout),
        validDNSResponse(body)
      {
        return candidate
      }
    }
    return nil
  }

  private static func remainingSeconds(
    until deadline: ContinuousClock.Instant,
    clock: ContinuousClock
  ) throws -> Int {
    let remaining = clock.now.duration(to: deadline)
    guard remaining > .zero else {
      throw LinuxBoxResidentialPolicyError.operationTimedOut
    }
    let components = remaining.components
    let rounded = components.seconds + (components.attoseconds > 0 ? 1 : 0)
    guard rounded > 0 else {
      throw LinuxBoxResidentialPolicyError.operationTimedOut
    }
    return min(30, Int(rounded))
  }

  private static func curlConfiguration(
    lines: [String],
    timeoutSeconds: Int
  ) -> Data {
    let bounded = max(1, min(timeoutSeconds, 30))
    let text = ([
      "silent",
      "fail",
      "proto = \"=https\"",
      "connect-timeout = \(min(10, bounded))",
      "max-time = \(bounded)",
      "write-out = \"\\n%{http_code}\"",
    ] + lines + [""]).joined(separator: "\n")
    return Data(text.utf8)
  }

  private static func configLine(_ name: String, _ value: String) -> String {
    precondition(!value.contains("\0") && !value.contains("\r") && !value.contains("\n"))
    let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\(name) = \"\(escaped)\""
  }

  private static func httpBody(_ data: Data) -> Data? {
    guard data.count <= 65_536,
      let marker = data.lastRange(of: Data("\n200".utf8)),
      marker.upperBound == data.endIndex
    else { return nil }
    return data[..<marker.lowerBound]
  }

  private static func identity(_ data: Data) -> Identity? {
    guard let root = try? StrictJSONDocument.parse(data),
      case .object(let object) = root,
      case .object(let proxy)? = object["proxy"],
      case .object(let isp)? = object["isp"],
      case .object(let country)? = object["country"],
      let rawIP = proxy["ip"]?.string,
      let ip = canonicalGlobalIPv4(rawIP),
      let ispName = isp["isp"]?.string,
      !ispName.isEmpty,
      let countryName = country["name"]?.string,
      !countryName.isEmpty
    else { return nil }
    return Identity(ip: ip, isp: ispName, country: countryName)
  }

  private static func validDNSResponse(_ data: Data) -> Bool {
    guard let root = try? StrictJSONDocument.parse(data),
      case .object(let object) = root,
      object["Status"]?.integer(as: Int.self) == 0,
      let answers = object["Answer"]?.array
    else { return false }
    return answers.contains { answer in
      guard case .object(let item) = answer,
        item["type"]?.integer(as: Int.self) == 1,
        let value = item["data"]?.string
      else { return false }
      return canonicalGlobalIPv4(value) != nil
    }
  }

  private static func canonicalGlobalIPv4(_ value: String) -> String? {
    var address = in_addr()
    guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
      return nil
    }
    let integer = UInt32(bigEndian: address.s_addr)
    guard isGlobalIPv4(integer), ipv4String(integer) == value else { return nil }
    return value
  }

  private static func ipv4String(_ value: UInt32) -> String? {
    var address = in_addr(s_addr: value.bigEndian)
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
      return nil
    }
    return buffer.withUnsafeBytes { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: UInt8.self)
      let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
      return String(decoding: bytes[..<end], as: UTF8.self)
    }
  }

  private static func isGlobalIPv4(_ value: UInt32) -> Bool {
    let denied: [(UInt32, UInt32)] = [
      (0x0000_0000, 0xff00_0000), (0x0a00_0000, 0xff00_0000),
      (0x6440_0000, 0xffc0_0000), (0x7f00_0000, 0xff00_0000),
      (0xa9fe_0000, 0xffff_0000), (0xac10_0000, 0xfff0_0000),
      (0xc000_0000, 0xffff_ff00), (0xc000_0200, 0xffff_ff00),
      (0xc058_6300, 0xffff_ff00), (0xc0a8_0000, 0xffff_0000),
      (0xc612_0000, 0xfffe_0000), (0xc633_6400, 0xffff_ff00),
      (0xcb00_7100, 0xffff_ff00), (0xe000_0000, 0xf000_0000),
      (0xf000_0000, 0xf000_0000),
    ]
    return !denied.contains { value & $0.1 == $0.0 }
  }
}

private final class LinuxBoxBoundedOutputCapture: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private var data = Data()
  private var exceeded = false

  init(limit: Int) {
    self.limit = limit
  }

  func append(_ chunk: Data) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !exceeded else { return true }
    guard data.count + chunk.count <= limit else {
      exceeded = true
      return true
    }
    data.append(chunk)
    return false
  }

  func snapshot() -> (data: Data, exceeded: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (data, exceeded)
  }
}

private final class LinuxBoxCurlRunner: @unchecked Sendable {
  struct Output: Sendable {
    let exitCode: Int32
    let stdout: Data
  }

  private let lock = NSLock()
  private var current: Process?
  private var cancelled = false

  func run(
    configuration: Data,
    timeoutSeconds: Int
  ) async throws -> Output {
    try await withTaskCancellationHandler {
      try await Task.detached(priority: .userInitiated) {
        try self.runSynchronously(
          configuration: configuration,
          timeoutSeconds: timeoutSeconds
        )
      }.value
    } onCancel: {
      self.cancel()
    }
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let process = current
    lock.unlock()
    if let process, process.isRunning { process.terminate() }
  }

  private func runSynchronously(
    configuration: Data,
    timeoutSeconds: Int
  ) throws -> Output {
    lock.lock()
    guard !cancelled, current == nil else {
      lock.unlock()
      throw LinuxBoxResidentialPolicyError.cancelled
    }
    lock.unlock()

    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/curl")
    process.arguments = ["-q", "--config", "-"]
    process.environment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "LANG": "C",
      "HOME": "/var/empty",
    ]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    let terminated = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in terminated.signal() }
    do {
      try process.run()
    } catch {
      throw LinuxBoxResidentialPolicyError.proxyUnreachable
    }
    lock.lock()
    current = process
    let shouldCancel = cancelled
    lock.unlock()
    if shouldCancel { process.terminate() }

    let capture = LinuxBoxBoundedOutputCapture(limit: 65_536)
    let drained = DispatchGroup()
    drained.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer { drained.leave() }
      while true {
        let chunk = output.fileHandleForReading.readData(ofLength: 16 * 1_024)
        if chunk.isEmpty { return }
        if capture.append(chunk) {
          process.terminate()
        }
      }
    }

    do {
      try input.fileHandleForWriting.write(contentsOf: configuration)
      try input.fileHandleForWriting.close()
    } catch {
      process.terminate()
    }

    let result = terminated.wait(timeout: .now() + .seconds(timeoutSeconds))
    if result == .timedOut {
      process.terminate()
      if terminated.wait(timeout: .now() + .seconds(2)) == .timedOut {
        Darwin.kill(process.processIdentifier, SIGKILL)
        _ = terminated.wait(timeout: .now() + .seconds(2))
      }
    }
    try? output.fileHandleForReading.close()
    drained.wait()
    lock.lock()
    current = nil
    let wasCancelled = cancelled
    lock.unlock()

    if wasCancelled { throw LinuxBoxResidentialPolicyError.cancelled }
    let captureSnapshot = capture.snapshot()
    if result == .timedOut || captureSnapshot.exceeded {
      throw LinuxBoxResidentialPolicyError.proxyUnreachable
    }
    return Output(exitCode: process.terminationStatus, stdout: captureSnapshot.data)
  }
}
