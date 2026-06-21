import Foundation

enum ImageBuildHistoryStatus: String, Codable, Equatable, Sendable {
  case running
  case succeeded
  case partiallySucceeded
  case failed
  case cancelled
  case interrupted

  var isTerminal: Bool { self != .running }
}

enum ImageBuildHistoryFailureKind: String, Codable, Equatable, Sendable {
  case authorization
  case staleReview
  case context
  case secretReview
  case builder
  case artifact
  case destinationReview
  case publication
  case partialFinalization
  case partialImport
  case partialExport
  case unknown
}

struct ImageBuildHistoryRetainedImage: Codable, Equatable, Identifiable, Sendable {
  let reference: String
  let digest: String

  var id: String { "\(reference)@\(digest)" }
}

struct ImageBuildHistoryRecord: Codable, Equatable, Sendable, Identifiable {
  let id: UUID
  let buildID: UUID
  let launchID: UUID
  let contextDisplayName: String
  let contextFingerprint: String
  let dockerfileSHA256: String
  let outputKind: ImageBuildOutputKind
  let requestedTags: [String]
  let completedTags: [String]
  let platforms: [ContainerBuildPlatform]
  let buildArgumentKeys: [String]
  let labelKeys: [String]
  let targetStage: String
  let startedAt: Date
  let finishedAt: Date?
  let durationMilliseconds: Int64?
  let status: ImageBuildHistoryStatus
  let imageDigest: String?
  let retainedImages: [ImageBuildHistoryRetainedImage]
  let failureKind: ImageBuildHistoryFailureKind?
  let secretCount: Int
  let noCache: Bool
  let pullLatest: Bool

  func finishing(
    at finishedAt: Date,
    status: ImageBuildHistoryStatus,
    imageDigest: String?,
    completedTags: [String],
    failureKind: ImageBuildHistoryFailureKind?,
    retainedImages: [ImageBuildHistoryRetainedImage] = []
  ) -> ImageBuildHistoryRecord {
    ImageBuildHistoryRecord(
      id: id,
      buildID: buildID,
      launchID: launchID,
      contextDisplayName: contextDisplayName,
      contextFingerprint: contextFingerprint,
      dockerfileSHA256: dockerfileSHA256,
      outputKind: outputKind,
      requestedTags: requestedTags,
      completedTags: completedTags,
      platforms: platforms,
      buildArgumentKeys: buildArgumentKeys,
      labelKeys: labelKeys,
      targetStage: targetStage,
      startedAt: startedAt,
      finishedAt: finishedAt,
      durationMilliseconds: max(
        0,
        Int64((finishedAt.timeIntervalSince(startedAt) * 1_000).rounded())
      ),
      status: status,
      imageDigest: imageDigest,
      retainedImages: retainedImages,
      failureKind: failureKind,
      secretCount: secretCount,
      noCache: noCache,
      pullLatest: pullLatest
    )
  }
}

extension ImageBuildHistoryRecord {
  private enum CodingKeys: String, CodingKey {
    case id
    case buildID
    case launchID
    case contextDisplayName
    case contextFingerprint
    case dockerfileSHA256
    case outputKind
    case requestedTags
    case completedTags
    case platforms
    case buildArgumentKeys
    case labelKeys
    case targetStage
    case startedAt
    case finishedAt
    case durationMilliseconds
    case status
    case imageDigest
    case retainedImages
    case failureKind
    case secretCount
    case noCache
    case pullLatest
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    buildID = try container.decode(UUID.self, forKey: .buildID)
    launchID = try container.decode(UUID.self, forKey: .launchID)
    contextDisplayName = try container.decode(
      String.self,
      forKey: .contextDisplayName
    )
    contextFingerprint = try container.decode(
      String.self,
      forKey: .contextFingerprint
    )
    dockerfileSHA256 = try container.decode(
      String.self,
      forKey: .dockerfileSHA256
    )
    outputKind =
      try container.decodeIfPresent(
        ImageBuildOutputKind.self,
        forKey: .outputKind
      ) ?? .imageStore
    requestedTags = try container.decode([String].self, forKey: .requestedTags)
    completedTags = try container.decode([String].self, forKey: .completedTags)
    platforms = try container.decode(
      [ContainerBuildPlatform].self,
      forKey: .platforms
    )
    buildArgumentKeys = try container.decode(
      [String].self,
      forKey: .buildArgumentKeys
    )
    labelKeys = try container.decode([String].self, forKey: .labelKeys)
    targetStage = try container.decode(String.self, forKey: .targetStage)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
    durationMilliseconds = try container.decodeIfPresent(
      Int64.self,
      forKey: .durationMilliseconds
    )
    status = try container.decode(
      ImageBuildHistoryStatus.self,
      forKey: .status
    )
    imageDigest = try container.decodeIfPresent(
      String.self,
      forKey: .imageDigest
    )
    retainedImages =
      try container.decodeIfPresent(
        [ImageBuildHistoryRetainedImage].self,
        forKey: .retainedImages
      ) ?? []
    failureKind = try container.decodeIfPresent(
      ImageBuildHistoryFailureKind.self,
      forKey: .failureKind
    )
    secretCount = try container.decode(Int.self, forKey: .secretCount)
    noCache = try container.decode(Bool.self, forKey: .noCache)
    pullLatest = try container.decode(Bool.self, forKey: .pullLatest)
  }
}

struct ImageBuildHistorySnapshot: Equatable, Sendable {
  let records: [ImageBuildHistoryRecord]
  let rejectedRecordCount: Int
}
