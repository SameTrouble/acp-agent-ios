/**
 * Kept in sync with the `version` field in package.json by hand; the value
 * is embedded in the compiled binary at build time, so it must not depend on
 * reading package.json at runtime.
 */
const VERSION = "0.1.0";

export function isVersionRequest(args: string[]): boolean {
  const first = args[0];
  return first === "--version" || first === "-v";
}

export function versionLine(): string {
  return `acp-agent-companion ${VERSION}`;
}
