import CryptoKit
import Darwin
import Foundation

protocol NativeRuntimePersistentDataCopying: Sendable {
  func copyPersistentData(
    layout: NativeRuntimeMigrationLayout,
    stagingRootURL: URL
  ) throws -> String
}

struct CloneOrCopyNativeRuntimePersistentDataCopier:
  NativeRuntimePersistentDataCopying
{
  private static let excludedDirectoryNames: Set<String> = [
    "logs", "pids", "sockets",
  ]
  private static let excludedFileExtensions: Set<String> = [
    "log", "pid", "plist",
  ]

  private let requiredOwnerUID: uid_t

  init(requiredOwnerUID: uid_t = getuid()) {
    self.requiredOwnerUID = requiredOwnerUID
  }

  func copyPersistentData(
    layout: NativeRuntimeMigrationLayout,
    stagingRootURL: URL
  ) throws -> String {
    var selectionFingerprints: [(NativeRuntimePersistentDataCategory, String, String, String)] = []

    for selection in sortedSelections(layout.selections) {
      guard
        try selectionExists(
          rootURL: layout.sourceRootURL,
          relativePath: selection.sourceRelativePath
        )
      else {
        guard !selection.isRequired else {
          throw NativeRuntimeMigrationError.unsafeSource(
            layout.sourceRootURL
              .appending(path: selection.sourceRelativePath)
              .path
          )
        }
        selectionFingerprints.append(
          (
            selection.category,
            selection.sourceRelativePath,
            selection.destinationRelativePath,
            "absent"
          )
        )
        continue
      }

      let before = try fingerprintSelection(
        rootURL: layout.sourceRootURL,
        relativePath: selection.sourceRelativePath
      )
      try copySelection(
        sourceRootURL: layout.sourceRootURL,
        sourceRelativePath: selection.sourceRelativePath,
        stagingRootURL: stagingRootURL,
        destinationRelativePath: selection.destinationRelativePath
      )
      let afterSource = try fingerprintSelection(
        rootURL: layout.sourceRootURL,
        relativePath: selection.sourceRelativePath
      )
      let destinationFingerprint = try fingerprintSelection(
        rootURL: stagingRootURL,
        relativePath: selection.destinationRelativePath
      )
      guard before == afterSource else {
        throw NativeRuntimeMigrationError.validationFailed(
          "The Apple source changed while \(selection.category.rawValue) was copied."
        )
      }
      guard before == destinationFingerprint else {
        throw NativeRuntimeMigrationError.validationFailed(
          "The staged \(selection.category.rawValue) tree does not match its source."
        )
      }
      selectionFingerprints.append(
        (
          selection.category,
          selection.sourceRelativePath,
          selection.destinationRelativePath,
          before
        )
      )
    }

    var hasher = SHA256()
    for (category, source, destination, fingerprint) in selectionFingerprints {
      for component in [category.rawValue, source, destination, fingerprint] {
        hasher.update(data: Data(component.utf8))
        hasher.update(data: Data([0]))
      }
    }
    return Self.hexDigest(hasher.finalize())
  }

  private func sortedSelections(
    _ selections: [NativeRuntimeMigrationSelection]
  ) -> [NativeRuntimeMigrationSelection] {
    selections.sorted {
      (
        $0.category.rawValue,
        $0.destinationRelativePath,
        $0.sourceRelativePath
      ) < (
        $1.category.rawValue,
        $1.destinationRelativePath,
        $1.sourceRelativePath
      )
    }
  }

  private func selectionExists(
    rootURL: URL,
    relativePath: String
  ) throws -> Bool {
    let rootDescriptor = Darwin.open(
      rootURL.nativeContainersPOSIXPath,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard rootDescriptor >= 0 else {
      throw NativeRuntimeMigrationError.unsafeSource(rootURL.path)
    }
    defer { Darwin.close(rootDescriptor) }
    try requireSecureDirectory(
      descriptor: rootDescriptor,
      displayPath: rootURL.path
    )

    let components = try Self.safeComponents(relativePath)
    var currentDescriptor = rootDescriptor
    var ownedDescriptor: Int32?
    defer {
      if let ownedDescriptor {
        Darwin.close(ownedDescriptor)
      }
    }
    var currentPath = rootURL.path

    for (index, component) in components.enumerated() {
      currentPath += "/" + component
      var linkMetadata = stat()
      guard
        Darwin.fstatat(
          currentDescriptor,
          component,
          &linkMetadata,
          AT_SYMLINK_NOFOLLOW
        ) == 0
      else {
        if errno == ENOENT { return false }
        throw NativeRuntimeMigrationError.unsafeSource(currentPath)
      }

      let kind = linkMetadata.st_mode & mode_t(S_IFMT)
      guard kind == mode_t(S_IFDIR) || kind == mode_t(S_IFREG) else {
        throw NativeRuntimeMigrationError.unsupportedSourceEntry(currentPath)
      }
      let isFinal = index == components.count - 1
      guard isFinal || kind == mode_t(S_IFDIR) else {
        throw NativeRuntimeMigrationError.unsafeSource(currentPath)
      }
      let flags =
        O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        | (kind == mode_t(S_IFDIR) ? O_DIRECTORY : 0)
      let nextDescriptor = Darwin.openat(currentDescriptor, component, flags)
      guard nextDescriptor >= 0 else {
        if errno == ENOENT { return false }
        throw NativeRuntimeMigrationError.unsafeSource(currentPath)
      }
      if let ownedDescriptor {
        Darwin.close(ownedDescriptor)
      }
      ownedDescriptor = nextDescriptor
      currentDescriptor = nextDescriptor

      var metadata = stat()
      guard Darwin.fstat(nextDescriptor, &metadata) == 0 else {
        throw NativeRuntimeMigrationError.unsafeSource(currentPath)
      }
      try requireSameNode(
        expected: linkMetadata,
        observed: metadata,
        displayPath: currentPath
      )
      try requireSecureNode(metadata, displayPath: currentPath)
    }

    return true
  }

  private func fingerprintSelection(
    rootURL: URL,
    relativePath: String
  ) throws -> String {
    try withOpenSelection(rootURL: rootURL, relativePath: relativePath) {
      descriptor,
      metadata,
      displayPath in
      var hasher = SHA256()
      try updateFingerprint(
        descriptor: descriptor,
        metadata: metadata,
        relativeComponents: [],
        displayPath: displayPath,
        hasher: &hasher
      )
      return Self.hexDigest(hasher.finalize())
    }
  }

  private func updateFingerprint(
    descriptor: Int32,
    metadata: stat,
    relativeComponents: [String],
    displayPath: String,
    hasher: inout SHA256
  ) throws {
    let relativePath =
      relativeComponents.isEmpty
      ? "."
      : relativeComponents.joined(separator: "/")
    switch metadata.st_mode & mode_t(S_IFMT) {
    case mode_t(S_IFDIR):
      hasher.update(data: Data("D\(relativePath)\u{0}".utf8))
      for name in try directoryEntryNames(
        descriptor: descriptor,
        displayPath: displayPath
      ) {
        try withOpenChild(
          parentDescriptor: descriptor,
          name: name,
          relativeComponents: relativeComponents + [name],
          displayPath: displayPath + "/" + name
        ) { childDescriptor, childMetadata, excluded in
          guard !excluded else { return }
          try updateFingerprint(
            descriptor: childDescriptor,
            metadata: childMetadata,
            relativeComponents: relativeComponents + [name],
            displayPath: displayPath + "/" + name,
            hasher: &hasher
          )
        }
      }
    case mode_t(S_IFREG):
      hasher.update(
        data: Data("F\(relativePath)\u{0}\(metadata.st_size)\u{0}".utf8)
      )
      guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
        throw NativeRuntimeMigrationError.unsafeSource(displayPath)
      }
      var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
      while true {
        let count = buffer.withUnsafeMutableBytes {
          Darwin.read(descriptor, $0.baseAddress, $0.count)
        }
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else {
          throw NativeRuntimeMigrationError.unsafeSource(displayPath)
        }
        if count == 0 { break }
        hasher.update(data: Data(buffer[0..<count]))
      }
    default:
      throw NativeRuntimeMigrationError.unsupportedSourceEntry(displayPath)
    }
  }

  private func copySelection(
    sourceRootURL: URL,
    sourceRelativePath: String,
    stagingRootURL: URL,
    destinationRelativePath: String
  ) throws {
    try withOpenSelection(
      rootURL: sourceRootURL,
      relativePath: sourceRelativePath
    ) { sourceDescriptor, sourceMetadata, sourceDisplayPath in
      let stagingDescriptor = Darwin.open(
        stagingRootURL.nativeContainersPOSIXPath,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard stagingDescriptor >= 0 else {
        throw NativeRuntimeMigrationError.copyFailed(
          "Could not open the staging root."
        )
      }
      defer { Darwin.close(stagingDescriptor) }
      try requireSecureDirectory(
        descriptor: stagingDescriptor,
        displayPath: stagingRootURL.path
      )

      let components = try Self.safeComponents(destinationRelativePath)
      try withDestinationParent(
        rootDescriptor: stagingDescriptor,
        components: Array(components.dropLast()),
        displayPath: stagingRootURL.path
      ) { parentDescriptor, parentDisplayPath in
        try copyNode(
          sourceDescriptor: sourceDescriptor,
          sourceMetadata: sourceMetadata,
          sourceDisplayPath: sourceDisplayPath,
          destinationParentDescriptor: parentDescriptor,
          destinationName: components.last!,
          destinationDisplayPath: parentDisplayPath + "/" + components.last!,
          relativeComponents: []
        )
      }
    }
  }

  private func copyNode(
    sourceDescriptor: Int32,
    sourceMetadata: stat,
    sourceDisplayPath: String,
    destinationParentDescriptor: Int32,
    destinationName: String,
    destinationDisplayPath: String,
    relativeComponents: [String]
  ) throws {
    switch sourceMetadata.st_mode & mode_t(S_IFMT) {
    case mode_t(S_IFDIR):
      guard
        Darwin.mkdirat(destinationParentDescriptor, destinationName, 0o700) == 0
      else {
        throw NativeRuntimeMigrationError.copyFailed(
          "Could not create \(destinationDisplayPath) (errno \(errno))."
        )
      }
      let destinationDescriptor = Darwin.openat(
        destinationParentDescriptor,
        destinationName,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard destinationDescriptor >= 0 else {
        throw NativeRuntimeMigrationError.copyFailed(
          "Could not open \(destinationDisplayPath)."
        )
      }
      defer { Darwin.close(destinationDescriptor) }

      for name in try directoryEntryNames(
        descriptor: sourceDescriptor,
        displayPath: sourceDisplayPath
      ) {
        try withOpenChild(
          parentDescriptor: sourceDescriptor,
          name: name,
          relativeComponents: relativeComponents + [name],
          displayPath: sourceDisplayPath + "/" + name
        ) { childDescriptor, childMetadata, excluded in
          guard !excluded else { return }
          try copyNode(
            sourceDescriptor: childDescriptor,
            sourceMetadata: childMetadata,
            sourceDisplayPath: sourceDisplayPath + "/" + name,
            destinationParentDescriptor: destinationDescriptor,
            destinationName: name,
            destinationDisplayPath: destinationDisplayPath + "/" + name,
            relativeComponents: relativeComponents + [name]
          )
        }
      }
      guard Darwin.fsync(destinationDescriptor) == 0 else {
        throw NativeRuntimeMigrationError.copyFailed(
          "Could not synchronize \(destinationDisplayPath)."
        )
      }

    case mode_t(S_IFREG):
      try cloneOrCopyFile(
        sourceDescriptor: sourceDescriptor,
        sourceMetadata: sourceMetadata,
        sourceDisplayPath: sourceDisplayPath,
        destinationParentDescriptor: destinationParentDescriptor,
        destinationName: destinationName,
        destinationDisplayPath: destinationDisplayPath
      )

    default:
      throw NativeRuntimeMigrationError.unsupportedSourceEntry(sourceDisplayPath)
    }
  }

  private func cloneOrCopyFile(
    sourceDescriptor: Int32,
    sourceMetadata: stat,
    sourceDisplayPath: String,
    destinationParentDescriptor: Int32,
    destinationName: String,
    destinationDisplayPath: String
  ) throws {
    let cloneResult = Darwin.fclonefileat(
      sourceDescriptor,
      destinationParentDescriptor,
      destinationName,
      0
    )
    if cloneResult != 0 {
      let code = errno
      guard code == EXDEV || code == ENOTSUP || code == EINVAL || code == EPERM else {
        throw NativeRuntimeMigrationError.copyFailed(
          "fclonefileat failed for \(sourceDisplayPath) (errno \(code))."
        )
      }
      try copyFileBytes(
        sourceDescriptor: sourceDescriptor,
        destinationParentDescriptor: destinationParentDescriptor,
        destinationName: destinationName,
        sourceDisplayPath: sourceDisplayPath
      )
    }

    let destinationDescriptor = Darwin.openat(
      destinationParentDescriptor,
      destinationName,
      O_RDWR | O_NOFOLLOW | O_CLOEXEC
    )
    guard destinationDescriptor >= 0 else {
      throw NativeRuntimeMigrationError.copyFailed(
        "Could not open \(destinationDisplayPath)."
      )
    }
    defer { Darwin.close(destinationDescriptor) }

    let safeMode = sourceMetadata.st_mode & mode_t(0o755)
    guard
      Darwin.fchmod(destinationDescriptor, safeMode) == 0,
      Darwin.fsync(destinationDescriptor) == 0
    else {
      throw NativeRuntimeMigrationError.copyFailed(
        "Could not secure and synchronize \(destinationDisplayPath)."
      )
    }
    var destinationMetadata = stat()
    guard
      Darwin.fstat(destinationDescriptor, &destinationMetadata) == 0,
      destinationMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      destinationMetadata.st_uid == requiredOwnerUID,
      destinationMetadata.st_nlink == 1,
      destinationMetadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw NativeRuntimeMigrationError.copyFailed(
        "The staged file is unsafe at \(destinationDisplayPath)."
      )
    }
  }

  private func copyFileBytes(
    sourceDescriptor: Int32,
    destinationParentDescriptor: Int32,
    destinationName: String,
    sourceDisplayPath: String
  ) throws {
    let destinationDescriptor = Darwin.openat(
      destinationParentDescriptor,
      destinationName,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      0o600
    )
    guard destinationDescriptor >= 0 else {
      throw NativeRuntimeMigrationError.copyFailed(
        "Could not create a staged copy for \(sourceDisplayPath)."
      )
    }
    defer { Darwin.close(destinationDescriptor) }
    guard Darwin.lseek(sourceDescriptor, 0, SEEK_SET) >= 0 else {
      throw NativeRuntimeMigrationError.copyFailed(
        "Could not seek \(sourceDisplayPath)."
      )
    }

    var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
    while true {
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(sourceDescriptor, $0.baseAddress, $0.count)
      }
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else {
        throw NativeRuntimeMigrationError.copyFailed(
          "Could not read \(sourceDisplayPath)."
        )
      }
      if count == 0 { break }
      try buffer.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return }
        var written = 0
        while written < count {
          let result = Darwin.write(
            destinationDescriptor,
            baseAddress.advanced(by: written),
            count - written
          )
          if result < 0, errno == EINTR { continue }
          guard result > 0 else {
            throw NativeRuntimeMigrationError.copyFailed(
              "Could not write a staged copy for \(sourceDisplayPath)."
            )
          }
          written += result
        }
      }
    }
  }

  private func withOpenSelection<T>(
    rootURL: URL,
    relativePath: String,
    body: (Int32, stat, String) throws -> T
  ) throws -> T {
    let rootDescriptor = Darwin.open(
      rootURL.nativeContainersPOSIXPath,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard rootDescriptor >= 0 else {
      throw NativeRuntimeMigrationError.unsafeSource(rootURL.path)
    }
    defer { Darwin.close(rootDescriptor) }
    try requireSecureDirectory(
      descriptor: rootDescriptor,
      displayPath: rootURL.path
    )

    let components = try Self.safeComponents(relativePath)
    var currentDescriptor = rootDescriptor
    var ownedDescriptor: Int32?
    defer {
      if let ownedDescriptor {
        Darwin.close(ownedDescriptor)
      }
    }
    var currentPath = rootURL.path
    var metadata = stat()

    for (index, component) in components.enumerated() {
      currentPath += "/" + component
      var linkMetadata = stat()
      guard
        Darwin.fstatat(
          currentDescriptor,
          component,
          &linkMetadata,
          AT_SYMLINK_NOFOLLOW
        ) == 0
      else {
        throw NativeRuntimeMigrationError.unsafeSource(currentPath)
      }
      let kind = linkMetadata.st_mode & mode_t(S_IFMT)
      guard kind == mode_t(S_IFDIR) || kind == mode_t(S_IFREG) else {
        throw NativeRuntimeMigrationError.unsupportedSourceEntry(currentPath)
      }
      let isFinal = index == components.count - 1
      guard isFinal || kind == mode_t(S_IFDIR) else {
        throw NativeRuntimeMigrationError.unsafeSource(currentPath)
      }
      let flags =
        O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        | (kind == mode_t(S_IFDIR) ? O_DIRECTORY : 0)
      let nextDescriptor = Darwin.openat(currentDescriptor, component, flags)
      guard nextDescriptor >= 0 else {
        throw NativeRuntimeMigrationError.unsafeSource(currentPath)
      }
      if let ownedDescriptor {
        Darwin.close(ownedDescriptor)
      }
      ownedDescriptor = nextDescriptor
      currentDescriptor = nextDescriptor

      guard Darwin.fstat(nextDescriptor, &metadata) == 0 else {
        throw NativeRuntimeMigrationError.unsafeSource(currentPath)
      }
      try requireSameNode(
        expected: linkMetadata,
        observed: metadata,
        displayPath: currentPath
      )
      try requireSecureNode(metadata, displayPath: currentPath)
    }

    return try body(currentDescriptor, metadata, currentPath)
  }

  private func withOpenChild<T>(
    parentDescriptor: Int32,
    name: String,
    relativeComponents: [String],
    displayPath: String,
    body: (Int32, stat, Bool) throws -> T
  ) throws -> T {
    guard Self.isSafeName(name) else {
      throw NativeRuntimeMigrationError.unsafeSource(displayPath)
    }
    var linkMetadata = stat()
    guard
      Darwin.fstatat(
        parentDescriptor,
        name,
        &linkMetadata,
        AT_SYMLINK_NOFOLLOW
      ) == 0
    else {
      throw NativeRuntimeMigrationError.unsafeSource(displayPath)
    }

    let kind = linkMetadata.st_mode & mode_t(S_IFMT)
    if kind == mode_t(S_IFLNK) {
      throw NativeRuntimeMigrationError.unsupportedSourceEntry(displayPath)
    }
    if kind == mode_t(S_IFSOCK) {
      return try body(-1, linkMetadata, true)
    }
    guard kind == mode_t(S_IFDIR) || kind == mode_t(S_IFREG) else {
      throw NativeRuntimeMigrationError.unsupportedSourceEntry(displayPath)
    }

    let flags =
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
      | (kind == mode_t(S_IFDIR) ? O_DIRECTORY : 0)
    let descriptor = Darwin.openat(parentDescriptor, name, flags)
    guard descriptor >= 0 else {
      throw NativeRuntimeMigrationError.unsafeSource(displayPath)
    }
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else {
      throw NativeRuntimeMigrationError.unsafeSource(displayPath)
    }
    try requireSameNode(
      expected: linkMetadata,
      observed: metadata,
      displayPath: displayPath
    )
    try requireSecureNode(metadata, displayPath: displayPath)
    return try body(
      descriptor,
      metadata,
      Self.shouldExclude(
        name: name,
        relativeComponents: relativeComponents,
        mode: metadata.st_mode
      )
    )
  }

  private func requireSecureNode(_ metadata: stat, displayPath: String) throws {
    let kind = metadata.st_mode & mode_t(S_IFMT)
    guard
      metadata.st_uid == requiredOwnerUID,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
      kind == mode_t(S_IFDIR)
        || (kind == mode_t(S_IFREG) && metadata.st_nlink == 1)
    else {
      throw NativeRuntimeMigrationError.unsafeSource(displayPath)
    }
  }

  private func requireSecureDirectory(
    descriptor: Int32,
    displayPath: String
  ) throws {
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else {
      throw NativeRuntimeMigrationError.unsafeSource(displayPath)
    }
    try requireSecureNode(metadata, displayPath: displayPath)
    guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
      throw NativeRuntimeMigrationError.unsafeSource(displayPath)
    }
  }

  private func requireSameNode(
    expected: stat,
    observed: stat,
    displayPath: String
  ) throws {
    guard
      expected.st_dev == observed.st_dev,
      expected.st_ino == observed.st_ino,
      expected.st_mode & mode_t(S_IFMT) == observed.st_mode & mode_t(S_IFMT)
    else {
      throw NativeRuntimeMigrationError.unsafeSource(displayPath)
    }
  }

  private func directoryEntryNames(
    descriptor: Int32,
    displayPath: String
  ) throws -> [String] {
    let duplicate = Darwin.dup(descriptor)
    guard duplicate >= 0 else {
      throw NativeRuntimeMigrationError.unsafeSource(displayPath)
    }
    guard let directory = Darwin.fdopendir(duplicate) else {
      Darwin.close(duplicate)
      throw NativeRuntimeMigrationError.unsafeSource(displayPath)
    }
    defer { Darwin.closedir(directory) }

    var names: [String] = []
    while true {
      errno = 0
      guard let entry = Darwin.readdir(directory) else {
        guard errno == 0 else {
          throw NativeRuntimeMigrationError.unsafeSource(displayPath)
        }
        break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(
          to: CChar.self,
          capacity: Int(entry.pointee.d_namlen) + 1
        ) {
          String(cString: $0)
        }
      }
      if name == "." || name == ".." { continue }
      guard Self.isSafeName(name) else {
        throw NativeRuntimeMigrationError.unsafeSource(displayPath + "/" + name)
      }
      names.append(name)
    }
    return names.sorted()
  }

  private func withDestinationParent<T>(
    rootDescriptor: Int32,
    components: [String],
    displayPath: String,
    body: (Int32, String) throws -> T
  ) throws -> T {
    let initialDescriptor = Darwin.dup(rootDescriptor)
    guard initialDescriptor >= 0 else {
      throw NativeRuntimeMigrationError.copyFailed(
        "Could not duplicate the staging root descriptor."
      )
    }
    var currentDescriptor = initialDescriptor
    var currentDisplayPath = displayPath
    defer { Darwin.close(currentDescriptor) }

    for component in components {
      currentDisplayPath += "/" + component
      if Darwin.mkdirat(currentDescriptor, component, 0o700) != 0, errno != EEXIST {
        throw NativeRuntimeMigrationError.copyFailed(
          "Could not create \(currentDisplayPath) (errno \(errno))."
        )
      }
      let nextDescriptor = Darwin.openat(
        currentDescriptor,
        component,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard nextDescriptor >= 0 else {
        throw NativeRuntimeMigrationError.copyFailed(
          "Could not open \(currentDisplayPath)."
        )
      }
      do {
        try requireSecureDirectory(
          descriptor: nextDescriptor,
          displayPath: currentDisplayPath
        )
      } catch {
        Darwin.close(nextDescriptor)
        throw error
      }
      Darwin.close(currentDescriptor)
      currentDescriptor = nextDescriptor
    }
    return try body(currentDescriptor, currentDisplayPath)
  }

  private static func safeComponents(_ relativePath: String) throws -> [String] {
    let components = relativePath.split(
      separator: "/",
      omittingEmptySubsequences: false
    ).map(String.init)
    guard !components.isEmpty, components.allSatisfy(isSafeName) else {
      throw NativeRuntimeMigrationError.invalidLayout(
        "A selected path is unsafe."
      )
    }
    return components
  }

  private static func isSafeName(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && !value.contains("/")
  }

  private static func shouldExclude(
    name: String,
    relativeComponents: [String],
    mode: mode_t
  ) -> Bool {
    if mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) { return true }
    let loweredComponents = relativeComponents.map { $0.lowercased() }
    if !excludedDirectoryNames.isDisjoint(with: loweredComponents) {
      return true
    }
    let lowered = name.lowercased()
    if lowered == "pid" { return true }
    return excludedFileExtensions.contains(URL(filePath: lowered).pathExtension)
  }

  private static func hexDigest<D: Sequence>(_ digest: D) -> String
  where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}
