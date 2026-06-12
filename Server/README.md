# KokoroServer

macOS executables for the [kokoro-ios](..) fork:

- **KokoroServer** — HTTP server exposing Kokoro TTS
- **KokoroDemo** — one-shot CLI that writes a WAV file
- **KokoroKit** — shared helpers (voice loading, text chunking, WAV encoding)

This lives in its own SwiftPM package (depending on the root package by path)
so the root stays byte-close to upstream `mlalma/kokoro-ios` for easy syncing,
and iOS consumers of `KokoroSwift` never resolve server-only dependencies.

## Setup

Model and voices are not bundled; download once:

```sh
mkdir -p /tmp/kokoro-model
curl -L -o /tmp/kokoro-model/kokoro-v1_0.safetensors \
  'https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/kokoro-v1_0.safetensors'
git clone --depth 1 https://github.com/mlalma/KokoroTestApp /tmp/KokoroTestApp
```

(Or put them anywhere and set `KOKORO_MODEL_PATH` / `KOKORO_VOICES_PATH`.)

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
| `KOKORO_MODEL_PATH` | `/tmp/kokoro-model/kokoro-v1_0.safetensors` |
| `KOKORO_VOICES_PATH` | `/tmp/KokoroTestApp/Resources/voices.npz` |
| `KOKORO_HOST` | `127.0.0.1` (set `0.0.0.0` to expose) |
| `KOKORO_PORT` | `8080` |
| `KOKORO_VOICE` | `bm_fable` (default voice) |

### Endpoints

- `GET /` — browser playground
- `GET /healthz` — liveness
- `GET /voices` — JSON array of voice names
- `POST /tts` — body `{"text": "...", "voice": "bm_fable", "speed": 1.0}` → `audio/wav`
- `GET /tts?text=...&voice=...&speed=...` → `audio/wav`

```sh
curl -X POST localhost:8080/tts \
  -d '{"text": "Hello from Kokoro.", "voice": "bm_fable"}' -o hello.wav
```

## Demo CLI

```sh
cd Server
swift run -c release KokoroDemo   # writes /tmp/kubla-khan.wav
```

Extra env vars: `KOKORO_TEXT`, `KOKORO_TEXT_FILE`, `KOKORO_OUTPUT_PATH`.

## Releasing

`./release.sh <tag>` builds the release binary, bundles it with the metallib
and README into `dist/kokoro-server-<tag>-macos-arm64.tar.gz`, and uploads it
to the GitHub release for `<tag>` (created on `main` if missing, assets
replaced if it exists). Prefer non-semver tags like `server-v0.1.0` so SwiftPM
never treats them as package versions. Use `--dry-run` to build and stage
without publishing.

## Building a distributable binary

Everything (MLX, MisakiSwift, KokoroSwift) links statically into one binary;
only the Metal shader library rides alongside as a file:

```sh
cd Server
make dist
# → dist/kokoro-server + dist/mlx.metallib (keep them side by side)
```
