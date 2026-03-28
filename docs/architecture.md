# Architecture Notes

## Goals

- Support private-cloud style file browsing and management
- Support LAN device discovery and peer-to-peer file transfer
- Keep the client modular so mobile, desktop, and tablet can share most logic

## Suggested Layering

Each feature can gradually evolve toward this structure:

```text
features/<feature>/
  data/
    datasources/
    models/
    repositories/
  domain/
    entities/
    repositories/
    usecases/
  presentation/
    pages/
    providers/
    widgets/
```

## Current Decisions

- `app/`: app shell, router, theme
- `core/`: shared contracts, common models, errors, constants
- `features/`: business modules
- `shared/`: reusable providers and widgets

## Planned Core Modules

1. File index module
2. Device discovery module
3. Transfer queue and session module
4. Auth and trust module
5. Local persistence module

## Recommended Next Milestones

1. Add platform folders with `flutter create .`
2. Introduce a persistence layer, for example `isar` or `drift`
3. Add a real network abstraction for HTTP + socket-based transfer
4. Design transfer protocol messages and retry semantics
5. Add logging, diagnostics, and integration tests
