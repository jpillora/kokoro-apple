# KokoroServer

macOS executables for the [kokoro-apple](..) fork:

- **KokoroServer** — HTTP server exposing Kokoro TTS
- **KokoroDemo** — one-shot CLI that writes a WAV file
- **KokoroKit** — shared helpers (voice loading, text chunking, WAV encoding)

This lives in its own SwiftPM package (depending on the root package by path)
so the root stays byte-close to upstream `mlalma/kokoro-ios` for easy syncing,
and iOS consumers of `KokoroSwift` never resolve server-only dependencies.

## Setup

None — on first run the server downloads the model (327 MB, Hugging Face)
and voices (15 MB) into `$XDG_STATE_HOME/kokoro-apple` (default
`~/.local/state/kokoro-apple`), alongside the extracted GPU kernels.
Existing files are reused; point `KOKORO_MODEL_PATH` / `KOKORO_VOICES_PATH`
elsewhere to override.

## Metal shaders (one-time)

`swift build` alone cannot compile MLX's Metal shaders ([mlx-swift
limitation](https://github.com/ml-explore/mlx-swift#swiftpm)) — binaries die
at startup with `Failed to load the default metallib`. Compile the shaders
once via xcodebuild and colocate them with the swift-build binaries:

```sh
cd Server
make metallib   # rerun after every mlx-swift version bump
```

## Server

```sh
cd Server
swift run -c release KokoroServer
```

| Env var | Default |
| --- | --- |
| `KOKORO_MODEL_PATH` | `~/.local/state/kokoro-apple/kokoro-v1_0.safetensors` (auto-downloaded) |
| `KOKORO_VOICES_PATH` | `~/.local/state/kokoro-apple/voices.npz` (auto-downloaded) |
| `KOKORO_HOST` | `127.0.0.1` (set `0.0.0.0` to expose) |
| `KOKORO_PORT` | `8080` |
| `KOKORO_VOICE` | `bm_fable` (default voice) |
| `KOKORO_API_KEY` | unset (if set, `/v1` routes require this bearer token) |

### Endpoints

- `GET /` — browser playground
- `GET /healthz` — liveness
- `GET /voices` — JSON array of voice names
- `POST /tts` — body `{"text": "...", "voice": "bm_fable", "speed": 1.0}` → `audio/wav`
- `GET /tts?text=...&voice=...&speed=...` → `audio/wav`
- `POST /v1/audio/speech` — OpenAI-compatible (see below)
- `GET /v1/models` — OpenAI-compatible model list

```sh
curl -X POST localhost:8080/tts \
  -d '{"text": "Hello from Kokoro.", "voice": "bm_fable"}' -o hello.wav
```

### OpenAI-compatible API

`POST /v1/audio/speech` accepts OpenAI's [create speech](https://platform.openai.com/docs/api-reference/audio/createSpeech)
request, so the official SDKs work by pointing `base_url` at this server:

```python
from openai import OpenAI
client = OpenAI(base_url="http://localhost:8080/v1", api_key="not-needed")
client.audio.speech.create(
    model="tts-1",        # ignored — Kokoro is the only model
    voice="alloy",        # OpenAI names map to Kokoro voices; native names also work
    input="Hello from Kokoro.",
    response_format="wav",
).write_to_file("hello.wav")
```

- **`voice`** — OpenAI voices (`alloy`, `echo`, `fable`, `onyx`, `nova`, `shimmer`,
  `ash`, `ballad`, `coral`, `sage`, `verse`, `marin`, `cedar`) map to Kokoro voices;
  a native Kokoro name (e.g. `bm_fable`, `af_alloy` — see `GET /voices`) passes through.
- **`response_format`** — `wav`, `pcm`, `aac`, `flac` are supported (`pcm` is 24 kHz
  s16le mono). `mp3`/`opus` return `400` (no system encoder on macOS). When omitted,
  defaults to `wav`.
- **`speed`** — `0.25`–`4.0`.
- **`stream_format: "sse"`** — streams `speech.audio.delta` events (Base64 PCM) then
  `speech.audio.done`; only valid with `response_format` `pcm`/`wav`. Chunking is tuned
  for low latency: a small first chunk (so the first audio arrives fast) then larger
  chunks for throughput.
- **`model`** / **`instructions`** — accepted but ignored.
- **Auth** — a `Bearer` token is accepted (and ignored) unless `KOKORO_API_KEY` is set,
  in which case it must match.

## Demo CLI

```sh
cd Server
swift run -c release KokoroDemo   # writes /tmp/kubla-khan.wav
```

Extra env vars: `KOKORO_TEXT`, `KOKORO_TEXT_FILE`, `KOKORO_OUTPUT_PATH`.

## Releasing

`./release.sh <tag>` builds the self-contained binary (GPU kernels embedded)
and uploads `kokoro-server-macos-arm64` plus a `.sha256` to the GitHub
release for `<tag>` (created on `main` if missing, assets replaced if it
exists). Prefer non-semver tags like `server-v0.1.0` so SwiftPM never treats
them as package versions. Use `--dry-run` to build and stage without
publishing.

## Building a distributable binary

Everything (MLX, MisakiSwift, KokoroSwift) links statically into one binary,
and the Metal shader library is embedded as a Mach-O section — the result is
fully self-contained:

```sh
cd Server
make dist   # → dist/kokoro-server
```

On startup the binary extracts the GPU kernels to
`$XDG_STATE_HOME/kokoro-apple` (default `~/.local/state/kokoro-apple`) unless
it finds an `mlx.metallib` next to itself (the dev-build layout), and reuses
the extraction on later runs.

## Installing a release

Single file; rename it whatever you like:

```sh
curl -L -o ~/.local/bin/kokoro-apple \
  https://github.com/jpillora/kokoro-apple/releases/latest/download/kokoro-server-macos-arm64
chmod +x ~/.local/bin/kokoro-apple
kokoro-apple --help
```
