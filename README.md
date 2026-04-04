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
  --input enwiktionary.xml \
  --output data/enwiktionary.bin
```

Build a smaller test binary:

```bash
zig build encode -- \
  --input enwiktionary.xml \
  --output data/test.bin \
  --limit 500
```

Lookup a word with the decoder CLI:

```bash
zig build lookup -- --db data/enwiktionary.bin --word color
```

Suggestions:

```bash
zig build suggest -- --db data/enwiktionary.bin --prefix colo --limit 10
```

Stats:

```bash
zig build stats -- --db data/enwiktionary.bin
```

The first decoder open builds a sidecar cache at `data/enwiktionary.bin.idx`. Later opens mmap that cache and skip the expensive metadata rebuild.

Run the backend server:

```bash
zig build -Doptimize=ReleaseFast serve -- --db data/enwiktionary.bin --port 3000
```

If `data/enwiktionary.bin` does not exist, the backend will build it from `enwiktionary.xml` before serving requests.

## Frontend Commands

Install frontend dependencies:

```bash
zig build frontend-install
```

Build the frontend:

```bash
zig build frontend-build
```

Type-check and build the frontend:

```bash
zig build frontend-check
```

Run the Vite dev server:

```bash
zig build frontend-dev
```

Preview the built frontend:

```bash
zig build frontend-preview
```

The Vite dev server proxies `/api/*` to `http://127.0.0.1:3000`.

## API

The backend exposes:

- `/api/stats`
- `/api/search?q=color&limit=10`
- `/api/lookup/color`
- `/api/random`

The production frontend is served from the same Zig process. Raw English entry formatting is preserved exactly, while lookup indices are rebuilt in memory after load.
