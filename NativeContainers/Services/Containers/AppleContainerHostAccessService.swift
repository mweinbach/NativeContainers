import Darwin
import Foundation

struct AppleContainerHostAccessService: Sendable {
  private static let resolverPrefix = "containerization."
  private static let maximumConfigurationBytes: Int64 = 64 * 1_024

  private let resolverDirectoryURL: URL
  private let packetFilterConfigurationURL: URL
  private let packetFilterAnchorURL: URL
  private let expectedOwnerUID: uid_t

  init(
    resolverDirectoryURL: URL = URL(
      filePath: "/etc/resolver",
      directoryHint: .isDirectory
    ),
    packetFilterConfigurationURL: URL = URL(
      filePath: "/etc/pf.conf",
      directoryHint: .notDirectory
    ),
    packetFilterAnchorURL: URL = URL(
      filePath: "/etc/pf.anchors/com.apple.container",
      directoryHint: .notDirectory
    ),
    expectedOwnerUID: uid_t = 0
  ) {
    self.resolverDirectoryURL = resolverDirectoryURL
    self.packetFilterConfigurationURL = packetFilterConfigurationURL
    self.packetFilterAnchorURL = packetFilterAnchorURL
    self.expectedOwnerUID = expectedOwnerUID
  }

  func loadCatalog() -> ContainerHostAccessCatalog {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: resolverDirectoryURL.path(percentEncoded: false)) else {
      return .empty
    }

    do {
      try requireSecureDirectory(resolverDirectoryURL)
    } catch {
      return ContainerHostAccessCatalog(
        configurations: [],
        warnings: ["The resolver directory is unsafe: \(error.localizedDescription)"]
      )
    }

    let resolverFilenames: [String]
    do {
      resolverFilenames =
        try fileManager.contentsOfDirectory(
          atPath: resolverDirectoryURL.path(percentEncoded: false)
        )
        .filter { $0.hasPrefix(Self.resolverPrefix) }
        .sorted()
    } catch {
      return ContainerHostAccessCatalog(
        configurations: [],
        warnings: ["The resolver directory could not be read."]
      )
    }
    guard !resolverFilenames.isEmpty else { return .empty }

    let packetFilterConfiguration: String
    let packetFilterAnchor: String
    do {
      packetFilterConfiguration = try readSecureFile(packetFilterConfigurationURL)
      packetFilterAnchor = try readSecureFile(packetFilterAnchorURL)
    } catch {
      return ContainerHostAccessCatalog(
        configurations: [],
        warnings: resolverFilenames.map {
          "\($0): packet-filter configuration is missing or unsafe."
        }
      )
    }

    let requiredLoadDirective =
      #"load anchor "com.apple.container" from "\#(packetFilterAnchorURL.path(percentEncoded: false))""#
    guard
      packetFilterConfiguration.components(separatedBy: .newlines).contains(
        requiredLoadDirective
      )
    else {
      return ContainerHostAccessCatalog(
        configurations: [],
        warnings: resolverFilenames.map {
          "\($0): /etc/pf.conf does not load Apple’s container anchor."
        }
      )
    }

    var configurations: [ContainerHostAccessConfiguration] = []
    var warnings: [String] = []
    for filename in resolverFilenames.prefix(256) {
      let suffix = String(filename.dropFirst(Self.resolverPrefix.count))
      let fileURL = resolverDirectoryURL.appending(
        path: filename,
        directoryHint: .notDirectory
      )
      do {
        let configuration = try parseResolver(
          try readSecureFile(fileURL),
          expectedDomain: suffix
        )
        guard
          packetFilterAnchor.components(separatedBy: .newlines).contains(
            redirectRule(for: configuration)
          )
        else {
          warnings.append(
            "\(configuration.domain) is configured in DNS but has no matching packet-filter rule."
          )
          continue
        }
        configurations.append(configuration)
      } catch {
        warnings.append("\(filename): \(error.localizedDescription)")
      }
    }

    let configuredDomains = Set(configurations.map(\.domain))
    for rule in packetFilterAnchor.components(separatedBy: .newlines)
    where rule.hasPrefix("rdr inet ") {
      guard let marker = rule.range(of: " # ") else { continue }
      let domain = String(rule[marker.upperBound...]).lowercased()
      if !configuredDomains.contains(domain) {
        warnings.append(
          "\(domain) has a packet-filter rule but no matching safe resolver entry."
        )
      }
    }

    return ContainerHostAccessCatalog(
      configurations: configurations.sorted { $0.domain < $1.domain },
      warnings: Array(Set(warnings)).sorted()
    )
  }

  func validate(_ configuration: ContainerHostAccessConfiguration) throws {
    guard loadCatalog().configurations.contains(configuration) else {
      throw ContainerAttachmentValidationError.unavailableHostAccess
    }
  }

  private func requireSecureDirectory(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path(percentEncoded: false), &info) == 0 else {
      throw HostAccessInspectionError.unreadable
    }
    guard
      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      info.st_uid == expectedOwnerUID,
      info.st_mode & 0o022 == 0
    else {
      throw HostAccessInspectionError.unsafeMetadata
    }
  }

  private func readSecureFile(_ url: URL) throws -> String {
    var info = stat()
    guard lstat(url.path(percentEncoded: false), &info) == 0 else {
      throw HostAccessInspectionError.unreadable
    }
    guard
      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      info.st_uid == expectedOwnerUID,
      info.st_mode & 0o022 == 0,
      info.st_size >= 0,
      info.st_size <= Self.maximumConfigurationBytes
    else {
      throw HostAccessInspectionError.unsafeMetadata
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  private func parseResolver(
    _ text: String,
    expectedDomain: String
  ) throws -> ContainerHostAccessConfiguration {
    var directives: [String: String] = [:]

    for rawLine in text.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      let parts = line.split(whereSeparator: { $0.isWhitespace })
      guard parts.count == 2 else {
        throw HostAccessInspectionError.invalidResolver
      }
      let key = String(parts[0])
      guard ["domain", "search", "nameserver", "port", "options"].contains(key) else {
        throw HostAccessInspectionError.invalidResolver
      }
      guard directives.updateValue(String(parts[1]), forKey: key) == nil else {
        throw HostAccessInspectionError.invalidResolver
      }
    }

    guard
      let domain = directives["domain"],
      domain.caseInsensitiveCompare(expectedDomain) == .orderedSame,
      directives["search"]?.caseInsensitiveCompare(domain) == .orderedSame,
      directives["nameserver"] == "127.0.0.1",
      directives["port"] == "1053",
      let option = directives["options"],
      option.hasPrefix("localhost:"),
      option.filter({ $0 == ":" }).count == 1
    else {
      throw HostAccessInspectionError.invalidResolver
    }

    return try ContainerHostAccessConfiguration(
      domain: domain,
      redirectIPv4Address: String(option.dropFirst("localhost:".count))
    )
  }

  private func redirectRule(for configuration: ContainerHostAccessConfiguration) -> String {
    "rdr inet from any to \(configuration.redirectIPv4Address) -> 127.0.0.1 # \(configuration.domain)"
  }
}

private enum HostAccessInspectionError: LocalizedError {
  case unreadable
  case unsafeMetadata
  case invalidResolver

  var errorDescription: String? {
    switch self {
    case .unreadable:
      "The configuration could not be read."
    case .unsafeMetadata:
      "The configuration is not a secure regular system file."
    case .invalidResolver:
      "The resolver entry is not an exact localhost redirect."
    }
  }
}
