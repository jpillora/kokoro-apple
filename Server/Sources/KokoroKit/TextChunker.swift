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

  /// Chunks tuned for low-latency streaming. The first chunk is emitted at the
  /// very first sentence (`.!?`) or clause (`,;:—`) boundary — capped at
  /// `firstChunkWords` for a boundary-less opening — so the first audio is ready
  /// as fast as possible. Later chunks pack toward a cap that doubles each time,
  /// up to `maxWordsPerChunk`, for throughput. Original punctuation is preserved.
  /// Unlike `split`, it inserts no pauses and ignores paragraph boundaries — it
  /// optimizes purely for time-to-first-sound.
  public static func splitStreaming(
    _ text: String, firstChunkWords: Int = 8, maxWordsPerChunk: Int = 40
  ) -> [String] {
    let words = text.split(whereSeparator: \.isWhitespace)
    guard !words.isEmpty else { return [] }

    let sentenceEnd: Set<Character> = [".", "!", "?"]
    let clauseEnd: Set<Character> = [",", ";", ":", "—", "–"]
    func endsAtBoundary(_ word: Substring) -> Bool {
      // The last character that isn't a closing quote/bracket.
      guard let c = word.last(where: { !"\")]}'’”".contains($0) }) else { return false }
      return sentenceEnd.contains(c) || clauseEnd.contains(c)
    }

    var chunks: [String] = []
    var current: [Substring] = []
    var cap = max(1, min(firstChunkWords, maxWordsPerChunk))
    for word in words {
      current.append(word)
      let n = current.count
      let isFirst = chunks.isEmpty
      let flush = isFirst
        ? (endsAtBoundary(word) && n >= 2) || n >= cap // first boundary, fast
        : (endsAtBoundary(word) && n >= cap) || n >= min(cap * 2, maxWordsPerChunk)
      if flush {
        chunks.append(current.joined(separator: " "))
        current.removeAll(keepingCapacity: true)
        if !isFirst { cap = min(maxWordsPerChunk, cap * 2) } // ramp after first
      }
    }
    if !current.isEmpty { chunks.append(current.joined(separator: " ")) }
    return chunks
  }
}
