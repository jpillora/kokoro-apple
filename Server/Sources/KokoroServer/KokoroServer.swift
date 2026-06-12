import FlyingFox
import Foundation
import KokoroKit
import KokoroSwift
import MLX

struct TTSParams: Decodable {
  let text: String
  var voice: String?
  var speed: Float?
}

enum TTSError: Error, CustomStringConvertible {
  case unknownVoice(String)

  var description: String {
    switch self {
    case let .unknownVoice(name): "unknown voice '\(name)' — see GET /voices"
    }
  }
}

/// Serializes access to KokoroTTS: the engine (and MLX evaluation) is not
/// thread-safe, so concurrent HTTP requests queue here one at a time.
actor Synthesizer {
  private let tts: KokoroTTS
  private let voices: [String: MLXArray]
  nonisolated let voiceNames: [String]

  init(modelPath: URL, voicesPath: URL) throws {
    voices = try VoiceLoader.loadAll(from: voicesPath)
    voiceNames = voices.keys.sorted()
    tts = KokoroTTS(modelPath: modelPath, g2p: .misaki)
  }

  func synthesize(text: String, voiceName: String, speed: Float) throws -> [Float] {
    guard let voice = voices[voiceName] else {
      throw TTSError.unknownVoice(voiceName)
    }
    let language: Language = voiceName.first == "a" ? .enUS : .enGB
    let silence = [Float](repeating: 0, count: KokoroTTS.Constants.samplingRate / 2)
    var samples: [Float] = []
    for chunk in TextChunker.split(text) {
      let (chunkSamples, _) = try tts.generateAudio(voice: voice, language: language, text: chunk, speed: speed)
      if !samples.isEmpty { samples.append(contentsOf: silence) }
      samples.append(contentsOf: chunkSamples)
    }
    return samples
  }
}

@main
struct KokoroServerMain {
  static func main() async throws {
    let env = ProcessInfo.processInfo.environment
    let modelPath = env["KOKORO_MODEL_PATH"] ?? "/tmp/kokoro-model/kokoro-v1_0.safetensors"
    let voicesPath = env["KOKORO_VOICES_PATH"] ?? "/tmp/KokoroTestApp/Resources/voices.npz"
    let host = env["KOKORO_HOST"] ?? "127.0.0.1"
    let port = UInt16(env["KOKORO_PORT"] ?? "8080") ?? 8080
    let defaultVoice = env["KOKORO_VOICE"] ?? "bm_fable"

    let fm = FileManager.default
    guard fm.fileExists(atPath: modelPath) else {
      fputs("Missing model at \(modelPath) (set KOKORO_MODEL_PATH)\n", stderr)
      fputs("Download with:\n  curl -L -o '\(modelPath)' 'https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/kokoro-v1_0.safetensors'\n", stderr)
      exit(1)
    }
    guard fm.fileExists(atPath: voicesPath) else {
      fputs("Missing voices.npz at \(voicesPath) (set KOKORO_VOICES_PATH)\n", stderr)
      exit(1)
    }

    print("Loading model and voices...")
    let synthesizer = try Synthesizer(
      modelPath: URL(fileURLWithPath: modelPath),
      voicesPath: URL(fileURLWithPath: voicesPath)
    )
    guard let warmVoice = synthesizer.voiceNames.contains(defaultVoice)
      ? defaultVoice : synthesizer.voiceNames.first
    else {
      fputs("No voices found in \(voicesPath)\n", stderr)
      exit(1)
    }

    // First generation triggers MLX kernel compilation; do it before
    // accepting traffic so the first request isn't slow.
    print("Warming up...")
    let warmStart = Date()
    _ = try await synthesizer.synthesize(text: "Warm up.", voiceName: warmVoice, speed: 1.0)
    print("Warmed up in \(String(format: "%.2f", Date().timeIntervalSince(warmStart)))s")

    let cors: HTTPHeaders = [
      HTTPHeader(rawValue: "Access-Control-Allow-Origin"): "*",
      HTTPHeader(rawValue: "Access-Control-Allow-Headers"): "Content-Type",
    ]

    @Sendable func json(_ status: HTTPStatusCode, _ object: some Encodable & Sendable) -> HTTPResponse {
      let body = (try? JSONEncoder().encode(object)) ?? Data()
      var headers = cors
      headers[.contentType] = "application/json"
      return HTTPResponse(statusCode: status, headers: headers, body: body)
    }

    @Sendable func synthesize(_ params: TTSParams) async -> HTTPResponse {
      let text = params.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else {
        return json(.badRequest, ["error": "missing 'text'"])
      }
      let voiceName = params.voice ?? defaultVoice
      let start = Date()
      do {
        let samples = try await synthesizer.synthesize(
          text: text, voiceName: voiceName, speed: params.speed ?? 1.0
        )
        let wav = WavEncoder.encode(samples: samples, sampleRate: KokoroTTS.Constants.samplingRate)
        let audioSeconds = Double(samples.count) / Double(KokoroTTS.Constants.samplingRate)
        print("tts voice=\(voiceName) chars=\(text.count) audio=\(String(format: "%.2f", audioSeconds))s took=\(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        var headers = cors
        headers[.contentType] = "audio/wav"
        return HTTPResponse(statusCode: .ok, headers: headers, body: wav)
      } catch let error as TTSError {
        return json(.badRequest, ["error": "\(error)"])
      } catch {
        return json(.internalServerError, ["error": "synthesis failed: \(error)"])
      }
    }

    let server = HTTPServer(address: try .inet(ip4: host, port: port))

    await server.appendRoute("GET /healthz") { _ in
      HTTPResponse(statusCode: .ok, body: Data("ok".utf8))
    }

    await server.appendRoute("GET /voices") { _ in
      json(.ok, synthesizer.voiceNames)
    }

    await server.appendRoute("POST /tts") { request in
      guard let params = try? await JSONDecoder().decode(TTSParams.self, from: request.bodyData) else {
        return json(.badRequest, ["error": #"invalid body; expected JSON like {"text":"hello","voice":"bm_fable","speed":1.0}"#])
      }
      return await synthesize(params)
    }

    await server.appendRoute("GET /tts") { request in
      guard let text = request.query["text"] else {
        return json(.badRequest, ["error": "missing 'text' query parameter"])
      }
      let params = TTSParams(
        text: text,
        voice: request.query["voice"],
        speed: request.query["speed"].flatMap(Float.init)
      )
      return await synthesize(params)
    }

    await server.appendRoute("OPTIONS *") { _ in
      HTTPResponse(statusCode: .noContent, headers: cors)
    }

    await server.appendRoute("GET /") { _ in
      HTTPResponse(
        statusCode: .ok,
        headers: [.contentType: "text/html; charset=utf-8"],
        body: Data(indexPage(defaultVoice: defaultVoice).utf8)
      )
    }

    let serverTask = Task { try await server.run() }
    try await server.waitUntilListening()
    print("KokoroServer listening on http://\(host):\(port)")
    try await serverTask.value
  }
}

func indexPage(defaultVoice: String) -> String {
  #"""
  <!doctype html>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Kokoro TTS</title>
  <style>
    body { font: 16px system-ui; max-width: 640px; margin: 40px auto; padding: 0 16px }
    textarea { width: 100%; height: 120px; font: inherit }
    select, button, input { font: inherit; padding: 4px 10px }
    #row { display: flex; gap: 12px; margin: 12px 0; align-items: center }
    audio { width: 100% }
  </style>
  <h1>Kokoro TTS</h1>
  <textarea id="text">In Xanadu did Kubla Khan a stately pleasure-dome decree.</textarea>
  <div id="row">
    <select id="voice"></select>
    <label>speed <input id="speed" type="number" value="1.0" step="0.1" min="0.5" max="2.0" style="width:70px"></label>
    <button id="go">Speak</button>
  </div>
  <audio id="audio" controls></audio>
  <script>
    const $ = (id) => document.getElementById(id);
    fetch('/voices').then((r) => r.json()).then((names) => {
      $('voice').innerHTML = names
        .map((n) => '<option' + (n === '\#(defaultVoice)' ? ' selected' : '') + '>' + n + '</option>')
        .join('');
    });
    $('go').onclick = async () => {
      $('go').disabled = true;
      try {
        const res = await fetch('/tts', {
          method: 'POST',
          body: JSON.stringify({
            text: $('text').value,
            voice: $('voice').value,
            speed: parseFloat($('speed').value),
          }),
        });
        if (!res.ok) { alert((await res.json()).error); return; }
        $('audio').src = URL.createObjectURL(await res.blob());
        $('audio').play();
      } finally {
        $('go').disabled = false;
      }
    };
  </script>
  """#
}
