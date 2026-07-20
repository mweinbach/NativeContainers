import Foundation

@main
struct NativeContainersLinuxImageBuilderMain {
  static func main() async {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      let builder = NativeContainersLinuxImageBuilder(projectRoot: root)
      let revision = ProcessInfo.processInfo.environment["NATIVECONTAINERS_GUEST_REVISION"] ?? "working-tree"
      let result: NativeContainersLinuxImageBuildResult
      if (arguments.count == 2 && arguments[0] == "--output")
        || (arguments.count == 3 && arguments[0] == "--build" && arguments[1] == "--output") {
        let outputArgument = arguments[arguments.count - 1]
        result = try await builder.prepareAndBuild(
          outputDirectory: URL(fileURLWithPath: outputArgument), guestSourceRevision: revision)
      } else if arguments.count == 4, arguments[0] == "--candidate", arguments[2] == "--output" {
        // Deliberately retained as an explicitly separate packaging/debug mode. It is
        // never used by the full command and does not perform image preparation.
        result = try builder.build(
          sealedCandidateURL: URL(fileURLWithPath: arguments[1]),
          outputDirectory: URL(fileURLWithPath: arguments[3]), guestSourceRevision: revision)
      } else {
        throw NativeContainersLinuxImageBuilderError.invalidCandidate
      }
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      FileHandle.standardOutput.write(try encoder.encode(result.provenance) + Data([0x0A]))
    } catch {
      FileHandle.standardError.write(Data("native image builder: \(error.localizedDescription)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }
}
