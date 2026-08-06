# ADR-001: Core / UI split in ACPAgentKit

**Status**: In effect from #5.
**Date**: 2026-08-06

## Context

The iOS side of this repo ships an app (under `ios/App/`) and a Swift Package
(`ios/ACPAgentKit/`). The package has two source folders:
`Sources/ACPAgentCore/` and `Sources/ACPAgentUI/`.

## Decision

All wire-protocol logic, state models, and the `ACPClient` controller live in
`ACPAgentCore`. SwiftUI views live in the app target (not in `ACPAgentUI`).
The `ACPAgentUI` folder is reserved for reusable UI components if a second
target ever needs them.

The seam between them is the `ACPClient` ObservableObject, vended to views
via `@EnvironmentObject`. Views read published state and call public methods;
they never reach into `JsonRpcClient` or `WebSocketTransport` directly.

## Consequences

- Core is fully testable without hosting a SwiftUI app.
- Views are thin — they translate published state into SwiftUI rendering.
- The `ACPAgentUI` target stays empty for now; adding components there is a
  separate decision, not something this ADR pre-judges.
