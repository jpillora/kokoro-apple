import Foundation

/// Splits long text into chunks small enough to fit in Kokoro's 510-token limit.
public enum TextChunker {
  /// Splits on sentence boundaries, then greedily packs ~`maxWordsPerChunk`
  /// words per chunk. Paragraphs (blank-line separated) never share a chunk.
  public static func split(_ text: String, maxWordsPerChunk: Int = 40) -> [String] {
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
}
