import FlyingFox
import Foundation
import KokoroKit
import KokoroSwift
import MachO
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
  static let usage = """
  kokoro-server — Kokoro TTS over HTTP (MLX, Apple Silicon)

  Usage: kokoro-server [--help]

  Configuration is via environment variables:
    KOKORO_MODEL_PATH   path to kokoro-v1_0.safetensors
                        (default /tmp/kokoro-model/kokoro-v1_0.safetensors)
    KOKORO_VOICES_PATH  path to voices.npz
                        (default /tmp/KokoroTestApp/Resources/voices.npz)
    KOKORO_HOST         bind address (default 127.0.0.1; set 0.0.0.0 to expose)
    KOKORO_PORT         port (default 8080)
    KOKORO_VOICE        default voice (default bm_fable)

  Endpoints:
    GET  /         browser playground
    GET  /healthz  liveness
    GET  /voices   voice names as JSON
    POST /tts      {"text":"...","voice":"bm_fable","speed":1.0} -> audio/wav
    GET  /tts?text=...&voice=...&speed=...                       -> audio/wav

  Release binaries embed the MLX GPU kernels and extract them to
  $XDG_STATE_HOME/kokoro-apple (default ~/.local/state/kokoro-apple) on first
  run. Development builds instead need mlx.metallib next to the binary
  (see `make metallib`).
  """

  /// MLX loads its GPU kernels (a `.metallib`) at runtime; it searches for
  /// `mlx.metallib` next to the executable, then a `mlx-swift_Cmlx.bundle`
  /// (Xcode-built apps), and finally `default.metallib` relative to the
  /// working directory. Release binaries embed the metallib in a Mach-O
  /// section; when nothing is discoverable in place we extract it to the
  /// state dir and chdir there so MLX's working-directory fallback finds it.
  static func ensureMetallib(env: [String: String]) -> String? {
    let fm = FileManager.default
    guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let exeDir = exe.deletingLastPathComponent()
    var candidates = [
      exeDir.appendingPathComponent("mlx.metallib"),
      exeDir.appendingPathComponent("mlx-swift_Cmlx.bundle"),
    ]
    if let resources = Bundle.main.resourceURL {
      candidates.append(resources.appendingPathComponent("mlx-swift_Cmlx.bundle"))
    }
    if candidates.contains(where: { fm.fileExists(atPath: $0.path) }) {
      return nil
    }

    guard let embedded = embeddedMetallib() else {
      return """
      Missing mlx.metallib (the MLX GPU kernels): expected next to this binary at
        \(exeDir.path)/mlx.metallib
      This binary has none embedded (development build?) — either keep
      mlx.metallib beside it, or use a release binary, which embeds the
      kernels and extracts them to ~/.local/state/kokoro-apple on first run.
      """
    }

    let stateHome = env["XDG_STATE_HOME"].map { URL(fileURLWithPath: $0) }
      ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
    let stateDir = stateHome.appendingPathComponent("kokoro-apple")
    let lib = stateDir.appendingPathComponent("mlx.metallib")
    // MLX's working-directory fallback looks for this exact name.
    let alias = stateDir.appendingPathComponent("default.metallib")
    do {
      try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
      if (try? Data(contentsOf: lib)) != embedded {
        let tmp = stateDir.appendingPathComponent("mlx.metallib.tmp-\(getpid())")
        try embedded.write(to: tmp)
        if fm.fileExists(atPath: lib.path) {
          try fm.removeItem(at: lib)
        }
        try fm.moveItem(at: tmp, to: lib)
        print("Extracted embedded GPU kernels to \(lib.path)")
      }
      if (try? fm.destinationOfSymbolicLink(atPath: alias.path)) != "mlx.metallib" {
        try? fm.removeItem(at: alias)
        try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: "mlx.metallib")
      }
    } catch {
      return "Failed to extract embedded GPU kernels to \(stateDir.path): \(error)"
    }
    guard fm.changeCurrentDirectoryPath(stateDir.path) else {
      return "Failed to change working directory to \(stateDir.path)"
    }
    print("Using GPU kernels from \(lib.path)")
    return nil
  }

  /// Reads the metallib that release.sh links into the binary via
  /// `-sectcreate __DATA __mlx_metallib`.
  static func embeddedMetallib() -> Data? {
    for i in 0 ..< _dyld_image_count() {
      guard let header = _dyld_get_image_header(i), header.pointee.filetype == MH_EXECUTE else {
        continue
      }
      var size: UInt = 0
      let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
      guard let bytes = getsectiondata(header64, "__DATA", "__mlx_metallib", &size), size > 0 else {
        return nil
      }
      return Data(bytes: bytes, count: Int(size))
    }
    return nil
  }

  static func main() async throws {
    let args = CommandLine.arguments.dropFirst()
    if args.contains("--help") || args.contains("-h") {
      print(usage)
      return
    }
    if let unknown = args.first {
      fputs("unknown argument '\(unknown)'\n\n\(usage)\n", stderr)
      exit(64)
    }

    let env = ProcessInfo.processInfo.environment
    let modelPath = env["KOKORO_MODEL_PATH"] ?? "/tmp/kokoro-model/kokoro-v1_0.safetensors"
    let voicesPath = env["KOKORO_VOICES_PATH"] ?? "/tmp/KokoroTestApp/Resources/voices.npz"
    let host = env["KOKORO_HOST"] ?? "127.0.0.1"
    let port = UInt16(env["KOKORO_PORT"] ?? "8080") ?? 8080
    let defaultVoice = env["KOKORO_VOICE"] ?? "bm_fable"

    // Resolve against the original working directory now: ensureMetallib()
    // may chdir to the state dir before MLX initializes.
    let modelURL = URL(fileURLWithPath: modelPath).standardizedFileURL
    let voicesURL = URL(fileURLWithPath: voicesPath).standardizedFileURL

    let fm = FileManager.default
    guard fm.fileExists(atPath: modelURL.path) else {
      fputs("Missing model at \(modelURL.path) (set KOKORO_MODEL_PATH)\n", stderr)
      fputs("Download with:\n  curl -L -o '\(modelURL.path)' 'https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/kokoro-v1_0.safetensors'\n", stderr)
      exit(1)
    }
    guard fm.fileExists(atPath: voicesURL.path) else {
      fputs("Missing voices.npz at \(voicesURL.path) (set KOKORO_VOICES_PATH)\n", stderr)
      exit(1)
    }

    if let problem = ensureMetallib(env: env) {
      fputs(problem + "\n", stderr)
      exit(1)
    }

    print("Loading model and voices...")
    let synthesizer = try Synthesizer(modelPath: modelURL, voicesPath: voicesURL)
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
