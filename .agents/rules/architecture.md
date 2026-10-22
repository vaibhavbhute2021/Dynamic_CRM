---
trigger: always_on
description: Binding Dynamic CRM architecture, tenancy, and stack. Apply on every task.
---

# Architecture rules

These rules bind every task. Cursor, Antigravity, and any other agent follow them instead of a default stack or a new design. If a request conflicts with this file or with `docs/01_PRD.md` through `docs/05_DESIGN_SYSTEM.md`, follow the documents. Do not invent a parallel approach.

## Authority

Before changing behavior, read the matching spec:

- Product behavior: `docs/01_PRD.md`
- Process, tenancy, modules, API: `docs/02_ARCHITECTURE.md`
- Tables, indexes, RLS: `docs/03_DATABASE_SCHEMA.md` and `docs/sql/`
- Custom fields, forms, JSONB: `docs/04_DYNAMIC_ENGINE.md`
- Color and shell: `docs/05_DESIGN_SYSTEM.md`

A column, route, role, metric name, or widget type that the spec does not list is not added in passing. Update the spec in the same change, or do not add it.

## Stack

Use only this stack:

- Frontend: Angular 20+ standalone components, signals, reactive forms, Tailwind CSS 4, Angular CDK, Chart.js, Apache ECharts.
- Backend: Node.js 22, Express 5, TypeScript strict, Zod 3.24.
- Database: PostgreSQL 17, TimescaleDB for `telemetry_metrics`, shared schema, `tenant_id` on every tenant row, forced row-level security.
- Realtime: Socket.io fed by PostgreSQL `LISTEN/NOTIFY`.
- Monorepo: npm workspaces, `packages/backend`, `packages/frontend`, `packages/shared-types`.

Do not add React, Vue, Next.js, NestJS, Prisma, TypeORM, Drizzle, GraphQL, tRPC, NgRx, Redux, Kafka, Redis, a second database, MongoDB, or a CSS framework other than Tailwind. Do not add a UI kit.

## Tenancy and data

- Take `tenantId` from request context. Never from the JSON body or the query string.
- Open tenant SQL only inside `withTenant`. Repositories accept the `PoolClient` they are given and do not open transactions or call `pool.query`.
- `set_config('app.tenant_id', value, true)` — the third argument stays `true`.
- Client viewers are filtered by `customer_id` in the repository as well as by RLS.
- The only cross-tenant SQL is a `SECURITY DEFINER` function already on the allowlist in `docs/03_DATABASE_SCHEMA.md`. A new one is added to that allowlist in the same change.
- Parameterized SQL only. Do not concatenate values into SQL.
- Money on relational columns is integer minor units. Custom currency fields are decimal strings.
- Status values are tenant status keys from `status_definitions`, not new PostgreSQL enums.
- Custom attributes are validated with `compileCustomAttributesSchema` on the merged object from `docs/04_DYNAMIC_ENGINE.md`.
- Mutating services write `audit_logs` in the same transaction. Secrets are redacted.
- Do not add a column the schema document does not describe.

## API and modules

- Throw `AppError` with a stable code from `@dynamic-crm/shared-types`. Responses never include stacks, SQL, or constraint names.
- Request bodies use Zod `.strict()`.
- Permission checks import the matrix in `@dynamic-crm/shared-types`. A new route updates that matrix and the PRD table together.
- Each backend module owns its routes, core Zod schemas, repository, and service. CRM calls the dynamic engine. It does not reimplement field types.
- The access token stays in memory. It is not written to `localStorage`.
- Ingest routes accept ingest credentials, not user access tokens.

## Frontend structure

- `bootstrapApplication`, standalone components, `ChangeDetectionStrategy.OnPush` on every component.
- Signals for session, server snapshots, and live maps. Reactive forms for input. Do not introduce another global state library.
- The dynamic form factory is the only renderer for custom fields.
- Route guards use `canMatch` and the shared permission matrix.
- Lists that can exceed 100 rows use the CDK scrolling viewport.

## Scope

Stay inside the PRD. Do not build card charging, email delivery, SNMP, SSH collection, a per-tenant database, native mobile apps, plugins, or multi-factor authentication while doing some other task.

Phase 2 build order in `docs/02_ARCHITECTURE.md` is the sequence. Do not skip the RLS isolation test to start a feature.

## Changing these rules

Do not weaken this file to finish a task. An edit to the rule text is made in `docs/agent-rules/` and copied to `AGENTS.md`, `.cursorrules`, `.cursor/rules/`, and `.agents/rules/` in the same change.
