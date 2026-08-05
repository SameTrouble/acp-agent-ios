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