import Foundation
import MLX
import MLXUtilsLibrary

/// Loads voice embeddings from a `voices.npz` archive.
///
/// The archive contains one `.npy` array per voice (e.g. `bm_fable.npy`).
/// Use `load(from:name:)` to read a single voice embedding, or
/// `loadAll(from:)` to read every voice, for use with
/// `KokoroTTS.generateAudio(voice:language:text:)`.
public enum VoiceLoader {
  public enum Error: Swift.Error {
    case fileNotReadable(URL)
    case voiceNotFound(String)
  }

  /// Loads a single voice embedding by name from a `voices.npz` archive.
  /// - Parameters:
  ///   - url: File URL to a `voices.npz` archive.
  ///   - name: Voice key without the `.npy` suffix (e.g. `"bm_fable"`).
  /// - Returns: An `MLXArray` suitable for passing to `KokoroTTS.generateAudio`.
  public static func load(from url: URL, name: String) throws -> MLXArray {
    guard let voices = NpyzReader.read(fileFromPath: url) else {
      throw Error.fileNotReadable(url)
    }
    guard let voice = voices[name + ".npy"] else {
      throw Error.voiceNotFound(name)
    }
    return voice
  }

  /// Loads every voice embedding in a `voices.npz` archive, keyed by voice
  /// name with the `.npy` suffix stripped.
  public static func loadAll(from url: URL) throws -> [String: MLXArray] {
    guard let voices = NpyzReader.read(fileFromPath: url) else {
      throw Error.fileNotReadable(url)
    }
    return Dictionary(uniqueKeysWithValues: voices.map { key, value in
      (key.hasSuffix(".npy") ? String(key.dropLast(4)) : key, value)
    })
  }
}
