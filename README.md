# Dynamic CRM

Multi-tenant IT operations and CRM platform for small managed service providers and tech consultancies.

Phase 1 is the engineering blueprint in [`docs/`](docs/README.md). Start with [docs/01_PRD.md](docs/01_PRD.md). Application code is specified in [docs/02_ARCHITECTURE.md](docs/02_ARCHITECTURE.md) and is not scaffolded yet.

| Spec | Purpose |
| --- | --- |
| [Product requirements](docs/01_PRD.md) | Who the product serves and what it must do |
| [Architecture](docs/02_ARCHITECTURE.md) | Monorepo, tenancy, telemetry, errors, realtime |
| [Database schema](docs/03_DATABASE_SCHEMA.md) | PostgreSQL DDL, indexes, row-level security |
| [Migrations](docs/sql/001_core.sql) | Executable schema applied by `psql -f` |
| [Dynamic engine](docs/04_DYNAMIC_ENGINE.md) | Custom fields, Zod, Angular forms, JSONB queries |
| [Color scheme](docs/05_DESIGN_SYSTEM.md) | The only palette, chart colors, and app shell |
| [Agent rules](AGENTS.md) | Always-on rules for Cursor and Antigravity |
