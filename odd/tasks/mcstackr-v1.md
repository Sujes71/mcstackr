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
  environment named `local`; the **Port Forwards** section uses the first environment
  whose name is not `local`. New workspaces create `local` and `dev`.
- **S11** — Sidebar: brand, workspace dropdown (switch, create, delete), Docker
  and Port Forwards navigation with running / port-forward counts, Docker status footer.
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
- **S15** — Port Forwards section: read-only list of port-forwards and local processes for
  the port-forward environment, with an explicit empty state; management lands in the
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
- **S20** — One delete pattern everywhere: a red destructive button in the sheet
  footer (left), a native confirmation dialog, and the same placement in the
  service editor and in workspace settings. Workspace deletion lives in
  `Workspace settings…` (description editable via `PATCH /api/profiles/{p}`),
  not in the workspace menu.
- **S21** — Sheet chrome: one close affordance per sheet (the header `x`); no
  duplicate bottom `Cancel`. The add-service back step is a bare `<` icon.
- **S22** — The sidebar shows the full workspace name (no initials) and creation
  caps names at 24 characters, enforced in the UI and by the engine.
- **S25** — Add service browses recent Docker Hub tags (`GET /api/hub/tags`)
  and shows them as selectable chips next to the prefilled tag.
- **S26** — Host-port conflicts are rejected before saving, for add and update,
  with the Stackr CLI message: a host port used by another service, or twice in
  the same service, returns 400.
- **S27** — Deleting a service removes it from the config, removes its container
  (`compose rm -fs`, while the compose file still knows it) and its named
  volumes; deleting the last service writes an empty `services: {}` compose file
  instead of leaving the stale one behind.
- **S28** — "Stop all" stops containers (`compose stop`) instead of `compose
  down`, so it no longer removes them.
- **S29** — The Port Forwards section lists each configured forward with its
  live state (`stopped`/`starting`/`running`/`failed`), `local → remote` and
  `context · namespace/service`, plus per-row start/stop.
- **S30** — Adding a forward is discovery driven: context → namespace →
  service → local port. The local port defaults to the first free port from
  8080 and must be `1..65535` and unused; the forward name is the service name
  and the remote port comes from the service.
- **S31** — Start runs `kubectl port-forward --context <ctx> -n <ns>
  service/<svc> <local>:<remote>`; it is `running` only after surviving 2s,
  fast failures surface kubectl's stderr, and state refreshes while the
  section is open.
- **S32** — Stop stops the subprocess; Start all / Stop all act on every
  forward; deleting stops the forward first; engine shutdown stops every
  child process.
- **S33** — Editing changes the local port only; a running forward restarts
  with the new port.
- **S24** — All sheets share one shell (header with a single close, divider,
  scrolling body, divider, footer) and the same `FormSection` heading: a
  centered, larger title with hairline rules. New workspace, workspace
  settings, service editor and add service use it.
- **S23** — The former AWS section is named **Port Forwards**: the original
  Stackr treats every non-`local` environment as a Kubernetes port-forward
  environment, so the cloud-specific name was misleading.
- **S16** — Engine endpoints: `GET /envs/{e}` (environment detail),
  `GET /envs/{e}/services/{s}` (service config),
  `PATCH /envs/{e}/services/{s}` (update + regenerate compose),
  `DELETE /profiles/{p}` (delete profile).

- **S34** — The Docker header keeps only **Start all** / **Stop all**; the
  global **Restart all** action is gone (restart is stop then start, and the
  per-service restart stays).
- **S35** — The Port Forwards header mirrors Docker: a `LIVE` badge when at
  least one forward is running and a `"N port-forwards · X running"` subtitle.
- **S36** — Local processes belong to the Docker section: they are listed with
  state, PID, command and workdir, can be started/stopped and deleted through
  the standard destructive confirmation. The name is sanitized and must be
  unique against services and other local processes; the command is required.
  Commands run through `sh -c`, so shell syntax works.
- **S39** — One add entry point: the header `+` (and the empty-state button)
  opens a single sheet with a **Service / Local process** switch. There is no
  separate add-process button and no second terminal icon. Local processes use
  the same name, command (via `sh -c`) and optional workdir fields.
- **S41** — Docker renders one card grid: services and local processes share
  the same card anatomy (dot, name, type badge, mono detail, footer actions) and
  the same padding and minimum height. There is no separate "LOCAL PROCESSES"
  section header. The status dot alone conveys state, and every off state
  (`created`, `not_created`, `exited`, `stopped`, `dead`, `failed`, `error`)
  is red, so no "RUNNING"/"STOPPED" text is repeated in cards or port-forward
  rows.
- **S42** — The card badge names the service *category*, not the image: `DB`
  for databases, `QUEUE` for kafka/rabbitmq/activemq, `MOCK` for mockserver,
  `SEARCH` for elasticsearch/opensearch/solr, `CACHE` for
  redis/valkey/memcached, and `PROCESS` for host commands. Unknown images show
  no badge.
- **S40** — Sidebar badges show only what is running: Docker shows the number
  of running services plus local processes, Port Forwards the number of running
  forwards, and nothing at all when the count is zero. The leftover `SOON`
  label is gone.
- **S37** — Each local process runs in its own process group and writes
  `~/.stackr/<profile>/<env>/procs/<name>.pid`. A restarted engine adopts
  processes that are still alive, detects exits on its own, waits up to five
  seconds when stopping, and leaves no children behind on shutdown. Environment
  `up` / `stop` / `down` also start or stop its local processes, and deleting a
  profile stops them.
- **S38** — AWS/EKS is not exercised without the VPN. Port-forward verification
  uses a fake `kubectl`; local processes are verified locally.

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
- [x] T14 — Swift: workspace-first sidebar with dropdown (switch/create/settings/delete), Docker/Port Forwards navigation and counts. Evidence: `swift build` passes.
- [x] T15 — Swift: Docker header action rules and single-line buttons; service card with one logs affordance and click-to-configure. Evidence: `swift build` passes.
- [x] T16 — Swift: service editor sheet (image, tag, ports, env vars with masked secrets, delete). Evidence: `swift build` passes.
- [x] T17 — Swift: Port Forwards section with port-forward/local-process rows and empty state.
- [x] T18 — Build and boot verification: `./scripts/build-app.sh` OK; app boots, health/profiles/status 200, 3s polling; engine exits with the app.
- [x] T19 — Engine: catalog endpoint, env vars + volumes on create/update, volume replacement in `config.UpdateService`. Evidence: catalog returns 11 entries; add redis with defaults persisted ports+volume; PATCH added a bind mount and env var; compose shows both volumes; delete 200.
- [x] T20 — Swift: shared `ServiceConfigForm` (name, image, tag, ports, env vars, volumes), add-service wizard (Catalog / Docker Hub / Manual → prefilled editable form). Evidence: `swift build` passes.
- [x] T21 — Swift: destructive delete in the editor and card context menu; destructive button style. Evidence: `swift build` passes; app boots and loads the catalog.
- [x] T22 — Engine: `PATCH /api/profiles/{p}` for the workspace description; 24-character profile-name limit. Evidence: PATCH 200, long name 400, unknown profile 404.
- [x] T23 — Swift: workspace settings sheet with the shared destructive footer; workspace delete removed from the menu; unified delete button in the service editor; single close affordance; bare `<` back in add-service. Evidence: `swift build` passes.
- [x] T24 — Swift: full workspace name with a 24-character creation limit; AWS renamed to Port Forwards across UI, README and specs. Evidence: `swift build` passes; app boots and loads status + catalog.
- [x] T25 — Swift: extracted `FormSection` and applied it to every form; New workspace and Workspace settings now use the standard sheet shell. Evidence: `swift build` passes; bundle rebuilt.
- [x] T26 — Engine: `GET /api/hub/tags`; UI tag chips in the add-service configure step. Evidence: endpoint 200 with recent tags.
- [x] T27 — Engine: port-conflict validation on add and update. Evidence: duplicate host port 400 with owner, same-service duplicate 400.
- [x] T28 — Engine: service delete removes container + named volumes; last-service delete writes `services: {}`. Evidence: alpha removed from compose, last delete leaves valid empty compose, `/compose` 200.
- [x] T29 — Engine + UI: `stop` env action and "Stop all" uses it. Evidence: `actions/stop` 200, compose unchanged.
- [x] T30 — Engine: copied the Stackr port-forward runtime (start/stop/state, 512-byte stderr ring, 2s fast-fail) and added a per profile+env manager. Evidence: start → running after 2s; kill → failed with `process exited unexpectedly`; shutdown leaves 0 children.
- [x] T31 — Engine: discovery endpoints (`/api/k8s/status|contexts|namespaces|services`). Evidence: fake kubectl returned ctx-a, default/prod and api/web with their ports.
- [x] T32 — Engine: port-forward CRUD + start/stop/start-all/stop-all with validation (name, 1..65535, duplicate name, local-port conflict). Evidence: 201/400/400/400/200/204 as expected; `port_forwards` persisted.
- [x] T33 — Swift: `PortForwardInfo.state/error`, discovery + action methods, 3s state refresh while the section is open.
- [x] T34 — Swift: row state dot + start/stop, editor sheet with local port and red delete, header Start all/Stop all and add.
- [x] T35 — Swift: discovery wizard sheet (context → namespace → service → local port). Evidence: `swift build` and bundle rebuild pass; boot smoke clean.
- [x] T36 — Swift: dropped the global Restart all; Port Forwards header shows the LIVE badge and running count. Evidence: `swift build` and bundle rebuild pass; boot smoke clean.
- [x] T37 — Engine: `localprocess` runtime (process group, PID file, orphan adoption, exit detection, 5s stop) and a per profile+env manager wired into shutdown. Evidence: start/stop/add/delete 201/400/400/400/204; killed process flips to stopped; adopted PID survives an engine SIGKILL and is stopped afterwards; 0 leftovers.
- [x] T38 — Engine: local-process routes, env detail state/pid, env actions start/stop them, profile delete stops them. Evidence: `up` with no services 200 and starts the process; `stop` stops it; duplicate names 400.
- [x] T39 — Swift: Docker section lists local processes with state/pid, start/stop, context-menu delete, 3s refresh. Evidence: `swift build` and bundle rebuild pass; app boots and loads `local` detail.
- [x] T40 — Swift: one `+` opens an add sheet with a Service / Local process switch; removed the section add-process button, the header terminal icon and the standalone process sheet. Evidence: `swift build` and bundle rebuild pass; boot smoke clean.
- [x] T42 — Engine `Service.Kind()` + `kind` in the status DTO; Swift unified card grid, red-off dot, state text removed from service/process/forward rows, category badges. Evidence: `go build`/`go vet` pass; status probe returns `QUEUE`, `DB`, `DB` for activemq/mongo/postgres; `swift build` and bundle rebuild pass; boot smoke clean.
- [x] T41 — Swift: sidebar badges are running-only (services + local processes, forwards) and the `SOON` label is removed. Evidence: `swift build` passes.
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
  (6) no profiles at all: just the Docker view and the Port Forwards view; another project
  is another workspace.
- **L8 (user feedback, verbatim):**
  > 1- No hay un boton para poder eliminar los servicios de docker. 2- El añadir servicio no se parece al de editar, deberiamos reevaluar el como funciona esto actualmente porque deberia funcionar parecido a como funcionaba en el original de staack r, algo como que primero en dockerhub elegimos la imagen o no y una vez que lo elegimos uqe me abarala parte que es como editar no se... pero esta claro que dependiendo el servicio deberia aparecer las configuraciones por defecto y hacerlas editables como haciamos en stackr esto hay que verlo de nuevo. Luegfo es una duda, sguro qeu AWS es lo que hacemos en stackr original cuando hacemos port forward a los servicios qeu tenemos en k8s ? es un buen naming?
- **L10 (user feedback, verbatim):**
  > vale no me gusta el delete, deberiamos tener todos los formularios y botones de delete alineados el delete de workspace es muy distinto al de service, elige un formato chulo y moderno y que todo este alineado. En el configure service no me gusta el boton < change image simplemnte con < creo qeu quedaria mas minimalista y chulo. luego en el add service veo una x arriba para cerrar la ventana y un cancel abajo que hace lo mismo yo quitaria el cancel. y veoque eso lo tienes en create workspace tambien ... Luego en los workspace en vez de poner GL yo pondria entero el nombre del workspace limitado en la creacion para no romper la uix porque no quepa .
  >
  > respecto a kubernetes renombralo portforward que se sepa para que sirve al final
  >
  > o algo similar que lo deje clarisimo
- **L14 (user request, verbatim):**
  > Vale muy bien, revisa si nos falta algo mas y si esta todo ya perfecto y no nos dejamos ninguna funcionalidad hasta donde vamos que este en stackr pasamos a lo siguiente
- **L15 (audit outcome):** read-only audit against Stackr found four real gaps
  in the current slice (tag browsing, port-conflict validation, delete not
  removing containers/volumes, Stop all using `compose down`) plus one bug
  found while verifying (deleting the last service left a stale compose file).
  All five are fixed above. Known deliberate divergences: no env switcher
  (workspace model), no local-process creation, port-forward runtime state
  deferred with the Port Forwards slice.
- **L12 (user feedback, verbatim):**
  > en new workspace misma logca y en generl en todos los formularios hay que estandarizar
- **L13 (decision):** form standardization: `FormSection` (centered title +
  hairline rules) is shared, and every sheet follows the same shell and footer
  placement. New workspace was rebuilt on that shell.
- **L11 (decision):** delete is now one pattern: red destructive button on the
  left of a sheet footer plus a native confirmation, used by the service editor
  and by the new workspace settings sheet (workspace delete left the dropdown).
  Every sheet has a single close affordance. The add-service back affordance is
  a bare `<`. Workspace names show in full and are capped at 24 characters.
  The AWS section is renamed Port Forwards (Kubernetes port-forwards for every
  non-`local` environment).
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

- **L16 (user request, verbatim):**
  > Vale tiene buenaa pinta. Podemos pasar a desarrollar lo siguiente recuerda que tienes stackr como referencia
- **L18 (user request, verbatim):**
  > ademas en docker señalamos los ue estan running pero en forward no estamos informando eso, que las ventanas esten alineadas en las vistas en ese sentido pero muy bien
  >
  > ya añadi el aws por si quieres echarle un vistazo por si ves algo
  >
  > una vez ajustes eso pasa a lo siguiente
- **L19 (user constraint, verbatim):**
  > te corte porque veo que esstas orobando creo cosas contra aws pero sin la vpn n funciona asi que no pierdas el tiempo probando eso
- **L21 (user request, verbatim):**
  > en docker veo el boton add process abajo y luego arriba el icono de una consola que hace lo mismo yo lo que haria seria uitar ambos bnotones y que el + que actualmente te crea un servicio deberia manehjar ambos casos al darle esta en add service pero deberia haber un boton que me cambie entre add service y add process
  >
  > en el nav de la izquierda donde esta docker y port forward en docker no veo nada de cuantos hay creado a la derecha y en el otro si decidete o me lo muestras en todos o no me lo muestras. lo ideal es uqe no aparezca nada y solo aparezcan cuando esten running creo
- **L23 (user request, verbatim):**
  > en docker veo qiue la luz que indica que esta encendido o apagado no es la misma en local que en services pon la de local en todos la roja para off ademas el formato no esta alineado me pones stopped al lado del localproces lo cual es estupido porque la luz me lo dice ya lo mismo con los services para que quiero ver el running si ya tengo la luz que indica el estado encima. Otra cosa en los services es que me pones una especie de etiqueta arriba a al derecha del contenedor que pone por ejemplo (MONGO) al lado el titulo que ya de normal si es una mongo será mongo. encima en la activemq no pones eso asi que mejor ahi pondremos simplemente lo que es , si es una mongo postgre u otra base de datos BD, si es activemq kafka etc.. QUEUE si es un mockserver pues lo que sea elasticsearch pues lo que corresponda o sea indicaremos el tipo mas que quje es porque puede resultar redundante. en forward lo mism que ne local process quita lo de stopped en pequeño con la luz es suficiente. En docker otra cosa veo que me pusiste una seccion para local proceses pero no veo la seccion de services encima el formato de como se ven es muy diferente deberian ser similares no? o quizas no deberiamos separarlos en sercciones no lo se.. no lo termino de ver claro.
- **L24 (decision):** one unified grid — services and local processes are cards
  with identical anatomy, no section headers. Dot color is the only state
  signal and every off state is red. Badges now carry the category (`DB`,
  `QUEUE`, `MOCK`, `SEARCH`, `CACHE`, `PROCESS`), so a `mongo` card reads `DB`
  and the activemq card reads `QUEUE` instead of being the only one labelled.
- **L22 (decision):** both notes applied. The add sheet is now one flow with a
  segmented Service / Local process switch in its header; the section button,
  the header terminal icon and the standalone process sheet are gone. Sidebar
  badges show only running counts and disappear at zero, in both sections.
- **L20 (decision):** the header alignment shipped first (no global Restart
  all, LIVE badge + running count in Port Forwards). The next slice is local
  processes, not the Kubernetes manager: local processes are fully verifiable
  without the VPN and they were already present in the config but invisible in
  the UI. Runtime copies Stackr semantics (own process group, PID files under
  `procs/`, orphan adoption, 5s stop); divergences: no log capture, no editor
  for an existing process (delete and re-add). Environment `up`/`stop`/`down`
  also act on them, like the TUI's `s`/`x`. The AWS/EKS cluster is never probed
  without the VPN.
- **L17 (decision):** the next slice is Port Forwards management, mirroring the
  original runtime exactly: `kubectl port-forward --context <ctx> -n <ns>
  service/<svc> <local>:<remote>`, `running` only after 2s, last 512 bytes of
  stderr kept for failures, and a per profile+env handle registry so one engine
  can serve every workspace. Adding is discovery driven and only the local port
  is editable afterwards (same as the TUI). Local processes stay read-only in
  this slice; they belong to the Docker/local-process work. Divergence: the
  original has no "open in browser" action, so none was added.
