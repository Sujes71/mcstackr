# MCStackr

Native macOS app for the Stackr environment manager. Same domain, same config,
same power — with a real UI.

MCStackr is a SwiftUI front end over a local Go engine. Both the app and the
existing `stackr` CLI read and write `~/.stackr/config.yaml`, so services and
encrypted credentials are shared.

The UI is workspace-first. A **workspace** maps to one Stackr profile and has
two sections:

- **Docker** — the environment named `local`: compose services, live status,
  logs and lifecycle actions, plus host commands (`local_processes`) that run
  on your Mac.
- **Port Forwards** — every other environment (`dev`, `staging`, …): Kubernetes
  port-forwards and cloud workloads. Forwards are discovered from kubeconfig and
  managed with kubectl.

## Architecture

```
MCStackr.app
├── Contents/MacOS/MCStackr        SwiftUI presentation layer
└── Contents/MacOS/mcstackr-engine Go engine (HTTP on 127.0.0.1, bearer token)
```

- The app spawns the engine, reads its handshake from stdout
  (`MCSTACKR_READY <port> <token>`) and keeps its stdin open. If the app dies,
  the engine exits with it.
- The engine never listens on a public interface and rejects requests without
  the ephemeral bearer token.
- All Docker work still shells out to `docker compose`, exactly like the CLI.
  Nothing is reimplemented in Swift.

## Requirements

- macOS 14+
- Docker (Docker Desktop or Colima) for anything container related
- Go 1.22+ and Swift 5.9+ / Command Line Tools to build

Xcode is not required.

## Build and run

```bash
make run       # builds the engine + app bundle and opens it
make app       # build only -> build/MCStackr.app
make engine    # engine binary only -> build/mcstackr-engine
make clean
```

The app bundle embeds both binaries:

```
build/MCStackr.app/Contents/MacOS/MCStackr
build/MCStackr.app/Contents/MacOS/mcstackr-engine
```

Engine logs: `~/Library/Logs/MCStackr/engine.log`.

## API (v1)

All routes require `Authorization: Bearer <token>`.

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/health` | engine version, Docker availability, config path |
| GET | `/api/profiles` | profiles with environments |
| POST | `/api/profiles` | create a profile (workspace) |
| DELETE | `/api/profiles/{p}` | delete a profile (best-effort container stop) |
| POST | `/api/profiles/{p}/envs` | add an environment |
| GET | `/api/profiles/{p}/envs/{e}` | environment detail (port-forwards, processes) |
| GET | `/api/profiles/{p}/envs/{e}/status` | merged config + container status |
| GET | `/api/profiles/{p}/envs/{e}/compose` | generated compose YAML |
| GET | `/api/profiles/{p}/envs/{e}/logs` | SSE log stream |
| POST | `/api/profiles/{p}/envs/{e}/actions/{up,stop,down,restart}` | environment lifecycle |
| POST | `/api/profiles/{p}/envs/{e}/services` | add a service |
| GET | `/api/profiles/{p}/envs/{e}/services/{s}` | service config (image, ports, env) |
| PATCH | `/api/profiles/{p}/envs/{e}/services/{s}` | update a service and regenerate compose |
| DELETE | `/api/profiles/{p}/envs/{e}/services/{s}` | remove a service |
| POST | `/api/profiles/{p}/envs/{e}/services/{s}/actions/{up,stop,down,restart}` | service lifecycle |
| GET | `/api/profiles/{p}/envs/{e}/services/{s}/dbops` | sync environments, actions and dumps for a DB service |
| POST | `/api/profiles/{p}/envs/{e}/services/{s}/dbops/{export-schema,export-data,import-schema,import-data,truncate}` | start a DB operation job |
| GET | `/api/profiles/{p}/envs/{e}/services/{s}/dbops/jobs/{id}` | DB operation job state |
| POST | `/api/profiles/{p}/envs/{e}/services/{s}/sync-envs` | add a sync environment (password encrypted at rest) |
| PATCH | `/api/profiles/{p}/envs/{e}/services/{s}/sync-envs/{name}` | update or rename one; omit `password` to keep it |
| DELETE | `/api/profiles/{p}/envs/{e}/services/{s}/sync-envs/{name}` | remove one (dumps stay on disk) |
| POST | `/api/profiles/{p}/envs/{e}/services/{s}/sync-envs/{name}/custom-actions` | add a custom action (`name`, `command`) |
| PATCH | `/api/profiles/{p}/envs/{e}/services/{s}/sync-envs/{name}/custom-actions/{action}` | update or rename one |
| DELETE | `/api/profiles/{p}/envs/{e}/services/{s}/sync-envs/{name}/custom-actions/{action}` | remove one |
| POST | `/api/profiles/{p}/envs/{e}/services/{s}/dbops/custom/{action}` | run a custom action job (`syncEnv`, `params`) |
| POST | `/api/profiles/{p}/envs/{e}/local-processes` | add a host command |
| DELETE | `/api/profiles/{p}/envs/{e}/local-processes/{name}` | stop and delete a host command |
| POST | `/api/profiles/{p}/envs/{e}/local-processes/{name}/actions/{start,stop}` | one host command |
| POST | `/api/profiles/{p}/envs/{e}/local-processes/actions/{start,stop}` | every host command in the environment |
| POST | `/api/profiles/{p}/envs/{e}/port-forwards` | add a port-forward |
| PATCH | `/api/profiles/{p}/envs/{e}/port-forwards/{name}` | change its local port |
| DELETE | `/api/profiles/{p}/envs/{e}/port-forwards/{name}` | stop and delete a port-forward |
| POST | `/api/profiles/{p}/envs/{e}/port-forwards/{name}/actions/{start,stop}` | one forward |
| POST | `/api/profiles/{p}/envs/{e}/port-forwards/actions/{start,stop}` | every forward in the environment |
| GET | `/api/k8s/status` | kubectl availability |
| GET | `/api/k8s/contexts` | kubeconfig contexts |
| GET | `/api/k8s/namespaces?context=` | namespaces |
| GET | `/api/k8s/services?context=&namespace=` | services with ports |
| GET | `/api/hub/catalog` | curated catalog with default ports, env vars and volume target |
| GET | `/api/hub/tags?image=&limit=` | recent Docker Hub tags for an image |
| GET | `/api/hub/search?q=` | Docker Hub search |
| GET | `/api/images` | local Docker images |
| POST | `/api/docker/launch` | start Colima / Docker Desktop |

## Scope of this slice

Implemented: workspace switcher (create/settings/delete), Docker and Port Forwards sections, Docker
service status, lifecycle actions, live logs, curated catalog + Docker Hub
search, add/edit/remove services with prefilled editable defaults (ports, env
vars, volumes), port-forward discovery + CRUD + start/stop with live state,
local-process management (start/stop/add/delete, orphan recovery), DB
operations (sync-environment wizard, schema/data export and import, truncate)
as background jobs (tool images pulled on demand), shared config, engine
lifecycle.

Next slices: Kubernetes resource manager (deployments), queues, MockServer,
request collections, git operations.
