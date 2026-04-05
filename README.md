# Dict

English Wiktionary parsed from the XML dump into a compact binary format, with:

- `encoder/`: package root with the encoding library and CLI
- `decoder/`: package root with the loading, indexing, and query library and CLI
- `backend/`: package root with the `zhttp` server that auto-builds the binary if it is missing
- `frontend/`: SolidJS UI

## Layout

```text
encoder/
decoder/
backend/
frontend/
data/
build.zig
```

The Zig sources now live directly under each package root, for example `encoder/root.zig` and `backend/main.zig`.

## Zig Commands

Build the encoder, decoder, and backend executables:

```bash
zig build
```

Encode the dictionary:

```bash
zig build -Doptimize=ReleaseFast encode -- \
  --input data/wiktionary.xml \
  --output data/wiktionary.bin
```

Build a smaller test binary:

```bash
zig build encode -- \
  --input data/wiktionary.xml \
  --output data/test.bin \
  --limit 500
```

Lookup a word with the decoder CLI:

```bash
zig build decode -- lookup --db data/wiktionary.bin --word color
```

Suggestions:

```bash
zig build decode -- suggest --db data/wiktionary.bin --prefix colo --limit 10
```

Stats:

```bash
zig build decode -- stats --db data/wiktionary.bin
```

The first decoder open builds a sidecar cache at `data/wiktionary.bin.idx`. Later opens mmap that cache and skip the expensive metadata rebuild.

Analyze the full dump structure:

```bash
zig build structure -- \
  --input data/wiktionary.xml \
  --output data/wiktionary-structure.json \
  --top 100 \
  --samples 100
```

The structure analyzer runs in `ReleaseFast` by default and emits structured JSON by default. The report includes:

- exact heading profiles with canonical titles, heading families, and parser kinds
- formatting signatures by heading and by family
- template usage by heading and by family
- translation source-label frequencies and target language-code frequencies
- structural anomalies such as bad parentage, level jumps, and pre-heading content

Run the backend server:

```bash
zig build -Doptimize=ReleaseFast serve -- --db data/wiktionary.bin --port 3000
```

If `data/wiktionary.bin` does not exist, the backend will build it from `data/wiktionary.xml` before serving requests.

## Frontend Commands

The frontend now uses a Zig CLI wrapper:

```bash
zig build frontend -- install
zig build frontend -- build
zig build frontend -- check
zig build frontend -- dev
zig build frontend -- preview
```

The Vite dev server proxies `/api/*` to `http://127.0.0.1:3000`.

## API

The backend exposes:

- `/api/stats`
- `/api/search?q=color&limit=10`
- `/api/lookup/color`
- `/api/random`

The production frontend is served from the same Zig process. Raw English entry formatting is preserved exactly, while lookup indices are rebuilt in memory after load.
