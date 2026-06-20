import FlyingSocks
import Foundation

/// Bridges an `AsyncThrowingStream<[UInt8], Error>` — into which the handler
/// pushes one fully-framed Server-Sent Event at a time — onto FlyingFox's
/// `AsyncBufferedSequence`, the protocol `HTTPBodySequence(from:)` consumes to
/// stream a chunked response body. Each `nextBuffer` hands back exactly one
/// event's bytes, so events flush to the client as they are produced rather
/// than being buffered until synthesis completes.
struct SSEBody: AsyncBufferedSequence {
  typealias Element = UInt8
  let stream: AsyncThrowingStream<[UInt8], Error>

  func makeAsyncIterator() -> Iterator {
    Iterator(inner: stream.makeAsyncIterator())
  }

  struct Iterator: AsyncBufferedIteratorProtocol {
    typealias Element = UInt8
    var inner: AsyncThrowingStream<[UInt8], Error>.Iterator
    private var leftover: ArraySlice<UInt8> = []

    init(inner: AsyncThrowingStream<[UInt8], Error>.Iterator) {
      self.inner = inner
    }

    /// The path FlyingFox's body writer uses: one pushed event == one buffer.
    mutating func nextBuffer(suggested count: Int) async throws -> [UInt8]? {
      try await inner.next()
    }

    /// Byte-wise fallback required by `AsyncIteratorProtocol`; unused by the
    /// buffered writer but kept correct for completeness.
    mutating func next() async throws -> UInt8? {
      while leftover.isEmpty {
        guard let buf = try await inner.next() else { return nil }
        leftover = buf[...]
      }
      return leftover.removeFirst()
    }
  }
}

/// Frames a `speech.audio.delta` event carrying a Base64-encoded audio chunk.
func sseAudioDelta(base64 audio: String) -> [UInt8] {
  Array("data: {\"type\":\"speech.audio.delta\",\"audio\":\"\(audio)\"}\n\n".utf8)
}

/// Frames the terminal `speech.audio.done` event. `usage` is best-effort —
/// Kokoro has no token concept, so `input_tokens` approximates the prompt by
/// word count and `output_tokens` is 0.
func sseAudioDone(inputTokens: Int) -> [UInt8] {
  Array(("data: {\"type\":\"speech.audio.done\",\"usage\":{\"input_tokens\":\(inputTokens)"
    + ",\"output_tokens\":0,\"total_tokens\":\(inputTokens)}}\n\n").utf8)
}

/// Frames an `error` event used when synthesis fails mid-stream (the HTTP
/// status was already sent, so we can't switch to a 4xx/5xx).
func sseError(_ message: String) -> [UInt8] {
  let escaped = message.replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
  return Array("data: {\"type\":\"error\",\"error\":{\"message\":\"\(escaped)\"}}\n\n".utf8)
}
