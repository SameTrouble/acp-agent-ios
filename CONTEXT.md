# ACP iOS Companion Client

The iOS app and `ACPAgentKit` package that let a user watch and drive
coding-agent sessions over the ACP wire protocol, relayed by a companion
server.

## Language

**Session**:
A server-side conversation thread with the agent, identified by `sessionId`.
_Avoid_: chat, thread

**Conversation**:
The client-side state of one session: its transcript, resume cursor, and
in-flight flags. Owned exclusively by `ConversationStore`.
_Avoid_: chat, dialogue, room

**Transcript**:
The render-ready timeline of message bubbles and tool call cards
accumulated from session updates. Pure accumulation logic, no I/O.
_Avoid_: history, log, feed

**Session update**:
A single server-pushed event in the `session/update` stream (message
chunk, tool call delta, plan, ...).
_Avoid_: event, message, notification (that is the JSON-RPC envelope)

**Tool call card**:
The single merged view of one tool call, folded from its `tool_call` and
`tool_call_update` deltas keyed by `toolCallId`.
_Avoid_: tool event, tool message

**Cursor**:
The position in the server's buffered event stream up to which a
conversation has consumed; sent on resume to fetch only missed events.
_Avoid_: offset, marker

**ConversationStore**:
The Core component that owns all per-session conversation state and the
conversation actions (resume, send, cancel, and future approvals).
`ACPClient` delegates to it and remains the only view-facing seam.
_Avoid_: controller, manager, SessionConversationController

**Unsupported variant**:
A `sessionUpdate` wire type the client does not recognise. Decoded by
name only and silently dropped from the transcript; expected to be rare
per ADR-002/003.
_Avoid_: unknown event, error
