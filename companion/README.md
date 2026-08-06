# acp-agent companion

A Bun/TypeScript server that bridges WebSocket clients to [opencode](https://opencode.ai)
running as an [ACP](https://agentclientprotocol.com) subprocess. Part of the
`acp-agent-ios` project (issue #1: companion 骨架：auth + ACP 桥).

## What it does

- Spawns `opencode acp` as a child process and completes the ACP
  `initialize` / `authenticate` handshake.
- Exposes a WebSocket JSON-RPC endpoint. The connection's first message must be
  an `auth` request with a token from the config's multi-token array.
- After auth, session methods (`session/new`, `session/prompt`, `session/cancel`,
  …) are passed through to the agent.
- `session/update` notifications emitted by the agent are broadcast to every
  authenticated connection, so multiple devices stay in sync.
- Disconnecting a client does not interrupt the session or the agent subprocess.
- `files.search` gives clients fuzzy file search scoped to a session's working
  directory, so `@`-mentions can be autocompleted on the device.
- `@`-references in a prompt are expanded by the companion before the prompt
  reaches the agent, in whichever form that agent can actually consume.

## File references (`@`-mentions)

Clients don't send file contents. They send a `file_ref` block naming a path
relative to the session's `cwd`, and the companion resolves it:

```json
{
  "jsonrpc": "2.0", "id": 3, "method": "session/prompt",
  "params": {
    "sessionId": "sess_abc",
    "prompt": [
      { "type": "text", "text": "compare " },
      { "type": "file_ref", "path": "src/server.ts" },
      { "type": "text", "text": " with " },
      { "type": "file_ref", "path": "src/acp.ts" }
    ]
  }
}
```

Which ACP block a `file_ref` becomes depends on what the agent declared during
`initialize`:

| Agent declares | `file_ref` becomes | Agent gets |
| --- | --- | --- |
| `promptCapabilities.embeddedContext: true` | `resource` | the file's text inline |
| anything else | `resource_link` | a `file://` URI to read itself |

The companion reads that capability in one place
(`agentSupportsEmbeddedContext` in `src/server.ts`), so adding a second agent
means adding a capability check there, not a second expansion path. Independently
of the capability, a `file_ref` degrades to `resource_link` when the file is
missing, unreadable, larger than 1 MiB, or resolves outside the session's `cwd` —
a `../` escape is answered with a link and nothing is read.

Non-`file_ref` blocks pass through untouched, so text and file references stay
interleaved in the order the user typed them.

## `files.search`

```json
{ "jsonrpc": "2.0", "id": 2, "method": "files.search",
  "params": { "sessionId": "sess_abc", "query": "srvr", "limit": 20 } }
```

Returns `{ "files": [{ "path": "src/server.ts", "score": 812 }, …] }`, ranked
best-first. Paths are relative to the session's `cwd`. Matching is substring
first, then subsequence, with basename and prefix hits ranked above deep-path
hits. `.git`, `node_modules`, `dist`, and similar build/vendor directories are
skipped, and the walk is bounded so a large repository can't hang the search.

## Configuration

Config lives at `$XDG_CONFIG_HOME/acp-agent/companion.json` (defaults to
`~/.config/acp-agent/companion.json`). See `config.example.json`:

```json
{
  "host": "0.0.0.0",
  "port": 8787,
  "tokens": ["replace-me-with-a-real-token"],
  "agent": { "command": "opencode", "args": ["acp"] }
}
```

`tokens` is a non-empty array of client tokens. `agent.command`/`agent.args`
override the agent process (useful for testing with a mock).

## Run

```sh
bun install
bun run start /path/to/companion.json
```

## Test

```sh
bun run typecheck
bun test
```

The suite spins up the server against a mock agent (`test/helpers/mock-agent.ts`)
and exercises auth, passthrough, broadcast, and disconnect behaviour.