import ContainerAPIClient
import ContainerPersistence
import SystemPackage

enum AppleContainerConfiguration {
  static func load() async throws -> ContainerSystemConfig {
    let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
    let applicationRoot = FilePath(health.appRoot.path(percentEncoded: false))
    let installRoot = FilePath(health.installRoot.path(percentEncoded: false))
    return try await ConfigurationLoader.load(
      configurationFiles: [
        ConfigurationLoader.configurationFile(in: applicationRoot, of: .appRoot),
        ConfigurationLoader.configurationFile(in: installRoot, of: .installRoot),
      ]
    )
  }
}
