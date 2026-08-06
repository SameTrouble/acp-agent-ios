import { readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const DEFAULT_IGNORES = new Set([
  ".git",
  "node_modules",
  "dist",
  "build",
  "out",
  ".next",
  ".nuxt",
  ".cache",
  ".DS_Store",
  "__pycache__",
  ".venv",
  "venv",
  "target",
]);

const MAX_WALK_DEPTH = 50;
const MAX_FILE_COUNT = 50000;

export interface SearchResult {
  path: string;
  score: number;
}

export function searchFiles(cwd: string, query: string, limit = 20): SearchResult[] {
  const files = collectFiles(cwd);
  if (query.length === 0) {
    return files
      .slice(0, limit)
      .map((path) => ({ path, score: 1 }));
  }

  const q = query.toLowerCase();
  const results: SearchResult[] = [];
  for (const path of files) {
    const score = fuzzyScore(path.toLowerCase(), q);
    if (score > 0) {
      results.push({ path, score });
    }
  }

  results.sort((a, b) => b.score - a.score);
  return results.slice(0, limit);
}

function collectFiles(cwd: string): string[] {
  const files: string[] = [];
  const stack: Array<{ dir: string; depth: number }> = [{ dir: cwd, depth: 0 }];

  while (stack.length > 0) {
    const { dir, depth } = stack.pop()!;
    if (depth > MAX_WALK_DEPTH) continue;
    if (files.length >= MAX_FILE_COUNT) break;

    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      continue;
    }

    for (const entry of entries) {
      if (DEFAULT_IGNORES.has(entry)) continue;
      const full = join(dir, entry);
      let isDir = false;
      try {
        isDir = statSync(full).isDirectory();
      } catch {
        continue;
      }
      if (isDir) {
        stack.push({ dir: full, depth: depth + 1 });
      } else {
        const rel = relative(cwd, full);
        files.push(rel);
      }
    }
  }

  return files;
}

function fuzzyScore(path: string, query: string): number {
  if (query.length === 0) return 1;

  const pathLen = path.length;
  const queryLen = query.length;
  if (queryLen > pathLen) return 0;

  if (path.includes(query)) {
    const basename = path.split("/").pop() ?? path;
    const baseMatch = basename.includes(query);
    const prefixMatch = path.startsWith(query);
    const basePrefixMatch = basename.startsWith(query);
    if (basePrefixMatch) return 1000 - pathLen;
    if (prefixMatch) return 900 - pathLen;
    if (baseMatch) return 800 - pathLen;
    return 500 - pathLen;
  }

  let qi = 0;
  let pi = 0;
  let matchedChars = 0;
  let consecutiveBonus = 0;
  let maxConsecutive = 0;

  while (qi < queryLen && pi < pathLen) {
    if (path[pi] === query[qi]) {
      matchedChars++;
      consecutiveBonus++;
      maxConsecutive = Math.max(maxConsecutive, consecutiveBonus);
      qi++;
    } else {
      consecutiveBonus = 0;
    }
    pi++;
  }

  if (qi < queryLen) return 0;

  const basename = path.split("/").pop() ?? path;
  const baseMatchBonus = basename.includes(query[0]!) ? 50 : 0;

  return matchedChars * 10 + maxConsecutive * 5 + baseMatchBonus - pathLen;
}
