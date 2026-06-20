import AVFoundation
import Foundation

/// Encodes mono float audio samples into the container formats that OpenAI's
/// `/v1/audio/speech` exposes. `wav`/`pcm` are produced directly; `aac`/`flac`
/// go through AVFoundation (a system framework, so no extra dependency and the
/// binary stays self-contained). `mp3`/`opus` have no system encoder on macOS
/// and are intentionally absent — `Format(openAIName:)` returns nil for them so
/// the server can answer with a clear 400.
public enum AudioEncoder {
  public enum Format: String {
    case wav, pcm, aac, flac

    /// Maps an OpenAI `response_format` string to a supported format, or nil
    /// for `mp3`/`opus`/unknown (which we cannot synthesize).
    public init?(openAIName: String) {
      switch openAIName.lowercased() {
      case "wav": self = .wav
      case "pcm": self = .pcm
      case "aac": self = .aac
      case "flac": self = .flac
      default: return nil
      }
    }

    public var contentType: String {
      switch self {
      case .wav: "audio/wav"
      case .pcm: "audio/pcm"
      case .aac: "audio/aac"
      case .flac: "audio/flac"
      }
    }
  }

  /// Mono float samples (range [-1, 1]) → 16-bit signed little-endian PCM,
  /// headerless. This is exactly OpenAI's `pcm` response (24 kHz, mono, s16le)
  /// and the body of a WAV file; both `WavEncoder` and the SSE path reuse it.
  public static func pcmS16LE(samples: [Float]) -> Data {
    var pcm = [Int16]()
    pcm.reserveCapacity(samples.count)
    for s in samples {
      pcm.append(Int16(max(-1.0, min(1.0, s)) * 32767))
    }
    // Apple platforms are little-endian, matching the required byte order.
    return pcm.withUnsafeBytes { Data($0) }
  }

  /// Encodes `samples` into `format`. Returns nil only on an encoder failure
  /// (the caller has already rejected unsupported formats via `Format`).
  public static func encode(samples: [Float], sampleRate: Int, format: Format) -> Data? {
    switch format {
    case .wav: WavEncoder.encode(samples: samples, sampleRate: sampleRate)
    case .pcm: pcmS16LE(samples: samples)
    case .aac: compressed(samples: samples, sampleRate: sampleRate, formatID: kAudioFormatMPEG4AAC, ext: "m4a")
    case .flac: compressed(samples: samples, sampleRate: sampleRate, formatID: kAudioFormatFLAC, ext: "flac")
    }
  }

  /// Encodes via AVFoundation. `AVAudioFile` only writes to a URL, so we write
  /// a unique temp file, read it back, and delete it. Requests are serialized
  /// upstream by the `Synthesizer` actor and synthesis dominates latency, so
  /// the temp-file round-trip is negligible. (AAC lands in an MP4/m4a container
  /// rather than raw ADTS — fine for the OpenAI SDK and common players.)
  private static func compressed(samples: [Float], sampleRate: Int, formatID: AudioFormatID, ext: String) -> Data? {
    guard !samples.isEmpty,
          let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
            channels: 1, interleaved: false
          ),
          let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(samples.count))
    else { return nil }

    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { src in
      buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
    }

    var settings: [String: Any] = [
      AVFormatIDKey: formatID,
      AVSampleRateKey: Double(sampleRate),
      AVNumberOfChannelsKey: 1,
    ]
    if formatID == kAudioFormatMPEG4AAC {
      settings[AVEncoderBitRateKey] = 64000
    }

    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("kokoro-\(UUID().uuidString).\(ext)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    do {
      // Scope the file so ARC closes (and flushes) it before we read back.
      do {
        // Force a float32 processing format so it matches `buffer` for every
        // container (FLAC's default processing format is otherwise integer).
        let file = try AVAudioFile(
          forWriting: tmp, settings: settings,
          commonFormat: .pcmFormatFloat32, interleaved: false
        )
        try file.write(from: buffer)
      }
      return try Data(contentsOf: tmp)
    } catch {
      return nil
    }
  }
}
