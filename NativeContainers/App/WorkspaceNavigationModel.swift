import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceNavigationModel {
  private(set) var route: WorkspaceRoute
  private(set) var entries: [WorkspaceResourceEntry]
  private(set) var results: [WorkspaceResourceEntry]
  var query: String {
    didSet { recomputeResults() }
  }
  var isQuickOpenPresented: Bool {
    didSet {
      if !isQuickOpenPresented, oldValue {
        query = ""
      }
    }
  }

  @ObservationIgnored
  private let catalog: any WorkspaceResourceCataloging

  init(
    initialRoute: WorkspaceRoute = .overview,
    snapshot: WorkspaceResourceSnapshot = WorkspaceResourceSnapshot(),
    catalog: any WorkspaceResourceCataloging = WorkspaceResourceCatalog()
  ) {
    self.route = initialRoute
    self.catalog = catalog
    self.entries = catalog.entries(from: snapshot)
    self.results = []
    self.query = ""
    self.isQuickOpenPresented = false
    recomputeResults()
    reconcileRoute()
  }

  func update(
    _ snapshot: WorkspaceResourceSnapshot,
    reconcileMissingRoute: Bool = true
  ) {
    entries = catalog.entries(from: snapshot)
    recomputeResults()
    if reconcileMissingRoute {
      reconcileRoute()
    }
  }

  @discardableResult
  func navigate(
    to route: WorkspaceRoute,
    lockedTo lockedRoute: WorkspaceRoute? = nil
  ) -> Bool {
    guard canNavigate(to: route, lockedTo: lockedRoute) else { return false }
    self.route = route
    isQuickOpenPresented = false
    return true
  }

  func canNavigate(
    to route: WorkspaceRoute,
    lockedTo lockedRoute: WorkspaceRoute? = nil
  ) -> Bool {
    if let lockedRoute, route.baseRoute != lockedRoute.baseRoute {
      return false
    }
    return catalog.contains(route, in: entries)
  }

  func presentQuickOpen() {
    isQuickOpenPresented = true
  }

  func dismissQuickOpen() {
    isQuickOpenPresented = false
  }

  private func reconcileRoute() {
    guard route.isResourceRoute, !catalog.contains(route, in: entries) else {
      return
    }
    route = route.baseRoute
  }

  private func recomputeResults() {
    results = catalog.search(query, in: entries, limit: 80)
  }
}
