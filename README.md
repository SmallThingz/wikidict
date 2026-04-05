# Dict

English Wiktionary parsed from the XML dump into a compact binary format, with:

- `encoder/`: package root with the encoding library and CLI
- `decoder/`: package root with the loading, indexing, and query library and CLI
- `backend/`: package root with the `zhttp` server
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

All `zig build <command>` entrypoints now fail fast if a required input file is missing. The only exception is the decoder sidecar index file (`.idx`), which is still rebuilt on demand.

`data/wiktionary-structure.json` is now the single source of truth for the virtual `generated/structure_tables.zig` module used by `encode`, `decode`, `serve`, and `verify`. Run `zig build structure` to refresh it explicitly when the dump changes.

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

- `input`: source metadata
- `summary`: high-level structure counts
- `anomalies`: bounded anomaly counts and samples
- `build`: the exact tables and fingerprint used to synthesize the virtual `generated/structure_tables.zig`

Run the backend server:

```bash
zig build -Doptimize=ReleaseFast serve -- --db data/wiktionary.bin --port 3000
```

## Frontend Commands

The frontend now uses a Zig CLI wrapper:

```bash
zig build frontend -- install
zig build frontend -- build
zig build frontend -- check
zig build frontend -- dev
zig build frontend -- preview
```

`build`, `check`, `dev`, and `preview` require existing frontend dependencies. Use `zig build frontend -- install` explicitly when you want to install them.

The Vite dev server proxies `/api/*` to `http://127.0.0.1:3000`.

## API

The backend exposes:

- `/api/stats`
- `/api/search?q=color&limit=10`
- `/api/lookup/color`
- `/api/random`

The production frontend is served from the same Zig process. Raw English entry formatting is preserved exactly, while lookup indices are rebuilt in memory after load.
