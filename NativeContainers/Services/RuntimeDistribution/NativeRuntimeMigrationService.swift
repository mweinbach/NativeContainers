import Darwin
import Foundation

actor NativeRuntimeMigrationService {
  private struct CompletionMarker: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sourceRootPath: String
    let fingerprint: String
    let categories: [String]
  }

  private let graphSnapshotter: any NativeRuntimeLaunchGraphSnapshotting
  private let graphClassifier: NativeRuntimeLaunchGraphClassifier
  private let copier: any NativeRuntimePersistentDataCopying
  private let publisher: any NativeRuntimeMigrationPublishing
  private let fileManager: FileManager

  init(
    manifests: [NativeRuntimeDistributionManifest],
    graphSnapshotter: any NativeRuntimeLaunchGraphSnapshotting,
    copier: any NativeRuntimePersistentDataCopying =
      CloneOrCopyNativeRuntimePersistentDataCopier(),
    publisher: any NativeRuntimeMigrationPublishing =
      AtomicNativeRuntimeMigrationPublisher(),
    fileManager: FileManager = .default
  ) {
    self.init(
      contractsByOrigin: Dictionary(
        uniqueKeysWithValues: manifests.map {
          let services = $0.launchServices
          let anchors = services.filter {
            $0.label == "com.apple.container.apiserver"
          }
          return (
            $0.origin,
            NativeRuntimeLaunchGraphContract(
              services: services,
              requiredServices: anchors.isEmpty ? services : anchors
            )
          )
        }
      ),
      graphSnapshotter: graphSnapshotter,
      copier: copier,
      publisher: publisher,
      fileManager: fileManager
    )
  }

  init(
    contractsByOrigin: [NativeRuntimeOrigin: NativeRuntimeLaunchGraphContract],
    graphSnapshotter: any NativeRuntimeLaunchGraphSnapshotting,
    copier: any NativeRuntimePersistentDataCopying =
      CloneOrCopyNativeRuntimePersistentDataCopier(),
    publisher: any NativeRuntimeMigrationPublishing =
      AtomicNativeRuntimeMigrationPublisher(),
    fileManager: FileManager = .default
  ) {
    self.graphSnapshotter = graphSnapshotter
    graphClassifier = NativeRuntimeLaunchGraphClassifier(
      contractsByOrigin: contractsByOrigin
    )
    self.copier = copier
    self.publisher = publisher
    self.fileManager = fileManager
  }

  func completionState(
    _ layout: NativeRuntimeMigrationLayout
  ) throws -> NativeRuntimeMigrationCompletionState {
    try validate(layout)
    let destination = layout.destinationRootURL.standardizedFileURL
    guard fileManager.fileExists(atPath: destination.nativeContainersPOSIXPath) else {
      return .notCompleted
    }
    let marker = try readMarker(from: destination, layout: layout)
    return .completed(fingerprint: marker.fingerprint)
  }

  func migrate(
    _ layout: NativeRuntimeMigrationLayout
  ) async throws -> NativeRuntimeMigrationResult {
    try validate(layout)
    try await requireBothRuntimesInactive()

    let destination = layout.destinationRootURL.standardizedFileURL
    let parent = destination.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: parent,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )

    let lockURL = parent.appending(
      path: ".nativecontainers-runtime-migration.lock",
      directoryHint: .notDirectory
    )
    guard let lease = try AdvisoryFileLock.acquire(at: lockURL) else {
      throw NativeRuntimeMigrationError.migrationInProgress
    }
    defer { lease.release() }

    if fileManager.fileExists(atPath: destination.nativeContainersPOSIXPath) {
      let marker = try readMarker(from: destination, layout: layout)
      return .alreadyCompleted(fingerprint: marker.fingerprint)
    }

    let staging = parent.appending(
      path: ".nativecontainers-runtime-\(UUID().uuidString.lowercased()).partial",
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(
      at: staging,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    var published = false
    defer {
      if !published {
        try? fileManager.removeItem(at: staging)
      }
    }

    let fingerprint: String
    do {
      fingerprint = try copier.copyPersistentData(
        layout: layout,
        stagingRootURL: staging
      )
    } catch let error as NativeRuntimeMigrationError {
      throw error
    } catch {
      throw NativeRuntimeMigrationError.copyFailed(error.localizedDescription)
    }

    try await requireBothRuntimesInactive()
    try writeMarker(
      CompletionMarker(
        schemaVersion: CompletionMarker.currentSchemaVersion,
        sourceRootPath: layout.sourceRootURL.standardizedFileURL.path,
        fingerprint: fingerprint,
        categories: layout.selections
          .map(\.category.rawValue)
          .sorted()
      ),
      to: staging
    )
    try publisher.synchronizeStagedTree(at: staging)
    try publisher.publish(
      stagingRootURL: staging,
      destinationRootURL: destination
    )
    published = true
    try publisher.synchronizeParent(of: destination)
    return .migrated(fingerprint: fingerprint)
  }

  private func requireBothRuntimesInactive() async throws {
    let state = try graphClassifier.classify(
      try await graphSnapshotter.snapshot()
    )
    guard state == .inactive else {
      throw NativeRuntimeMigrationError.runtimeActive
    }
  }

  private func validate(_ layout: NativeRuntimeMigrationLayout) throws {
    let source = layout.sourceRootURL.standardizedFileURL
    let destination = layout.destinationRootURL.standardizedFileURL
    guard
      source.isFileURL,
      destination.isFileURL,
      source.path.hasPrefix("/"),
      destination.path.hasPrefix("/"),
      source.path != destination.path,
      !destination.path.hasPrefix(source.path + "/"),
      !source.path.hasPrefix(destination.path + "/")
    else {
      throw NativeRuntimeMigrationError.invalidLayout(
        "Source and destination roots are not isolated."
      )
    }

    let expected = Set(NativeRuntimePersistentDataCategory.allCases)
    let observed = Set(layout.selections.map(\.category))
    guard observed == expected else {
      throw NativeRuntimeMigrationError.invalidLayout(
        "Every persistent data category must appear at least once."
      )
    }

    var sources = Set<String>()
    var destinations = Set<String>()
    for selection in layout.selections {
      guard
        Self.isSafeRelativePath(selection.sourceRelativePath),
        Self.isSafeRelativePath(selection.destinationRelativePath),
        sources.insert(selection.sourceRelativePath).inserted,
        destinations.insert(selection.destinationRelativePath).inserted
      else {
        throw NativeRuntimeMigrationError.invalidLayout(
          "A selected path is unsafe or duplicated."
        )
      }
    }
    let sortedDestinations = destinations.sorted()
    for (index, path) in sortedDestinations.enumerated() {
      guard
        !sortedDestinations.dropFirst(index + 1)
          .contains(where: { $0.hasPrefix(path + "/") })
      else {
        throw NativeRuntimeMigrationError.invalidLayout(
          "Selected destination paths overlap."
        )
      }
    }
  }

  private func writeMarker(
    _ marker: CompletionMarker,
    to staging: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(marker)
    let url = markerURL(in: staging)
    do {
      try data.write(to: url, options: [.atomic])
      guard chmod(url.nativeContainersPOSIXPath, 0o600) == 0 else {
        throw NativeRuntimeMigrationError.publishFailed(
          "Could not secure the completion marker."
        )
      }
    } catch let error as NativeRuntimeMigrationError {
      throw error
    } catch {
      throw NativeRuntimeMigrationError.publishFailed(error.localizedDescription)
    }
  }

  private func readMarker(
    from destination: URL,
    layout: NativeRuntimeMigrationLayout
  ) throws -> CompletionMarker {
    let data = try readMarkerData(from: destination)
    guard
      let marker = try? JSONDecoder().decode(CompletionMarker.self, from: data),
      marker.schemaVersion == CompletionMarker.currentSchemaVersion,
      marker.sourceRootPath == layout.sourceRootURL.standardizedFileURL.path,
      marker.categories == layout.selections.map(\.category.rawValue).sorted(),
      marker.fingerprint.count == 64,
      marker.fingerprint.allSatisfy(Set("0123456789abcdef").contains)
    else {
      throw NativeRuntimeMigrationError.invalidCompletionMarker
    }
    return marker
  }

  private func readMarkerData(from destination: URL) throws -> Data {
    let rootDescriptor = Darwin.open(
      destination.nativeContainersPOSIXPath,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard rootDescriptor >= 0 else {
      throw NativeRuntimeMigrationError.destinationExists
    }
    defer { Darwin.close(rootDescriptor) }

    var rootMetadata = stat()
    guard
      Darwin.fstat(rootDescriptor, &rootMetadata) == 0,
      rootMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      rootMetadata.st_uid == getuid(),
      rootMetadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw NativeRuntimeMigrationError.invalidCompletionMarker
    }

    let markerDescriptor = Darwin.openat(
      rootDescriptor,
      ".nativecontainers-migration.json",
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard markerDescriptor >= 0 else {
      throw NativeRuntimeMigrationError.destinationExists
    }
    defer { Darwin.close(markerDescriptor) }

    var markerMetadata = stat()
    guard
      Darwin.fstat(markerDescriptor, &markerMetadata) == 0,
      markerMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      markerMetadata.st_uid == getuid(),
      markerMetadata.st_nlink == 1,
      markerMetadata.st_size > 0,
      markerMetadata.st_size <= 64 * 1_024,
      markerMetadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw NativeRuntimeMigrationError.invalidCompletionMarker
    }

    var data = Data(count: Int(markerMetadata.st_size))
    try data.withUnsafeMutableBytes { bytes in
      guard let baseAddress = bytes.baseAddress else {
        throw NativeRuntimeMigrationError.invalidCompletionMarker
      }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.read(
          markerDescriptor,
          baseAddress.advanced(by: offset),
          bytes.count - offset
        )
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw NativeRuntimeMigrationError.invalidCompletionMarker
        }
        offset += count
      }
    }
    return data
  }

  private func markerURL(in root: URL) -> URL {
    root.appending(
      path: ".nativecontainers-migration.json",
      directoryHint: .notDirectory
    )
  }

  private static func isSafeRelativePath(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("/") else { return false }
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    return components.allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".."
    }
  }
}
