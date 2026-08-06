import { readFile, stat } from "node:fs/promises";
import { basename, relative, resolve, sep } from "node:path";

export interface FileRefBlock {
  type: "file_ref";
  path: string;
}

export interface ResourceBlock {
  type: "resource";
  resource: {
    uri: string;
    mimeType?: string;
    text: string;
  };
}

export interface ResourceLinkBlock {
  type: "resource_link";
  uri: string;
  name: string;
  mimeType?: string;
  size?: number;
}

export type ContentBlock = ResourceBlock | ResourceLinkBlock | Record<string, unknown>;

// Beyond this, embedding the file would bloat the prompt more than it helps, so
// the agent gets a link and can read the parts it actually needs.
const MAX_EMBED_SIZE = 1024 * 1024;

const MIME_TYPES = new Map<string, string>([
  [".ts", "text/typescript"],
  [".tsx", "text/typescript"],
  [".js", "text/javascript"],
  [".jsx", "text/javascript"],
  [".json", "application/json"],
  [".md", "text/markdown"],
  [".txt", "text/plain"],
  [".html", "text/html"],
  [".css", "text/css"],
  [".py", "text/x-python"],
  [".go", "text/x-go"],
  [".rs", "text/x-rust"],
  [".c", "text/x-c++"],
  [".h", "text/x-c++"],
  [".cpp", "text/x-c++"],
  [".hpp", "text/x-c++"],
  [".java", "text/x-java"],
  [".rb", "text/x-ruby"],
  [".php", "text/x-php"],
  [".sh", "text/x-shellscript"],
  [".bash", "text/x-shellscript"],
  [".zsh", "text/x-shellscript"],
  [".yaml", "text/yaml"],
  [".yml", "text/yaml"],
  [".toml", "text/toml"],
  [".ini", "text/plain"],
  [".cfg", "text/plain"],
  [".sql", "text/x-sql"],
  [".swift", "text/x-swift"],
  [".kt", "text/x-kotlin"],
  [".dart", "text/x-dart"],
  [".vue", "text/vue"],
  [".svelte", "text/svelte"],
]);

export function isFileRefBlock(block: unknown): block is FileRefBlock {
  if (typeof block !== "object" || block === null) return false;
  const b = block as Record<string, unknown>;
  return b.type === "file_ref" && typeof b.path === "string";
}

/**
 * Replaces every `file_ref` block with the richest ACP block the agent can
 * consume, leaving all other blocks in place so text and references stay
 * interleaved in the order the user typed them.
 */
export async function expandPrompt(
  prompt: unknown[],
  cwd: string,
  embeddedContext: boolean,
): Promise<ContentBlock[]> {
  const expanded = await Promise.all(
    prompt.map((block) =>
      isFileRefBlock(block)
        ? expandFileRef(block, cwd, embeddedContext)
        : Promise.resolve(block),
    ),
  );
  return expanded.filter((block): block is ContentBlock => typeof block === "object" && block !== null);
}

async function expandFileRef(
  ref: FileRefBlock,
  cwd: string,
  embeddedContext: boolean,
): Promise<ContentBlock> {
  const fullPath = resolve(cwd, ref.path);
  const mimeType = guessMimeType(fullPath);
  const link: ResourceLinkBlock = {
    type: "resource_link",
    uri: `file://${fullPath}`,
    name: basename(fullPath),
    ...(mimeType !== undefined ? { mimeType } : {}),
  };

  // A reference is only ever allowed to name a file inside the session's own
  // working directory; `../` escapes are answered with a link and nothing read.
  if (!isInside(cwd, fullPath)) return link;

  let size: number;
  try {
    size = (await stat(fullPath)).size;
  } catch {
    return link;
  }

  if (!embeddedContext || size > MAX_EMBED_SIZE) {
    return { ...link, size };
  }

  let text: string;
  try {
    text = await readFile(fullPath, "utf-8");
  } catch {
    return { ...link, size };
  }

  return {
    type: "resource",
    resource: {
      uri: link.uri,
      ...(mimeType !== undefined ? { mimeType } : {}),
      text,
    },
  };
}

function isInside(cwd: string, fullPath: string): boolean {
  const rel = relative(resolve(cwd), fullPath);
  return rel.length > 0 && !rel.startsWith(`..${sep}`) && rel !== "..";
}

function guessMimeType(path: string): string | undefined {
  const name = basename(path);
  const dot = name.lastIndexOf(".");
  if (dot <= 0) return undefined;
  return MIME_TYPES.get(name.slice(dot).toLowerCase());
}
