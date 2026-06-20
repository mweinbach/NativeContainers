import Foundation

enum RegistryTransport: String, CaseIterable, Equatable, Sendable, Identifiable {
  case automatic = "auto"
  case https
  case http

  var id: Self { self }

  var title: String {
    switch self {
    case .automatic: "Automatic"
    case .https: "HTTPS"
    case .http: "HTTP"
    }
  }

  var isInsecure: Bool { self == .http }
}

struct RegistryCredentialRecord: Equatable, Sendable, Identifiable {
  let hostname: String
  let username: String
  let createdAt: Date
  let modifiedAt: Date

  var id: String { hostname }
}

struct RegistryLoginPlan: Equatable, Sendable {
  let requestedServer: String
  let hostname: String
  let username: String
  let requestedTransport: RegistryTransport
  let resolvedTransport: RegistryTransport
  let existingCredential: RegistryCredentialRecord?

  var requiresInsecureConfirmation: Bool { resolvedTransport.isInsecure }
  var existingUsername: String? { existingCredential?.username }
  var replacesDifferentUsername: Bool {
    existingUsername.map { $0 != username } ?? false
  }
}

enum RegistryManagementError: LocalizedError, Equatable, Sendable {
  case unsupported
  case missingServer
  case invalidServer(String)
  case missingUsername
  case missingPassword
  case invalidResolvedTransport
  case insecureTransportRequiresConfirmation(String)
  case credentialReplacementRequiresConfirmation(hostname: String, username: String)
  case staleLoginPlan
  case staleLogoutPlan

  var errorDescription: String? {
    switch self {
    case .unsupported:
      "Registry credential management is unavailable."
    case .missingServer:
      "Enter a registry server."
    case .invalidServer(let server):
      "“\(server)” is not a valid registry hostname."
    case .missingUsername:
      "Enter a registry username."
    case .missingPassword:
      "Enter a registry password or access token."
    case .invalidResolvedTransport:
      "The registry transport could not be resolved."
    case .insecureTransportRequiresConfirmation(let hostname):
      "Confirm plain-text HTTP before sending credentials to \(hostname)."
    case .credentialReplacementRequiresConfirmation(let hostname, let username):
      "Confirm replacing \(username)’s stored credential for \(hostname)."
    case .staleLoginPlan:
      "The stored registry login changed after review. Review the login again before saving."
    case .staleLogoutPlan:
      "The stored registry login changed after review. Review it again before removing it."
    }
  }
}
