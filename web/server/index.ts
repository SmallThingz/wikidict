import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { BinaryDictionary } from "./dict";

const rootDir = fileURLToPath(new URL("..", import.meta.url));
const distDir = join(rootDir, "dist");
const dictPath = process.env.DICT_DB ?? join(rootDir, "..", "data", "enwiktionary.bin");
const port = Number(process.env.PORT ?? 3000);

const dictionary = await BinaryDictionary.open(dictPath);

function json(data: unknown, status = 200) {
  return Response.json(data, { status });
}

async function serveStatic(pathname: string) {
  const requestPath = pathname === "/" ? "index.html" : pathname.replace(/^\/+/, "");
  const assetPath = join(distDir, requestPath);
  const file = Bun.file(assetPath);
  if (await file.exists()) {
    return new Response(file);
  }

  const fallback = Bun.file(join(distDir, "index.html"));
  if (await fallback.exists()) {
    return new Response(fallback);
  }

  return new Response(
    "Frontend build not found. Run `bun install && bun run build` in web/ before starting the server.",
    { status: 503 },
  );
}

const server = Bun.serve({
  port,
  async fetch(request) {
    const url = new URL(request.url);
    const pathname = url.pathname;

    if (pathname === "/api/stats") {
      return json(dictionary.stats());
    }

    if (pathname === "/api/random") {
      return json({ word: dictionary.randomWord() });
    }

    if (pathname === "/api/search") {
      const query = url.searchParams.get("q") ?? "";
      const limit = Number(url.searchParams.get("limit") ?? "12");
      return json({
        query,
        suggestions: dictionary.suggest(query, limit),
      });
    }

    if (pathname.startsWith("/api/lookup/")) {
      const term = decodeURIComponent(pathname.slice("/api/lookup/".length));
      return json({
        query: term,
        hits: dictionary.lookup(term),
      });
    }

    return serveStatic(pathname);
  },
});

console.log(`Dictionary server ready on http://localhost:${server.port}`);
console.log(`Dictionary binary: ${dictPath}`);
