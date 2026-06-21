import Foundation

protocol WorkspaceResourceCataloging: Sendable {
  func entries(from snapshot: WorkspaceResourceSnapshot) -> [WorkspaceResourceEntry]
  func search(
    _ query: String,
    in entries: [WorkspaceResourceEntry],
    limit: Int
  ) -> [WorkspaceResourceEntry]
  func contains(_ route: WorkspaceRoute, in entries: [WorkspaceResourceEntry]) -> Bool
}

struct WorkspaceResourceCatalog: WorkspaceResourceCataloging {
  private let locale: Locale
  private let localizedKindTitles: [WorkspaceResourceKind: String]

  init(
    locale: Locale = .current,
    localizedKindTitles: [WorkspaceResourceKind: String] = [:]
  ) {
    self.locale = locale
    self.localizedKindTitles = localizedKindTitles
  }

  func entries(from snapshot: WorkspaceResourceSnapshot) -> [WorkspaceResourceEntry] {
    var entries: [WorkspaceResourceEntry] = []

    entries.append(
      contentsOf: snapshot.composeProjects.map { project in
        entry(
          route: .composeProject(project.name),
          kind: .composeProject,
          title: project.name,
          subtitle:
            "\(project.runningContainerCount)/\(project.containerCount) containers running",
          terms: [
            project.services.map(\.name).joined(separator: " "),
            project.containers.map(\.id).joined(separator: " "),
            project.containers.map(\.container.imageReference).joined(separator: " "),
            project.volumes.flatMap { [$0.id, $0.logicalName, $0.volume.name] }
              .joined(separator: " "),
            project.networks.flatMap { [$0.id, $0.logicalName, $0.network.name] }
              .joined(separator: " "),
          ]
        )
      }
    )
    entries.append(
      contentsOf: snapshot.containers.map { container in
        entry(
          route: .container(container.id),
          kind: .container,
          title: container.id,
          subtitle: container.imageReference,
          terms: [
            container.imageReference,
            container.platform,
            container.ipAddress,
            container.state.rawValue,
            flattenedMetadata(container.labels),
          ]
        )
      }
    )
    entries.append(
      contentsOf: snapshot.images.map { image in
        entry(
          route: .image(image.reference),
          kind: .image,
          title: image.reference,
          subtitle: image.digest,
          terms: [image.digest, image.mediaType]
        )
      }
    )
    entries.append(
      contentsOf: snapshot.volumes.map { volume in
        entry(
          route: .volume(volume.id),
          kind: .volume,
          title: volume.name,
          subtitle: "\(volume.driver) · \(volume.format)",
          terms: [
            volume.id,
            volume.driver,
            volume.format,
            volume.usedByContainerIDs.joined(separator: " "),
            flattenedMetadata(volume.labels),
          ]
        )
      }
    )
    entries.append(
      contentsOf: snapshot.networks.map { network in
        entry(
          route: .network(network.id),
          kind: .network,
          title: network.name,
          subtitle: network.assignedIPv4Subnet,
          terms: [
            network.id,
            network.assignedIPv4Subnet,
            network.ipv4Gateway,
            network.assignedIPv6Subnet,
            network.usedByContainerIDs.joined(separator: " "),
            flattenedMetadata(network.labels),
          ]
        )
      }
    )
    entries.append(
      contentsOf: snapshot.linuxMachines.map { machine in
        entry(
          route: .linuxMachine(machine.id),
          kind: .linuxMachine,
          title: machine.id,
          subtitle: machine.imageReference,
          terms: [
            machine.imageReference,
            machine.platform,
            machine.ipAddress,
            machine.state.rawValue,
          ]
        )
      }
    )
    entries.append(
      contentsOf: snapshot.macOSVirtualMachines.map { machine in
        entry(
          route: .macOSVirtualMachine(machine.id),
          kind:
            machine.guest == .macOS
            ? .macOSVirtualMachine
            : .linuxVirtualMachine,
          title: machine.name,
          subtitle: machine.id.uuidString,
          terms: [
            machine.id.uuidString,
            machine.guest.rawValue,
            machine.installState.rawValue,
          ]
        )
      }
    )

    entries.sort(by: stableEntryOrder)

    var seen: Set<WorkspaceRoute> = []
    return entries.filter { seen.insert($0.route).inserted }
  }

  func search(
    _ query: String,
    in entries: [WorkspaceResourceEntry],
    limit: Int = 80
  ) -> [WorkspaceResourceEntry] {
    guard limit > 0 else { return [] }
    let tokens = normalized(query)
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
    guard !tokens.isEmpty else {
      return Array(entries.prefix(limit))
    }

    return entries.compactMap { entry -> RankedEntry? in
      guard let score = score(entry, tokens: tokens) else { return nil }
      return RankedEntry(entry: entry, score: score)
    }
    .sorted(by: rankedEntryOrder)
    .prefix(limit)
    .map(\.entry)
  }

  func contains(
    _ route: WorkspaceRoute,
    in entries: [WorkspaceResourceEntry]
  ) -> Bool {
    !route.isResourceRoute || entries.contains { $0.route == route }
  }

  private func entry(
    route: WorkspaceRoute,
    kind: WorkspaceResourceKind,
    title: String,
    subtitle: String,
    terms: [String?]
  ) -> WorkspaceResourceEntry {
    WorkspaceResourceEntry(
      route: route,
      kind: kind,
      title: title,
      subtitle: subtitle,
      searchTerms: [localizedTitle(for: kind)] + kind.searchTerms
        + terms.compactMap { value in
          guard let value, !value.isEmpty else { return nil }
          return value
        }
    )
  }

  private func flattenedMetadata(_ metadata: [String: String]) -> String {
    metadata.keys.sorted().map { key in
      "\(key) \(metadata[key, default: ""])"
    }.joined(separator: " ")
  }

  private func localizedTitle(for kind: WorkspaceResourceKind) -> String {
    if let title = localizedKindTitles[kind] {
      return title
    }
    var resource = kind.title
    resource.locale = locale
    return String(localized: resource)
  }

  private func score(
    _ entry: WorkspaceResourceEntry,
    tokens: [String]
  ) -> Int? {
    let title = normalized(entry.title)
    let titleWords = title.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    let terms = entry.searchTerms.map(normalized)

    var total = 0
    for token in tokens {
      let tokenScore: Int?
      if title == token {
        tokenScore = 0
      } else if title.hasPrefix(token) {
        tokenScore = 10
      } else if titleWords.contains(where: { $0.hasPrefix(token) }) {
        tokenScore = 20
      } else if title.contains(token) {
        tokenScore = 30
      } else if terms.contains(token) {
        tokenScore = 40
      } else if terms.contains(where: { $0.hasPrefix(token) }) {
        tokenScore = 50
      } else if terms.contains(where: { $0.contains(token) }) {
        tokenScore = 60
      } else {
        tokenScore = nil
      }
      guard let tokenScore else { return nil }
      total += tokenScore
    }
    return total
  }

  private func normalized(_ value: String) -> String {
    value
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: locale
      )
      .lowercased()
  }

  private func stableEntryOrder(
    _ lhs: WorkspaceResourceEntry,
    _ rhs: WorkspaceResourceEntry
  ) -> Bool {
    if lhs.kind.rawValue != rhs.kind.rawValue {
      return lhs.kind.rawValue < rhs.kind.rawValue
    }
    let lhsTitle = normalized(lhs.title)
    let rhsTitle = normalized(rhs.title)
    if lhsTitle != rhsTitle {
      return lhsTitle.utf8.lexicographicallyPrecedes(rhsTitle.utf8)
    }
    return lhs.route.stableIdentifier.utf8.lexicographicallyPrecedes(
      rhs.route.stableIdentifier.utf8
    )
  }

  private func rankedEntryOrder(_ lhs: RankedEntry, _ rhs: RankedEntry) -> Bool {
    if lhs.score != rhs.score { return lhs.score < rhs.score }
    return stableEntryOrder(lhs.entry, rhs.entry)
  }
}

private struct RankedEntry {
  let entry: WorkspaceResourceEntry
  let score: Int
}
