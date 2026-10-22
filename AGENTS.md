# Dynamic CRM — binding agent rules

These rules are always on for Cursor, Google Antigravity, and any other coding agent working in this repository. Follow them on every task. Do not substitute a different stack, palette, module layout, or state library.

The same text is installed in:

- `.cursor/rules/` for Cursor (`alwaysApply: true`)
- `.agents/rules/` for Antigravity (`trigger: always_on`)
- `AGENTS.md` and `.cursorrules` for agents that load a root rules file

Edit `docs/agent-rules/` and copy the result into those locations in the same change. Do not weaken the rules to finish a task.

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

# Design-system rules

Every visual change uses `docs/05_DESIGN_SYSTEM.md` and nothing else. Do not pick a new palette, a new shell, or a new component library for a single screen.

## Theme

The product is a light operations console.

- Canvas `#f8fafc` (`bg-slate-50`). Surfaces `#ffffff` (`bg-white`). Muted wells `#f1f5f9` (`bg-slate-100`).
- Text `#0f172a` (`text-slate-900`), secondary `text-slate-800` or `text-slate-700`, muted `text-slate-600`, subtle `text-slate-500`.
- Borders `border-slate-200` and `border-slate-300`.
- Primary action `#0369a1` (`bg-sky-700 text-white hover:bg-sky-800`). Links `text-sky-700`. Focus `focus:border-sky-700 focus:ring-2 focus:ring-sky-700/30`.
- Success `text-emerald-700` on `bg-emerald-50`. Warning `text-amber-700` on `bg-amber-50`. Danger `text-red-700` on `bg-red-50`. Unknown and maintenance `text-slate-600` on `bg-slate-100`.
- Status color is always paired with a word or an icon.

Allowed backgrounds are `bg-white`, `bg-slate-50`, `bg-slate-100`, `bg-sky-50`, `bg-sky-700`, `bg-sky-800`, `bg-emerald-50`, `bg-amber-50`, `bg-red-50`, and `bg-red-700` only on a danger-confirm button. `hover:bg-red-800` is allowed only on that button.

Do not use purple, indigo, pink, orange, lime, fuchsia, teal, or rose utilities on chrome. Do not use arbitrary hex in templates. Do not add gradients, glass, or a dark theme. Do not add `dark:` classes.

## Charts

Series colors, in order: `#0369a1`, `#0f766e`, `#b45309`, `#334155`, `#be123c`, `#047857`. Chart.js and ECharts use this list. `#0f766e` and `#be123c` stay inside charts. Grid lines `#e2e8f0`. Axis labels `#475569`. Tooltip surface white, border `#cbd5e1`, text `#0f172a`.

## Shell and controls

- Font is Tailwind's default sans. No webfont. Metric values and ids use `font-mono text-sm`.
- Controls are `rounded-md`. Cards and dialogs are `rounded-lg shadow-sm`. `rounded-full` is only a status dot or an avatar.
- Shell: left nav `w-60 border-r border-slate-200 bg-white`; top bar `h-14 border-b border-slate-200 bg-white`; main `bg-slate-50 p-6`.
- Active nav item `bg-sky-50 text-sky-800`. Inactive `text-slate-700 hover:bg-slate-50`.
- Page title `text-xl font-semibold text-slate-900`. Section title `text-sm font-semibold text-slate-900`.
- Cards `rounded-lg border border-slate-200 bg-white p-4 shadow-sm`.
- Inputs match `docs/04_DYNAMIC_ENGINE.md`: `border-slate-300`, sky focus ring, `text-sm`. Errors `text-sm text-red-700`. Help `text-sm text-slate-600`.
- Primary, secondary, and danger button class strings are copied from `docs/05_DESIGN_SYSTEM.md`. Do not invent a fourth button style.

When creating `packages/frontend/src/styles.css`, paste the `:root` token block from `docs/05_DESIGN_SYSTEM.md` unchanged. Do not add color variables.
