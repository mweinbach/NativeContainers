protocol ContainerBuilderManaging: Sendable {
  func loadBuilder() async throws -> ContainerBuilderInspection
  func prepareBuilderAction(
    _ action: ContainerBuilderManagementAction
  ) async throws -> ContainerBuilderManagementPlan
  func performBuilderAction(
    _ plan: ContainerBuilderManagementPlan,
    authorization: ContainerBuilderManagementAuthorization
  ) async throws -> ContainerBuilderManagementResult
}

extension ContainerBuilderManaging {
  func loadBuilder() async throws -> ContainerBuilderInspection {
    throw ContainerBuilderManagementError.unsupported
  }

  func prepareBuilderAction(
    _ action: ContainerBuilderManagementAction
  ) async throws -> ContainerBuilderManagementPlan {
    throw ContainerBuilderManagementError.unsupported
  }

  func performBuilderAction(
    _ plan: ContainerBuilderManagementPlan,
    authorization: ContainerBuilderManagementAuthorization
  ) async throws -> ContainerBuilderManagementResult {
    throw ContainerBuilderManagementError.unsupported
  }
}
