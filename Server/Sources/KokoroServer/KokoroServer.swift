import CryptoKit
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
                        (default: in the state dir, auto-downloaded)
    KOKORO_VOICES_PATH  path to voices.npz
                        (default: in the state dir, auto-downloaded)
    KOKORO_HOST         bind address (default 127.0.0.1; set 0.0.0.0 to expose)
    KOKORO_PORT         port (default 8080)
    KOKORO_VOICE        default voice (default bm_fable)

  Endpoints:
    GET  /         browser playground
    GET  /healthz  liveness
    GET  /voices   voice names as JSON
    POST /tts      {"text":"...","voice":"bm_fable","speed":1.0} -> audio/wav
    GET  /tts?text=...&voice=...&speed=...                       -> audio/wav

  The state dir is $XDG_STATE_HOME/kokoro-apple (default
  ~/.local/state/kokoro-apple). Release binaries extract their embedded
  resources (model config, G2P data, MLX GPU kernels) there and re-exec
  from it; the model (327 MB) and voices (15 MB) are downloaded there on
  first run. Development builds instead run from the package build dir
  after `make metallib`.
  """

  static let modelSource =
    URL(string: "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/kokoro-v1_0.safetensors")!
  static let voicesSource =
    URL(string: "https://raw.githubusercontent.com/mlalma/KokoroTestApp/main/Resources/voices.npz")!

  static func stateDir(env: [String: String]) -> URL {
    let home = env["XDG_STATE_HOME"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
    return home.appendingPathComponent("kokoro-apple")
  }

  /// Downloads `source` to `dest` unless it already exists. Streams to a
  /// sibling temp file then renames, so an interrupted download never leaves
  /// a half-written file behind. Exits with a manual-download hint on error.
  static func ensureDownloaded(_ label: String, to dest: URL, from source: URL) async {
    let fm = FileManager.default
    if fm.fileExists(atPath: dest.path) { return }
    let tmp = dest.appendingPathExtension("download-\(getpid())")
    do {
      try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
      print("Downloading \(label) from \(source.host ?? "?") to \(dest.path)")
      let (bytes, response) = try await URLSession.shared.bytes(from: source)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
      let expected = response.expectedContentLength
      fm.createFile(atPath: tmp.path, contents: nil)
      let handle = try FileHandle(forWritingTo: tmp)
      defer { try? handle.close() }
      var buffer = Data(capacity: 1 << 20)
      var written: Int64 = 0
      var lastBucket = -1
      for try await byte in bytes {
        buffer.append(byte)
        if buffer.count >= 1 << 20 {
          try handle.write(contentsOf: buffer)
          written += Int64(buffer.count)
          buffer.removeAll(keepingCapacity: true)
          // Progress every 5% (or every 32 MB when the size is unknown).
          let bucket = expected > 0 ? Int(written * 20 / expected) : Int(written >> 25)
          if bucket != lastBucket {
            lastBucket = bucket
            let total = expected > 0 ? "/\(expected / 1_000_000)" : ""
            print("  \(label): \(written / 1_000_000)\(total) MB")
          }
        }
      }
      try handle.write(contentsOf: buffer)
      try handle.close()
      if fm.fileExists(atPath: dest.path) {
        try fm.removeItem(at: dest)
      }
      try fm.moveItem(at: tmp, to: dest)
      print("Downloaded \(label)")
    } catch {
      try? fm.removeItem(at: tmp)
      fputs("Failed to download \(label): \(error.localizedDescription)\n", stderr)
      fputs("Fetch it manually:\n  curl -L -o '\(dest.path)' '\(source.absoluteString)'\n", stderr)
      exit(1)
    }
  }

  /// Self-contained release binaries embed a tar.gz of everything that must
  /// live beside the executable at runtime: the SwiftPM resource bundles
  /// (Kokoro model config, MisakiSwift G2P dictionaries) and the MLX GPU
  /// kernels. SwiftPM's generated Bundle.module accessor only searches next
  /// to the executable or the absolute build dir baked in at compile time,
  /// and MLX likewise wants mlx.metallib beside the binary — so when nothing
  /// is colocated we extract the archive into the state dir, hardlink the
  /// binary there, and re-exec from it, after which everything resolves.
  static func ensureResources(env: [String: String]) -> String? {
    let fm = FileManager.default
    guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let exeDir = exe.deletingLastPathComponent()
    let hasBundles = fm.fileExists(atPath: exeDir.appendingPathComponent("KokoroSwift_KokoroSwift.bundle").path)
    let hasKernels = fm.fileExists(atPath: exeDir.appendingPathComponent("mlx.metallib").path)
      || fm.fileExists(atPath: exeDir.appendingPathComponent("mlx-swift_Cmlx.bundle").path)
    if hasBundles, hasKernels {
      return nil
    }

    guard let archive = embeddedResources() else {
      return """
      No resources found next to this binary at \(exeDir.path), and none are
      embedded in it (development build?). Development builds must run from
      the package build dir (swift run KokoroServer) after `make metallib`;
      release binaries (make dist / release.sh) are self-contained.
      """
    }

    let stateDir = Self.stateDir(env: env)
    do {
      try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
      let marker = stateDir.appendingPathComponent(".resources-\(shortHash(archive))")
      if !fm.fileExists(atPath: marker.path) {
        print("Extracting embedded resources to \(stateDir.path)")
        let tmp = stateDir.appendingPathComponent(".resources.tgz-\(getpid())")
        try archive.write(to: tmp)
        defer { try? fm.removeItem(at: tmp) }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", tmp.path, "-C", stateDir.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
          return "Failed to extract embedded resources (tar exited \(tar.terminationStatus))"
        }
        for entry in (try? fm.contentsOfDirectory(atPath: stateDir.path)) ?? []
          where entry.hasPrefix(".resources-") {
          try? fm.removeItem(at: stateDir.appendingPathComponent(entry))
        }
        fm.createFile(atPath: marker.path, contents: nil)
      }

      // Run from the state dir so Bundle.main and MLX find everything
      // beside the executable.
      let target = stateDir.appendingPathComponent("kokoro-server")
      if !isSameFile(exe.path, target.path) {
        try? fm.removeItem(at: target)
        if link(exe.path, target.path) != 0 {
          try fm.copyItem(at: exe, to: target)
        }
      }
      if exeDir.standardizedFileURL != stateDir.standardizedFileURL {
        var argv = CommandLine.arguments.map { strdup($0) }
        argv.append(nil)
        execv(target.path, argv)
        return "Failed to re-exec \(target.path): \(String(cString: strerror(errno)))"
      }
      return nil
    } catch {
      return "Failed to set up resources in \(stateDir.path): \(error)"
    }
  }

  static func isSameFile(_ a: String, _ b: String) -> Bool {
    var statA = stat(), statB = stat()
    return stat(a, &statA) == 0 && stat(b, &statB) == 0
      && statA.st_dev == statB.st_dev && statA.st_ino == statB.st_ino
  }

  static func shortHash(_ data: Data) -> String {
    SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  /// Reads the resources archive that the Makefile links into the binary
  /// via `-sectcreate __DATA __kokoro_res`.
  static func embeddedResources() -> Data? {
    for i in 0 ..< _dyld_image_count() {
      guard let header = _dyld_get_image_header(i), header.pointee.filetype == MH_EXECUTE else {
        continue
      }
      var size: UInt = 0
      let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
      guard let bytes = getsectiondata(header64, "__DATA", "__kokoro_res", &size), size > 0 else {
        return nil
      }
      return Data(bytes: bytes, count: Int(size))
    }
    return nil
  }

  static func main() async throws {
    // Keep logs timely when stdout is a pipe or file (launchd, tee, ...).
    setvbuf(stdout, nil, _IOLBF, 0)

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

    // May extract embedded resources and re-exec from the state dir; do it
    // before anything else so the re-exec'd process repeats minimal work.
    if let problem = ensureResources(env: env) {
      fputs(problem + "\n", stderr)
      exit(1)
    }

    let state = stateDir(env: env)
    let modelPath = env["KOKORO_MODEL_PATH"]
      ?? state.appendingPathComponent("kokoro-v1_0.safetensors").path
    let voicesPath = env["KOKORO_VOICES_PATH"]
      ?? state.appendingPathComponent("voices.npz").path
    let host = env["KOKORO_HOST"] ?? "127.0.0.1"
    let port = UInt16(env["KOKORO_PORT"] ?? "8080") ?? 8080
    let defaultVoice = env["KOKORO_VOICE"] ?? "bm_fable"

    let modelURL = URL(fileURLWithPath: modelPath).standardizedFileURL
    let voicesURL = URL(fileURLWithPath: voicesPath).standardizedFileURL

    await ensureDownloaded("model (327 MB)", to: modelURL, from: modelSource)
    await ensureDownloaded("voices (15 MB)", to: voicesURL, from: voicesSource)

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
