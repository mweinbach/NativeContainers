import Foundation

extension URL {
  var nativeContainersPOSIXPath: String {
    var result = path(percentEncoded: false)
    while result.count > 1, result.hasSuffix("/") {
      result.removeLast()
    }
    return result
  }
}
