import Foundation

enum StorageByteFormatter {
  static func string(from bytes: UInt64) -> String {
    let bounded = min(bytes, UInt64(Int64.max))
    return ByteCountFormatter.string(
      fromByteCount: Int64(bounded),
      countStyle: .file
    )
  }
}
