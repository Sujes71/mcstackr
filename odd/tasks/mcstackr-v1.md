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

- **S10** — Workspace model: a workspace is one Stackr profile and the UI
  exposes no profile or environment concept. The **Docker** section uses the
  environment named `local`; the **AWS** section uses the first environment
  whose name is not `local`. New workspaces create `local` and `dev`.
- **S11** — Sidebar: brand, workspace dropdown (switch, create, delete), Docker
  and AWS navigation with running / port-forward counts, Docker status footer.
  Delete asks for confirmation and stops the workspace containers (best effort)
  before removing the profile.
- **S12** — Docker header actions: `Restart all` + `Stop all` when something is
  running, `Start all` when nothing runs, plus an add-service icon. Buttons keep
  a single line at any window width.
- **S13** — Service card: one logs affordance; clicking the card opens the
  service editor; actions are `Start` when stopped and `Restart` + `Stop` when
  running.
- **S14** — Service editor: edit image, tag, ports, environment variables and
  volumes (secret-looking values masked with a reveal toggle), delete with
  confirmation. Saving regenerates the compose file; changes apply on the next
  restart.
- **S15** — AWS section: read-only list of port-forwards and local processes for
  the AWS environment, with an explicit empty state; management lands in the
  next slice.
- **S17** — Add-service flow mirrors Stackr: first choose the image (curated
  catalog, Docker Hub search, or manual), then open the same editable form used
  by the editor, prefilled with that image's default ports, environment
  variables and volume target. The service name is derived from the image and
  stays editable.
- **S18** — Delete service is available from the editor (destructive button) and
  from the service card context menu, both with confirmation.
- **S19** — Engine: `GET /api/hub/catalog` exposes the curated catalog; create
  and update service requests accept environment variables and volumes.
- **S16** — Engine endpoints: `GET /envs/{e}` (environment detail),
  `GET /envs/{e}/services/{s}` (service config),
  `PATCH /envs/{e}/services/{s}` (update + regenerate compose),
  `DELETE /profiles/{p}` (delete profile).

Non-goals for this slice: Kubernetes management, DB operations, queues,
MockServer, request collections, git operations.

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
- [x] T12 — Engine: `config.UpdateService` preserves volumes, sync envs and healthcheck while replacing image, tag, ports and env vars; regenerates compose. Evidence: `go build ./...`, `go vet ./...`.
- [x] T13 — Engine: environment detail, service config, service update and profile delete handlers + routes. Evidence: live engine against a temp copy of `~/.stackr`: env detail 200, service 200, PATCH updates tag and env vars, missing service 404, empty image 400, delete profile 204.
- [x] T14 — Swift: workspace-first sidebar with dropdown (switch/create/delete), Docker/AWS navigation and counts. Evidence: `swift build` passes.
- [x] T15 — Swift: Docker header action rules and single-line buttons; service card with one logs affordance and click-to-configure. Evidence: `swift build` passes.
- [x] T16 — Swift: service editor sheet (image, tag, ports, env vars with masked secrets, delete). Evidence: `swift build` passes.
- [x] T17 — Swift: AWS section with port-forward/local-process rows and empty state.
- [x] T18 — Build and boot verification: `./scripts/build-app.sh` OK; app boots, health/profiles/status 200, 3s polling; engine exits with the app.
- [x] T19 — Engine: catalog endpoint, env vars + volumes on create/update, volume replacement in `config.UpdateService`. Evidence: catalog returns 11 entries; add redis with defaults persisted ports+volume; PATCH added a bind mount and env var; compose shows both volumes; delete 200.
- [x] T20 — Swift: shared `ServiceConfigForm` (name, image, tag, ports, env vars, volumes), add-service wizard (Catalog / Docker Hub / Manual → prefilled editable form). Evidence: `swift build` passes.
- [x] T21 — Swift: destructive delete in the editor and card context menu; destructive button style. Evidence: `swift build` passes; app boots and loads the catalog.
- [ ] T10 — Manual UI smoke test on a real desktop session (user to confirm layout and interactions).
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
- **L6 (user feedback after first slice):** (1) there is no button to delete
  profiles; (2) there are three places to see logs, one is enough, and clicking
  a service should open its configuration (image, DB password, environment
  variables) like the original app's `v`; (3) the restart button does not fit
  and wraps to another line; (4) buttons should be start/stop — when running,
  the primary action should restart directly; (5) remove the environment chips
  (`local`, `dev`) — the gray dot turns yellow and misaligns the text;
  (6) no profiles at all: just the Docker view and the AWS view; another project
  is another workspace.
- **L8 (user feedback, verbatim):**
  > 1- No hay un boton para poder eliminar los servicios de docker. 2- El añadir servicio no se parece al de editar, deberiamos reevaluar el como funciona esto actualmente porque deberia funcionar parecido a como funcionaba en el original de staack r, algo como que primero en dockerhub elegimos la imagen o no y una vez que lo elegimos uqe me abarala parte que es como editar no se... pero esta claro que dependiendo el servicio deberia aparecer las configuraciones por defecto y hacerlas editables como haciamos en stackr esto hay que verlo de nuevo. Luegfo es una duda, sguro qeu AWS es lo que hacemos en stackr original cuando hacemos port forward a los servicios qeu tenemos en k8s ? es un buen naming?
- **L9 (decision):** add-service now mirrors the original TUI: source
  (catalog/search/manual) → prefilled config form. Defaults live in the Go
  catalog and are exposed through `GET /api/hub/catalog`. Volumes are part of
  the shared form and of create/update. Service deletion moved to a destructive
  action in the editor plus a card context menu (the TUI binds it to `d`).
  Open question: the AWS section name; the original Stackr treats every
  non-`local` environment as a port-forward/K8s environment, so `AWS` is
  narrower than the concept.
- **L7 (decision):** workspace = Stackr profile, keeping the on-disk schema
  unchanged for CLI compatibility. Docker section = environment `local`; AWS
  section = environments whose name is not `local`. New workspaces create
  `local` + `dev`. Delete workspace stops containers best effort, then removes
  the profile. Assumption: if the user wants per-directory workspaces, the
  engine data layer changes.
