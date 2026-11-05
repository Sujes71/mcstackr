# MCStackr v1

Native macOS app for Stackr. SwiftUI presentation layer over a local Go engine
that reuses the Stackr domain packages. Test runner: none for this slice (see L3).

## Specs

- **S1** — Create the project at `/Users/zedven/IdeaProjects/mcstackr`.
- **S2** — Native macOS app named MCStackr: SwiftUI UI plus a local Go engine.
  Buildable with Command Line Tools only, no Xcode project required.
- **S3** — Share state with the existing Stackr CLI: both read and write
  `~/.stackr/config.yaml` (profiles, environments, services, encrypted passwords).
- **S4** — Profiles: list profiles and their environments; create a profile with
  name, optional description and 1–5 environments; select profile and environment.
- **S5** — Docker services: merged config + live container status; start, stop
  and restart per service and per environment; live log streaming; add and
  delete services.
- **S6** — Docker Hub image search inside the add-service flow.
- **S7** — Engine contract: loopback-only HTTP API protected by an ephemeral
  bearer token; the app owns the engine process and the engine exits when the
  app exits.
- **S8** — Interface: dark, high-contrast, native macOS look with status
  semantics for running / stopped / not created / unhealthy.
- **S9** — Tests are explicitly skipped for this slice by user instruction.

Non-goals for this slice: Kubernetes, DB operations, queues, MockServer,
request collections, git operations.

## Tasks

- [x] T1 — Engine scaffold: copy Stackr domain packages (config, crypto, docker, hub), rewrite module path. Evidence: `engine/go.mod`, `go build ./...` OK.
- [x] T2 — Engine HTTP API with token auth, config store, status merge, lifecycle actions, SSE logs, Hub search, images, Docker launch. Evidence: `/api/health` and `/api/profiles` returned real data from `~/.stackr`.
- [x] T3 — SwiftUI shell: app entry, engine runtime/handshake, client, theme and components.
- [x] T4 — Profiles UI: sidebar, environment selection, create-profile sheet.
- [x] T5 — Services UI: header actions, status grid, service cards with lifecycle actions, Docker-offline banner.
- [x] T6 — Logs sheet with live SSE stream.
- [x] T7 — Add/delete service flow with Docker Hub search.
- [x] T8 — Build pipeline: `scripts/build-app.sh`, Makefile, Info.plist, ad-hoc signing.
- [x] T9 — Build verification: `go build ./...` and `swift build` pass; app bundle produced.
- [ ] T10 — Manual UI smoke test on a real desktop session.
- [ ] T11 — Next slice: Kubernetes port-forward and resource manager.

## Log

- **L1 (user request, verbatim):**
  > saltemos los tests empieza
  >
  > crea en ideaprojects la carpeta del proyecto al que llamaremos mcstackr
  >
  > y ponte a implementarlo
- **L2 (decision):** UI = SwiftUI; engine = Go. The Swift layer is presentation
  only; domain logic stays in Go and is shared with the CLI through `~/.stackr`.
  Transport: loopback HTTP + bearer token, handshake over stdout.
- **L3 (exception):** tests skipped for this slice by explicit user request.
  Functional proof for this slice is `go build ./...`, `swift build`, a live
  engine smoke test against the real config, and the app bundle build.
- **L4 (scope):** first slice covers profiles + Docker services + logs + Hub
  search. Kubernetes, DBOps, queues, mocks, requests and git follow.
- **L5 (bugfix):** Boot hung forever on "STARTING LOCAL ENGINE". Root cause:
  `FileHandle.read(upToCount:)` on the engine's stdout pipe blocked even though
  the handshake bytes were in the pipe — reproduced with a standalone Swift
  harness (`/bin/echo` returns, the long-lived engine does not); the 10s deadline
  could not fire because it was a blocked synchronous read. Fix: read with
  `availableData` (returns as soon as any bytes arrive) and enforce the deadline
  by terminating the engine on timeout, which closes the pipe. Also retained the
  stdin `Pipe` explicitly so it cannot deallocate. Added opt-in request logging
  (`MCSTACKR_DEBUG=1`) to the engine. Verified: health, profiles and status are
  requested, then 3s polling continues, which only happens after boot phase
  `.ready`; engine still exits with the app.
