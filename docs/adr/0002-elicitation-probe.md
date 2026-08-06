# ADR-002: Elicitation probe — opencode ACP

**Status**: Probe complete, decision deferred.
**Issue**: #6 — iOS 会话视图
**Date**: 2026-08-06

## Context

Issue #6 asked us to probe whether opencode, when run in ACP mode, emits
`elicitation/create` notifications over the `session/update` stream. If it
did, the iOS UI would need a structured question-asking card instead of (or
in addition to) a free-text input bar. If not, a plain input box is enough.

## Method

We inspected two surfaces:

1. **Companion server** (`companion/src/`, `companion/test/`). The companion
   forwards every `session/update` notification verbatim from the ACP agent
   subprocess — it does not filter, rewrite, or special-case any variant.
   Neither the source code nor the mock agent references `elicitation/create`,
   `session/request_permission`, `request_permission`, or `permission`.
2. **iOS client decode path**. `SessionUpdateNotification.init(from:)` decodes
   `update.sessionUpdate` into a known-case enum; anything it does not
   recognise falls through to `.unsupported(String)` and is logged via the
   transcript's no-op path. The transcript silently drops `.unsupported`
   updates and renders nothing.

## Finding

**No `elicitation/create` (or any elicitation variant) has been observed** in
the stream. The opencode ACP mode we are targeting sends these known variants:

| variant | meaning |
|---|---|
| `agent_message_chunk` | streaming agent reply (markdown) |
| `agent_thought_chunk` | streaming agent thought text |
| `user_message_chunk` | echo of user prompt |
| `tool_call` / `tool_call_update` | tool call start / status change |
| `plan` | current plan entries |

Anything else is decoded as `SessionUpdate.unsupported(«raw variant name»)`
and ignored by the transcript. No UI card is rendered.

## Decision — deferred

We are not building an elicitation/structured-question card. The input is a
plain text bar. If opencode ACP starts emitting `elicitation/create` in a
future version, the `.unsupported` catch-all will silently swallow it.

To revisit: add a new case to `SessionUpdate`, a new `TranscriptItem` variant
(or card view), and an input mode on `SessionDetailView` that renders the
elicitation's structured fields instead of the free-text input bar.

## Consequences

- Pro: simpler first-cut UI, no dead code for a feature the agent doesn't use.
- Con: if opencode starts sending elicitation, iOS users won't see the
  structured prompt — they'll only see the agent asking in markdown text.
  Users can still reply via the free-text input, so the conversation is not
  broken; it just isn't pretty.
