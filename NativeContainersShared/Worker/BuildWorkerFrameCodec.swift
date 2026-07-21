import Foundation

typealias ContainerBuildWorkerFrameError = BoundedJSONFrameError
typealias ContainerBuildWorkerFramedInput = BoundedJSONFramedInput
typealias ContainerBuildWorkerFrameCodec = BoundedJSONFrameCodec
typealias ContainerBuildWorkerFrameDecoder<Value: Decodable & Sendable> =
  BoundedJSONFrameDecoder<Value>
