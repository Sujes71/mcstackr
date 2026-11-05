# MCStackr

Native macOS app for the Stackr environment manager. Same domain, same config,
same power — with a real UI.

MCStackr is a SwiftUI front end over a local Go engine. Both the app and the
existing `stackr` CLI read and write `~/.stackr/config.yaml`, so profiles,
environments, services and encrypted credentials are shared.

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
| POST | `/api/profiles` | create a profile |
| POST | `/api/profiles/{p}/envs` | add an environment |
| GET | `/api/profiles/{p}/envs/{e}/status` | merged config + container status |
| GET | `/api/profiles/{p}/envs/{e}/compose` | generated compose YAML |
| GET | `/api/profiles/{p}/envs/{e}/logs` | SSE log stream |
| POST | `/api/profiles/{p}/envs/{e}/actions/{up,down,restart}` | environment lifecycle |
| POST | `/api/profiles/{p}/envs/{e}/services` | add a service |
| DELETE | `/api/profiles/{p}/envs/{e}/services/{s}` | remove a service |
| POST | `/api/profiles/{p}/envs/{e}/services/{s}/actions/{up,stop,down,restart}` | service lifecycle |
| GET | `/api/hub/search?q=` | Docker Hub search |
| GET | `/api/images` | local Docker images |
| POST | `/api/docker/launch` | start Colima / Docker Desktop |

## Scope of this slice

Implemented: profiles, environments, Docker service status, lifecycle actions,
live logs, Docker Hub search, add/remove services, shared config, engine
lifecycle.

Next slices: Kubernetes port-forward + resource manager, DB operations, queues,
MockServer, request collections, git operations.
