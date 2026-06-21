import Foundation

protocol TerminalPresetManaging: Sendable {
  func listPresets() async throws -> [TerminalPreset]
  func savePreset(_ preset: TerminalPreset) async throws
  func deletePreset(id: UUID) async throws
}

actor TerminalPresetStore: TerminalPresetManaging {
  static let maximumPresetCount = 64
  static let maximumEncodedBytes = 256 * 1_024

  private struct Envelope: Codable {
    let schemaVersion: Int
    let presets: [TerminalPreset]
  }

  private static let schemaVersion = 1
  private static let standardKey = "terminal.presets.v1"

  private let defaults: UserDefaults
  private let key: String

  init(
    suiteName: String? = nil,
    key: String = TerminalPresetStore.standardKey
  ) {
    if let suiteName, let defaults = UserDefaults(suiteName: suiteName) {
      self.defaults = defaults
    } else {
      defaults = .standard
    }
    self.key = key
  }

  static func standard() -> TerminalPresetStore {
    TerminalPresetStore()
  }

  func listPresets() throws -> [TerminalPreset] {
    try loadValidatedPresets()
  }

  func savePreset(_ preset: TerminalPreset) throws {
    var presets = try loadValidatedPresets()
    if let duplicate = presets.first(where: {
      $0.id != preset.id && $0.name.caseInsensitiveCompare(preset.name) == .orderedSame
    }) {
      throw TerminalWorkspaceError.duplicatePresetName(duplicate.name)
    }

    if let index = presets.firstIndex(where: { $0.id == preset.id }) {
      presets[index] = preset
    } else {
      guard presets.count < Self.maximumPresetCount else {
        throw TerminalWorkspaceError.presetLimitExceeded
      }
      presets.append(preset)
    }
    try persist(presets)
  }

  func deletePreset(id: UUID) throws {
    var presets = try loadValidatedPresets()
    guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
    presets.remove(at: index)
    try persist(presets)
  }

  private func loadValidatedPresets() throws -> [TerminalPreset] {
    guard let data = defaults.data(forKey: key) else { return [] }
    guard data.count <= Self.maximumEncodedBytes else {
      throw TerminalWorkspaceError.persistenceFailed("the preset payload is too large")
    }

    do {
      let envelope = try JSONDecoder().decode(Envelope.self, from: data)
      guard envelope.schemaVersion == Self.schemaVersion else {
        throw TerminalWorkspaceError.persistenceFailed(
          "unsupported preset schema version \(envelope.schemaVersion)"
        )
      }
      guard envelope.presets.count <= Self.maximumPresetCount else {
        throw TerminalWorkspaceError.presetLimitExceeded
      }

      var identifiers: Set<UUID> = []
      var names: Set<String> = []
      let presets = try envelope.presets.map { preset in
        guard identifiers.insert(preset.id).inserted else {
          throw TerminalWorkspaceError.persistenceFailed(
            "the preset payload contains duplicate identifiers"
          )
        }
        let normalizedName = preset.name.folding(
          options: [.caseInsensitive, .diacriticInsensitive],
          locale: Locale(identifier: "en_US_POSIX")
        )
        guard names.insert(normalizedName).inserted else {
          throw TerminalWorkspaceError.duplicatePresetName(preset.name)
        }
        return try TerminalPreset(
          id: preset.id,
          name: preset.name,
          program: preset.program,
          launchesAsLoginShell: preset.launchesAsLoginShell,
          workingDirectory: preset.workingDirectory
        )
      }
      return presets.sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
    } catch let error as TerminalWorkspaceError {
      throw error
    } catch {
      throw TerminalWorkspaceError.persistenceFailed(error.localizedDescription)
    }
  }

  private func persist(_ presets: [TerminalPreset]) throws {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(
        Envelope(schemaVersion: Self.schemaVersion, presets: presets)
      )
      guard data.count <= Self.maximumEncodedBytes else {
        throw TerminalWorkspaceError.persistenceFailed("the preset payload is too large")
      }
      defaults.set(data, forKey: key)
    } catch let error as TerminalWorkspaceError {
      throw error
    } catch {
      throw TerminalWorkspaceError.persistenceFailed(error.localizedDescription)
    }
  }
}

actor EphemeralTerminalPresetStore: TerminalPresetManaging {
  private var presets: [TerminalPreset]

  init(presets: [TerminalPreset] = []) {
    self.presets = presets
  }

  func listPresets() -> [TerminalPreset] {
    presets.sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  func savePreset(_ preset: TerminalPreset) throws {
    if let duplicate = presets.first(where: {
      $0.id != preset.id && $0.name.caseInsensitiveCompare(preset.name) == .orderedSame
    }) {
      throw TerminalWorkspaceError.duplicatePresetName(duplicate.name)
    }
    if let index = presets.firstIndex(where: { $0.id == preset.id }) {
      presets[index] = preset
    } else {
      guard presets.count < TerminalPresetStore.maximumPresetCount else {
        throw TerminalWorkspaceError.presetLimitExceeded
      }
      presets.append(preset)
    }
  }

  func deletePreset(id: UUID) {
    presets.removeAll { $0.id == id }
  }
}
