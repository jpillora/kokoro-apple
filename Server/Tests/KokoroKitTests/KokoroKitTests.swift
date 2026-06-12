import Foundation
import Testing
@testable import KokoroKit

@Suite struct TextChunkerTests {
  @Test func emptyTextProducesNoChunks() {
    #expect(TextChunker.split("") == [])
    #expect(TextChunker.split("   \n\n  ") == [])
  }

  @Test func shortTextIsOneChunk() {
    let chunks = TextChunker.split("Hello world. How are you?")
    #expect(chunks == ["Hello world. How are you."])
  }

  @Test func longTextSplitsOnSentenceBoundaries() {
    let sentence = "The quick brown fox jumps over the lazy dog near the river bank today"  // 14 words
    let text = Array(repeating: sentence, count: 10).joined(separator: ". ") + "."
    let chunks = TextChunker.split(text, maxWordsPerChunk: 40)
    #expect(chunks.count > 1)
    for chunk in chunks {
      // Greedy packing: a chunk holds at most 40 words unless a single
      // sentence alone exceeds the limit.
      #expect(chunk.split(separator: " ").count <= 42)
      #expect(chunk.hasSuffix("."))
    }
    // No words lost.
    let originalWords = text.split(whereSeparator: { " .".contains($0) }).count
    let chunkedWords = chunks.joined(separator: " ").split(whereSeparator: { " .".contains($0) }).count
    #expect(originalWords == chunkedWords)
  }

  @Test func paragraphsNeverShareAChunk() {
    let chunks = TextChunker.split("First paragraph here.\n\nSecond paragraph here.")
    #expect(chunks == ["First paragraph here.", "Second paragraph here."])
  }
}

@Suite struct WavEncoderTests {
  @Test func encodesValidHeader() {
    let samples = [Float](repeating: 0.5, count: 24000)
    let wav = WavEncoder.encode(samples: samples, sampleRate: 24000)

    #expect(wav.count == 44 + samples.count * 2)
    #expect(String(data: wav[0 ..< 4], encoding: .ascii) == "RIFF")
    #expect(String(data: wav[8 ..< 12], encoding: .ascii) == "WAVE")
    #expect(String(data: wav[36 ..< 40], encoding: .ascii) == "data")

    let riffSize = wav[4 ..< 8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    #expect(riffSize == UInt32(36 + samples.count * 2))
    let sampleRate = wav[24 ..< 28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    #expect(sampleRate == 24000)
    let dataSize = wav[40 ..< 44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    #expect(dataSize == UInt32(samples.count * 2))
  }

  @Test func clampsOutOfRangeSamples() {
    let wav = WavEncoder.encode(samples: [2.0, -2.0], sampleRate: 24000)
    let first = wav[44 ..< 46].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
    let second = wav[46 ..< 48].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
    #expect(first == 32767)
    #expect(second == -32767)
  }
}
