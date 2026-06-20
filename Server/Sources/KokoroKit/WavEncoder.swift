import Foundation

/// Encodes raw audio samples as an in-memory WAV file.
///
/// Unlike `KokoroSwift.AudioUtils` (DEBUG-only, file-based, via AVFoundation)
/// this is a dependency-free encoder that works in release builds and returns
/// `Data`, which suits HTTP responses.
public enum WavEncoder {
  /// Encodes mono float samples (range [-1, 1]) as 16-bit PCM WAV.
  public static func encode(samples: [Float], sampleRate: Int) -> Data {
    let pcm = AudioEncoder.pcmS16LE(samples: samples)
    var data = Data(capacity: 44 + pcm.count)
    func string(_ s: StaticString) { s.withUTF8Buffer { data.append(contentsOf: $0) } }
    func uint32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func uint16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

    let dataSize = UInt32(pcm.count)
    string("RIFF")
    uint32(36 + dataSize)
    string("WAVE")
    string("fmt ")
    uint32(16) // PCM chunk size
    uint16(1) // PCM format
    uint16(1) // mono
    uint32(UInt32(sampleRate))
    uint32(UInt32(sampleRate * 2)) // byte rate
    uint16(2) // block align
    uint16(16) // bits per sample
    string("data")
    uint32(dataSize)
    data.append(pcm)
    return data
  }
}
