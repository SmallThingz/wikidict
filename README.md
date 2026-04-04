# Dict

English Wiktionary parsed from the official XML dump into a compact binary format, with:

- a Zig builder and lookup library
- alias and alternate-spelling search
- a Zig `zhttp` API server
- a SolidJS web UI

## Build The Dictionary

Use the local XML dump:

```bash
zig build -Doptimize=ReleaseFast run -- build \
  --input enwiktionary.xml \
  --output data/enwiktionary.bin
```

Useful smaller test build:

```bash
zig build run -- build \
  --input enwiktionary.xml \
  --output data/test.bin \
  --limit 500
```

## Zig CLI

Lookup:

```bash
zig build run -- lookup --db data/enwiktionary.bin --word color
```

Suggestions:

```bash
zig build run -- suggest --db data/enwiktionary.bin --prefix colo --limit 10
```

Stats:

```bash
zig build run -- stats --db data/enwiktionary.bin
```

## Web UI

Install dependencies:

```bash
cd web
bun install
```

Build the frontend:

```bash
bun run build
```

Run the Zig server against the full dictionary:

```bash
zig build -Doptimize=ReleaseFast run -- serve --db data/enwiktionary.bin --port 3000
```

For local frontend development, run Vite separately:

```bash
bun run dev
```

The Vite dev server proxies `/api/*` to `http://127.0.0.1:3000`.

The Zig server exposes:

- `/api/stats`
- `/api/search?q=color&limit=10`
- `/api/lookup/color`
- `/api/random`

The production frontend is served from the same Zig process. Raw English entry formatting is preserved exactly; derived lookup data is rebuilt in memory after load rather than stored on disk.
