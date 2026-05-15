import Foundation
import KokoroSwift
import MLX

let env = ProcessInfo.processInfo.environment
let modelPath = env["KOKORO_MODEL_PATH"] ?? "/tmp/kokoro-model/kokoro-v1_0.safetensors"
let voicesPath = env["KOKORO_VOICES_PATH"] ?? "/tmp/KokoroTestApp/Resources/voices.npz"
let outputPath = env["KOKORO_OUTPUT_PATH"] ?? "/tmp/kubla-khan.wav"
let voiceName = env["KOKORO_VOICE"] ?? "bm_fable"

let fm = FileManager.default
guard fm.fileExists(atPath: modelPath) else {
  fputs("Missing model at \(modelPath)\n", stderr)
  fputs("Download with:\n  curl -L -o \(modelPath) 'https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/kokoro-v1_0.safetensors'\n", stderr)
  exit(1)
}
guard fm.fileExists(atPath: voicesPath) else {
  fputs("Missing voices.npz at \(voicesPath)\n", stderr)
  exit(1)
}

let voice: MLXArray
do {
  voice = try VoiceLoader.load(from: URL(fileURLWithPath: voicesPath), name: voiceName)
} catch {
  fputs("Failed to load voice '\(voiceName)': \(error)\n", stderr)
  exit(1)
}

let language: Language = voiceName.first == "a" ? .enUS : .enGB

let defaultText = """
In Xanadu did Kubla Khan
A stately pleasure-dome decree:
Where Alph, the sacred river, ran
Through caverns measureless to man
Down to a sunless sea.
"""

let poem: String
if let textFile = env["KOKORO_TEXT_FILE"], let contents = try? String(contentsOfFile: textFile, encoding: .utf8) {
  poem = contents
} else if let inline = env["KOKORO_TEXT"] {
  poem = inline
} else {
  poem = defaultText
}

print("Initializing Kokoro TTS...")
let tts = KokoroTTS(modelPath: URL(fileURLWithPath: modelPath), g2p: .misaki)

// Split text into chunks small enough to fit in Kokoro's 510-token limit.
// Strategy: split on sentence boundaries, then greedily pack ~40 words per chunk.
func splitIntoChunks(_ text: String, maxWordsPerChunk: Int = 40) -> [String] {
  let paragraphs = text.components(separatedBy: "\n\n")
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }

  var chunks: [String] = []
  for paragraph in paragraphs {
    let sentences = paragraph.split(whereSeparator: { ".!?".contains($0) })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    var current = ""
    var currentWords = 0
    for sentence in sentences {
      let words = sentence.split(separator: " ").count
      if currentWords + words > maxWordsPerChunk, !current.isEmpty {
        chunks.append(current)
        current = ""
        currentWords = 0
      }
      current = current.isEmpty ? sentence + "." : current + " " + sentence + "."
      currentWords += words
    }
    if !current.isEmpty { chunks.append(current) }
  }
  return chunks
}

let chunks = splitIntoChunks(poem)

print("Generating audio (voice: \(voiceName), lang: \(language.rawValue), chunks: \(chunks.count))...")
let silenceBetweenChunks = [Float](repeating: 0, count: KokoroTTS.Constants.samplingRate / 2)
var samples: [Float] = []
for (i, chunk) in chunks.enumerated() {
  let (chunkSamples, _) = try tts.generateAudio(voice: voice, language: language, text: chunk)
  print("  chunk \(i + 1)/\(chunks.count): \(chunkSamples.count) samples")
  if !samples.isEmpty { samples.append(contentsOf: silenceBetweenChunks) }
  samples.append(contentsOf: chunkSamples)
}

guard !samples.isEmpty else {
  fputs("Generated empty audio buffer\n", stderr)
  exit(1)
}

try AudioUtils.writeWavFile(
  samples: samples,
  sampleRate: Double(KokoroTTS.Constants.samplingRate),
  fileURL: URL(fileURLWithPath: outputPath)
)

let durationSeconds = Double(samples.count) / Double(KokoroTTS.Constants.samplingRate)
print("Wrote \(samples.count) samples (\(String(format: "%.2f", durationSeconds))s) to \(outputPath)")
