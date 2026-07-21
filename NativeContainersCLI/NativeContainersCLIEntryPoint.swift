import Foundation

@main
struct NativeContainersCLIEntryPoint {
  static func main() async {
    let requestID = UUID()
    do {
      let command = try NativeContainersCLIParser.parse(
        Array(CommandLine.arguments.dropFirst()),
        requestID: requestID
      )
      let result = try await NativeContainersCLIClient().execute(command)
      FileHandle.standardOutput.write(result.stdout)
      if !result.stderr.isEmpty { FileHandle.standardError.write(result.stderr) }
      Foundation.exit(result.exitCode)
    } catch let error as NativeContainersCLIError {
      let code: NativeContainersControlErrorCode
      switch error {
      case .invalidArguments:
        code = .invalidArguments
      case .appUnavailable:
        code = .appUnavailable
      case .protocolError:
        code = .protocolMismatch
      }
      writeLocalFailure(
        requestID: requestID,
        code: code,
        message: NativeContainersControlRedactor.message(error.localizedDescription)
      )
      Foundation.exit(2)
    } catch {
      writeLocalFailure(
        requestID: requestID,
        code: .internalError,
        message: "The operation could not be completed."
      )
      FileHandle.standardError.write(Data("The operation could not be completed.\n".utf8))
      Foundation.exit(1)
    }
  }

  private static func writeLocalFailure(
    requestID: UUID,
    code: NativeContainersControlErrorCode,
    message: String
  ) {
    let value: [String: Any] = [
      "schemaVersion": NativeContainersControlProtocol.schemaVersion,
      "requestID": requestID.uuidString.lowercased(),
      "ok": false,
      "error": [
        "code": code.rawValue,
        "message": message,
      ],
    ]
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
      ?? Data("{\"ok\":false}".utf8)
    FileHandle.standardOutput.write(data + Data([0x0a]))
  }
}
