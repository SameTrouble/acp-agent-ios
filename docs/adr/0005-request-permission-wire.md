# ADR-005: request_permission wire — live-verified (opencode 1.18.13)

**Status**: Accepted.
**Issue**: #22 — request_permission wire observation + elicitation final check
**Date**: 2026-08-06

## Context

Issue #7 (approval cards) needs the real wire shape of opencode's
permission request before the companion can relay it and the iOS app can
render it. ADR-002 deferred its elicitation question to this same live
probe. This ADR records the reproducible observations from real sessions
against the installed binary (opencode 1.18.13) via
`companion/scripts/observe-wire.ts`.

## Method

`bun run scripts/observe-wire.ts <cwd> <out.jsonl>` drives one full
session (initialize → authenticate → session/new → session/prompt) and
dumps every JSON-RPC frame. Six sessions were run:

1. default config, `pwd` (safe command) — no permission request
2. default config, `curl` bash command — no permission request
3. default config, write file — no permission request
4. config with `permission: {bash/edit/webfetch/websearch: "ask"}`,
   `curl` — `session/request_permission` observed; replied `allow_once`
   → tool executed (conclusion taken from a clean rerun; an earlier run
   with a probe bug that replied repeatedly was discarded)
5. same ask config, `curl`, replied `rejected` → tool failed
6. config without any `permission` field, read `/etc/hosts` (outside
   cwd) — `session/request_permission` (external_directory, default
   ask); replied `allow_once` → tool executed

To reproduce the ask scenarios, run with a temp config directory
(`XDG_CONFIG_HOME`) containing an `opencode/opencode.json` like:

```json
{
  "permission": { "bash": "ask", "edit": "ask", "webfetch": "ask", "websearch": "ask" }
}
```

Scenario 6 needs the same file without a `permission` field; the repo's
local config (`~/.config/opencode/opencode.json`) sets
`external_directory: {"/**": "allow"}`, which suppresses the
`external_directory` request — that is why scenarios 1–3 never asked.

## Finding

### Wire shape

The method name is the standard ACP one, **`session/request_permission`**,
sent as a JSON-RPC **request** (has an `id`) from agent to client:

```json
{
  "jsonrpc": "2.0",
  "id": 0,
  "method": "session/request_permission",
  "params": {
    "sessionId": "ses_...",
    "toolCall": {
      "toolCallId": "call_...",
      "title": "curl -s https://example.com | head -3",
      "kind": "execute",
      "status": "pending",
      "locations": [],
      "rawInput": { "command": "curl -s https://example.com | head -3" }
    },
    "options": [
      { "optionId": "once", "kind": "allow_once", "name": "Allow once" },
      { "optionId": "always", "kind": "allow_always", "name": "Always allow" },
      { "optionId": "reject", "kind": "reject_once", "name": "Reject" }
    ]
  }
}
```

Notes:

- `id` is a per-connection counter starting at **0** (SDK
  `@agentclientprotocol/sdk@0.21.0`, `nextRequestId`), independent of the
  client→agent request id space. It is not a fixed value.
- `toolCall.kind` varies: `execute` (bash), `other` + populated
  `locations` for `external_directory` requests
  (`{"path": "/etc/hosts"}, {"path": "/etc"}`), and per source code
  `read`/`edit` with a `content: [{type: "diff", ...}]` preview for
  edits.
- `rawInput` carries the tool's original input (e.g. `command`, or
  `filepath`/`parentDir`).

### Response expectations

The client replies to the same `id` with one of:

```json
{ "jsonrpc": "2.0", "id": 0, "result": { "outcome": { "outcome": "selected", "optionId": "once" } } }
{ "jsonrpc": "2.0", "id": 0, "result": { "outcome": { "outcome": "selected", "optionId": "always" } } }
{ "jsonrpc": "2.0", "id": 0, "result": { "outcome": { "outcome": "rejected" } } }
```

Verified behaviour:

- `selected`/`once` → `tool_call_update` `status: "completed"`, tool runs.
- `rejected` → `tool_call_update` `status: "failed"` with content
  `"The user rejected permission to use this specific tool call."`;
  the agent explains and ends the turn normally.
- Anything else (or an error reply) is treated as reject by opencode.

### When does opencode actually ask?

opencode's permission defaults are **permissive**: most tools default to
`allow`; only `doom_loop` and `external_directory` default to `ask`
(https://opencode.ai/docs/permissions/). Observed consequences:

- With the repo's default config (no `bash`/`edit` rules), bash commands
  and file writes run **without** any permission request.
- Setting `permission: {"bash": "ask", ...}` makes bash ask.
- Accessing paths outside the session cwd triggers
  `external_directory` requests even with no explicit rules (unless
  `external_directory` is configured allow, as the current local config
  does with `"/**": "allow"`).

So the approval card is live only when the user configures tools to
`ask`; the wire itself is verified working for all three options.

### Elicitation final check (closes ADR-002's deferral)

No `elicitation/create` or any elicitation variant appeared in any of
the sessions. ADR-002's deferral is resolved: no elicitation card is
built.

### Unknown / new variants observed

Two `session/update` variants not in ADR-002's table were observed:

- `available_commands_update` — slash-command list pushed after
  `session/new` (and on load/resume).
- `usage_update` — `{used, size, cost}` token accounting.

Both are **real, observed variants**, so per ADR-003 they must eventually
be decoded structurally rather than falling to `.unsupported`; decoding
landing in a follow-up ticket is flagged here so this ADR does not
silently override ADR-003. Today iOS decodes both by name only
(`.unsupported`) and drops them.

Also observed, and worth fixing alongside #7: `tool_call_update` uses
`status: "in_progress"` / `"failed"`, but iOS `ToolCallStatus` only
models `pending|running|completed|error` — both values currently decode
to `.pending` (an in-flight card never completes, a rejected card never
shows failure). `session/new`'s result also carries `configOptions`
(model/mode selection); the companion and iOS currently ignore it.

## Consequences

- #7's companion work must relay **agent-side JSON-RPC requests**:
  `AcpClient.handleFrame` currently drops any frame that is neither a
  response nor a notification — `session/request_permission` never
  reaches WebSocket clients. The companion needs a request
  relay/response round-trip path.
- #7's iOS work has the exact wire shape above for the approval card;
  it must also handle `failed`/`in_progress` tool statuses (see ADR-003:
  decode known variants even when unrendered).
- Elicitation remains absent; no card needed (ADR-002 closed).
- Reproduce/diff across opencode versions with
  `companion/scripts/observe-wire.ts` (JSONL dump + variant summary).
