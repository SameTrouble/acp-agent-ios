import { readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

/** One navigable directory inside a listing. Files are not listed — the
 * browser only picks project roots (issue #12). */
export interface DirectoryEntry {
  name: string;
  path: string;
}

export interface DirectoryListing {
  /** Absolute path of the listed directory. */
  path: string;
  /** One level up, or `null` at the filesystem root. */
  parent: string | null;
  /** Subdirectories, sorted case-insensitively. */
  entries: DirectoryEntry[];
}

/** Raised for paths that cannot be listed; the server maps it to an
 * InvalidParams error so the client can show the message. */
export class DirBrowseError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DirBrowseError";
  }
}

/**
 * Lists one directory level for the project picker. Without an explicit path
 * the listing starts at `$HOME` (falling back to `/`), so the browser opens
 * somewhere sensible on first use.
 */
export function browseDir(
  rawPath: string | undefined,
  env: NodeJS.ProcessEnv = process.env,
): DirectoryListing {
  const target = rawPath !== undefined ? resolve(rawPath) : defaultRoot(env);

  let isDirectory = false;
  try {
    isDirectory = statSync(target).isDirectory();
  } catch {
    throw new DirBrowseError(`directory not found: ${target}`);
  }
  if (!isDirectory) {
    throw new DirBrowseError(`not a directory: ${target}`);
  }

  let names: string[];
  try {
    names = readdirSync(target);
  } catch (err) {
    const e = err as Error;
    throw new DirBrowseError(`cannot read directory ${target}: ${e.message}`);
  }

  const entries: DirectoryEntry[] = [];
  for (const name of names) {
    const full = join(target, name);
    try {
      if (statSync(full).isDirectory()) {
        entries.push({ name, path: full });
      }
    } catch {
      // broken symlinks / vanished entries are skipped
    }
  }
  entries.sort((a, b) => {
    const la = a.name.toLowerCase();
    const lb = b.name.toLowerCase();
    return la < lb ? -1 : la > lb ? 1 : 0;
  });

  const up = dirname(target);
  return {
    path: target,
    parent: up === target ? null : up,
    entries,
  };
}

function defaultRoot(env: NodeJS.ProcessEnv): string {
  const home = env.HOME;
  if (typeof home === "string" && home.length > 0) {
    try {
      if (statSync(home).isDirectory()) return resolve(home);
    } catch {
      // fall through to root
    }
  }
  return "/";
}
