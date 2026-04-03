# Dict

English Wiktionary parsed from the official XML dump into a compact binary format, with:

- a Zig builder and lookup library
- alias and alternate-spelling search
- a Bun API server that reads the same binary directly
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

Run the Bun server against the full dictionary:

```bash
DICT_DB=../data/enwiktionary.bin bun run start
```

The server exposes:

- `/api/stats`
- `/api/search?q=color&limit=10`
- `/api/lookup/color`
- `/api/random`

The frontend is served from the same Bun process.
