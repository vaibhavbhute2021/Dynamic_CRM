# Dynamic CRM — System architecture

| | |
| --- | --- |
| Status | Approved for Phase 2 implementation |
| Version | 1.0 |
| Date | 22 October 2026 (Asia/Calcutta) |
| Audience | Engineering and AI implementation agents |
| Governs | Process shape, tenancy, pipelines, and the Phase 2 repository layout |

Behavior is defined in [01_PRD.md](01_PRD.md). Columns and constraints are defined in [03_DATABASE_SCHEMA.md](03_DATABASE_SCHEMA.md). Custom-field compilation and forms are defined in [04_DYNAMIC_ENGINE.md](04_DYNAMIC_ENGINE.md).

## 1. Architecture in one page

Dynamic CRM is a modular monolith. One Node.js process serves the HTTP API, the websocket gateway, the pull scheduler, and the breach scanners. PostgreSQL is the system of record for CRM rows, configuration, and time-series samples. TimescaleDB organizes the metric table into time chunks and serves one-minute aggregates to dashboards. Tenants share the schema. Isolation is `tenant_id` plus forced row-level security.

The frontend is an Angular application of standalone components. Server state enters through HTTP. Live node and incident updates enter through a websocket and land in signals. Custom forms are built at runtime from field metadata. They are not generated source code.

```
                         ┌───────────────────────────┐
                         │  Angular (standalone)     │
                         │  signals + reactive forms │
                         └────────────┬──────────────┘
                                      │ HTTPS + WSS
                                      ▼
┌─────────────────────────────────────────────────────────────┐
│  Node.js process  (Express, TypeScript strict)             │
│                                                             │
│  request id → headers → body limit → rate limit            │
│       → authenticate / ingest-auth                          │
│       → authorize (shared permission matrix)                │
│       → controller → service → withTenant()                 │
│                                                             │
│  scheduler + SLA scanner + escalation scanner               │
│  Socket.io gateway fed by PostgreSQL LISTEN/NOTIFY          │
└────────────┬───────────────────────────────┬────────────────┘
             │ SQL (runtime role, RLS)       │ NOTIFY
             ▼                               ▼
┌─────────────────────────────────────────────────────────────┐
│  PostgreSQL + TimescaleDB                                   │
│  relational core │ JSONB custom attributes │ hypertable     │
└─────────────────────────────────────────────────────────────┘
             ▲
             │ HTTPS push (ingest credential)
┌────────────┴────────────┐
│  Tenant-hosted agent    │
│  heartbeat + resources  │
└─────────────────────────┘
```

Phase 2 runs two replicas of that process behind a load balancer. No replica holds tenant data in memory except short-lived caches of compiled Zod schemas and the websocket room membership of its own connections. Both caches are invalidated or populated from the database, so a replica can disappear without a drain protocol beyond the load balancer dropping it.

## 2. Decision log

| Decision | Choice | Why it fits this product |
| --- | --- | --- |
| Tenancy | Shared schema, `tenant_id` on every tenant row, forced RLS | The envelope is 200 small tenants. A database per tenant would multiply backups and migrations past what this operating shape can carry. |
| Custom fields | JSONB on the row, GIN index, Zod compiled per tenant | The product requirement forbids a migration per field. Entity-attribute-value tables make the form and the filter path slower to implement correctly. |
| Metrics store | Timescale hypertable in the same PostgreSQL | About 1,000 samples per second is inside one database. A second metrics product would split the incident transaction from the sample. |
| Realtime bus | `LISTEN/NOTIFY`, forwarded by each replica's Socket.io | Payloads are small incident and sample notices. The 8 KB notify limit is enough. A cache service becomes justified above roughly 5,000 notices per second. |
| Collection | Push agent and HTTP/TCP/TLS pull | The platform never stores SSH or domain-admin credentials for a customer's server. |
| Status | Rows in `status_definitions`, not PostgreSQL enums | Tenants edit lifecycles in the product. |
| Money | Integer minor units on relational columns | Currency math stays exact. JSON currency fields are decimal strings for the same reason. |
| Validation | Server Zod schema is authoritative | The form and the API share field metadata and still fail closed when the form is bypassed. |
| Process shape | One deployable Node process | The team size implied by the envelope does not support a fleet of services. Modules inside the process keep a later split possible. |

## 3. Monorepo

Package manager: npm workspaces. Language: TypeScript in `strict` mode everywhere, plus `noUncheckedIndexedAccess` and `exactOptionalPropertyTypes`. Node.js 22 LTS. The backend compiles with `tsc` and runs as JavaScript. The frontend builds with the Angular CLI. Shared types are consumed as TypeScript source through project references so the two packages cannot drift on a published version.

### 3.1 Directory tree

This tree is the Phase 2 scaffold contract. Phase 1 creates the `docs/` files only.

```
dynamic-crm/
├── .cursorrules                    # agent rules in section 12
├── .editorconfig
├── .gitignore
├── package.json                    # private, workspaces: packages/*
├── package-lock.json
├── tsconfig.base.json              # strict flags live here
├── docker-compose.yml              # postgres+timescale, mailhog not required
├── Dockerfile.backend
├── Dockerfile.frontend
├── docs/
│   ├── README.md
│   ├── 01_PRD.md
│   ├── 02_ARCHITECTURE.md
│   ├── 03_DATABASE_SCHEMA.md
│   └── 04_DYNAMIC_ENGINE.md
└── packages/
    ├── shared-types/
    │   ├── package.json            # name: @dynamic-crm/shared-types
    │   ├── tsconfig.json
    │   └── src/
    │       ├── index.ts
    │       ├── roles.ts            # role union
    │       ├── permissions.ts      # the PRD matrix as data
    │       ├── custom-fields.ts    # field definition DTO
    │       ├── metrics.ts          # metric name union + units
    │       ├── money.ts            # minor-unit helpers, ISO exponents
    │       └── api-error.ts        # stable error code union
    ├── backend/
    │   ├── package.json            # name: @dynamic-crm/backend
    │   ├── tsconfig.json
    │   ├── src/
    │   │   ├── main.ts             # boot, role assertion, listen
    │   │   ├── app.ts              # Express app factory
    │   │   ├── config/env.ts       # Zod-parsed environment
    │   │   ├── context/als.ts      # AsyncLocalStorage request context
    │   │   ├── db/
    │   │   │   ├── pool.ts
    │   │   │   ├── with-tenant.ts
    │   │   │   └── sql.ts          # tagged query helper, parameters only
    │   │   ├── middleware/
    │   │   │   ├── request-id.ts
    │   │   │   ├── authenticate.ts
    │   │   │   ├── authorize.ts
    │   │   │   ├── ingest-auth.ts
    │   │   │   ├── error-handler.ts
    │   │   │   └── rate-limit.ts
    │   │   ├── modules/
    │   │   │   ├── auth/
    │   │   │   ├── crm/
    │   │   │   ├── monitoring/
    │   │   │   ├── alerts/
    │   │   │   ├── dynamic-engine/
    │   │   │   ├── dashboards/
    │   │   │   ├── audit/
    │   │   │   └── notifications/
    │   │   ├── realtime/
    │   │   │   ├── gateway.ts      # Socket.io
    │   │   │   └── notify-listener.ts
    │   │   └── jobs/
    │   │       ├── probe-scheduler.ts
    │   │       ├── heartbeat-scanner.ts
    │   │       ├── sla-scanner.ts
    │   │       └── escalation-scanner.ts
    │   └── migrations/             # SQL copied from the schema doc, ordered
    └── frontend/
        ├── package.json            # name: @dynamic-crm/frontend
        ├── tsconfig.json
        ├── tailwind configuration
        └── src/
            ├── main.ts
            ├── index.html
            ├── styles.css
            └── app/
                ├── app.config.ts   # bootstrapApplication providers
                ├── app.routes.ts
                ├── core/
                │   ├── auth/       # session signal, interceptor, guards
                │   ├── realtime/   # socket → signals
                │   └── http/       # error interceptor
                ├── shared/ui/
                │   └── dynamic-form/
                └── features/
                    ├── crm/
                    ├── monitoring/
                    ├── settings/   # fields, statuses, users
                    └── dashboard/
```

Each backend module owns its routes, its Zod input schemas for **core** columns, its repository, and its service. Repositories accept a `PoolClient` and do not open transactions. Services open one `withTenant` transaction per use case. The dynamic-engine module exports `compileCustomAttributesSchema` for the other modules. CRM services call it. They do not embed field-type switches of their own.

### 3.2 Runtime versions

| Piece | Version |
| --- | --- |
| Node.js | 22 LTS |
| TypeScript | 5.6 or newer, strict |
| Express | 5 |
| Zod | 3.24, classic API (`z.object`, `.strict()`, `.safeParse`) |
| Angular | 20 or newer, standalone, no `NgModule` |
| Tailwind CSS | 4 |
| Angular CDK | matching Angular major |
| Charts | Chart.js for counts and pipeline bars. Apache ECharts for metric series |
| Realtime | Socket.io 4 on the server and the matching client |
| PostgreSQL | 17 |
| TimescaleDB | 2.17 or newer, compatible with PostgreSQL 17 |
| Password hash | `argon2` (Argon2id) |

Zod 4 is an approved upgrade when the compilation helpers in the dynamic-engine spec are re-checked against it. The spec uses the Zod 3 call style.

### 3.3 Docker compose contract

Phase 2 `docker-compose.yml` MUST bring up at least:

| Service | Image | Purpose |
| --- | --- | --- |
| `postgres` | `timescale/timescaledb` PostgreSQL 17 tag | Database with Timescale preloaded |
| `backend` | `Dockerfile.backend` | API, scheduler, gateway. Depends on postgres healthy |
| `frontend` | `Dockerfile.frontend` | Static Angular build behind a small web server, or `ng serve` in a dev override |

The database container creates the `dynamic_crm` database. Migrations run as `dynamic_crm_migrator`. The API container receives only the runtime connection string.

Environment variables:

| Name | Who reads it | Purpose |
| --- | --- | --- |
| `DATABASE_URL` | API | Runtime role, RLS enforced |
| `DATABASE_MIGRATION_URL` | Migration job only | Migrator role, `BYPASSRLS` |
| `JWT_ED25519_PRIVATE_KEY` | API | PKCS8 PEM |
| `JWT_ED25519_PUBLIC_KEY` | API | SPKI PEM |
| `ACCESS_TOKEN_TTL_SECONDS` | API | Default 900 |
| `REFRESH_TOKEN_TTL_SECONDS` | API | Default 1209600 |
| `CORS_ORIGINS` | API | Comma-separated allowlist |
| `PORT` | API | Default 3000 |
| `LOG_LEVEL` | API | `info` in production |

The API process MUST exit on boot when `DATABASE_URL` uses a role that is a superuser or has `rolbypassrls = true`. The check is `SELECT current_user, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user`.

## 4. Request pipeline

### 4.1 Middleware order

Order is normative. Later middleware MAY assume earlier middleware ran.

```
1  requestId          ensure x-request-id, store on the response
2  security headers   helmet defaults, HSTS when the deployment is HTTPS
3  cors               allowlist from CORS_ORIGINS, no reflected origin
4  json body          64 KiB CRM, 256 KiB on /api/v1/ingest
5  rate limit         login, refresh, ingest, and the rest with separate budgets
6  access log         method, path template, status, duration, request id
7  route
```

Authenticated CRM routes then:

```
8  authenticate       verify EdDSA access token
9  load session       load_session(sub) and compare tid, role, ver, status
10 authorize          permission matrix for method + route template
11 controller
```

Ingest routes replace steps 8–10 with `ingest-auth`, which hashes the bearer token and calls `lookup_ingest_credential`. They do not accept access tokens.

`authenticate` and `ingest-auth` write the request context into `AsyncLocalStorage`:

```ts
interface RequestContext {
  requestId: string;
  tenantId: string;       // uuid
  userId: string | null;  // null on ingest
  role: Role | null;
  customerId: string | null;
  ingestNodeId: string | null; // set when the credential is node-scoped
  ip: string;
}
```

Controllers read context from the ALS helper `requireContext()`. They MUST NOT read `tenantId` from `req.body` or `req.query`.

### 4.2 Transactions and tenant context

`withTenant` is the only supported way to touch tenant data.

```ts
export async function withTenant<T>(
  tenantId: string,
  run: (client: PoolClient) => Promise<T>,
): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    await client.query("SELECT set_config('app.tenant_id', $1, true)", [tenantId]);
    const result = await run(client);
    await client.query("COMMIT");
    return result;
  } catch (error) {
    try {
      await client.query("ROLLBACK");
    } catch {
      // the connection is discarded by release on a failed rollback
    }
    throw error;
  } finally {
    client.release();
  }
}
```

Rules:

- The third argument to `set_config` MUST be `true`. That scopes the setting to the transaction. A session-level `SET` would leak the previous tenant to the next borrower of the pooled connection.
- Repositories MUST use the `PoolClient` passed in. A repository that calls `pool.query` directly bypasses the setting and will see zero rows under RLS, or worse, will run before any setting exists and fail closed. Both outcomes hide bugs. The lint rule is: production code outside `with-tenant.ts` and the privileged-function wrappers does not import the pool.
- One use case, one transaction. A service MUST NOT call `withTenant` and then perform HTTP (the probe scheduler uses its own short transactions per claim and per result). Holding a pool connection across a 10-second HTTP probe starves the pool.
- Client-supplied `tenant_id` is dropped. Inserts write `tenantId` from the ALS context. Updates never touch the `tenant_id` column. The database trigger `reject_tenant_id_change` is the backstop.
- Nested `withTenant` is not supported. Services compose by passing the client into repositories.

The RLS policy compares `tenant_id` to `current_setting('app.tenant_id', true)::uuid`. When the setting is missing, the policy is false and the statement returns no rows or fails the `WITH CHECK` on write. That is the fail-closed behavior required by NFR-01.

### 4.3 Customer scope

RLS does not know about client viewers. Repositories that read `crm_tickets`, `crm_orders`, `crm_order_lines`, `monitored_nodes`, `alert_incidents`, `crm_contacts`, and `custom_records` MUST append `AND customer_id = $customerId` when the context role is `client_viewer`. A shared helper `scopeCustomer(context)` returns the predicate and the bound value so each repository does not re-implement the branch incorrectly.

Writes follow the same helper. A client viewer insert of a ticket sets `customer_id` from the context, ignoring the body.

Internal roles do not get this predicate. An account owner filter ("my accounts") is a query parameter, not an authorization rule.

### 4.4 Error handling

Domain code throws `AppError`. Everything else is unexpected.

```ts
export class AppError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details?: unknown,
  ) {
    super(message);
  }
}
```

Stable codes live in `@dynamic-crm/shared-types` and include at least: `UNAUTHENTICATED`, `FORBIDDEN`, `NOT_FOUND`, `VALIDATION_ERROR`, `CONFLICT`, `TYPE_IMMUTABLE`, `RATE_LIMITED`, `INTERNAL`.

The error middleware is registered last. It maps:

| Thrown | HTTP | Body code |
| --- | --- | --- |
| `AppError` | its status | its code |
| ZodError from a body parser | 422 | `VALIDATION_ERROR` |
| PostgreSQL `23505` unique violation | 409 | `CONFLICT` |
| PostgreSQL `23503` foreign key | 422 | `VALIDATION_ERROR` |
| PostgreSQL `23514` check | 422 | `VALIDATION_ERROR` |
| PostgreSQL `42501` insufficient privilege | 403 | `FORBIDDEN` |
| Anything else | 500 | `INTERNAL` |

Response shape:

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Request validation failed",
    "requestId": "8f0c1c3e-4b2a-4e0a-9c1d-2a6b7c8d9e0f",
    "details": [
      { "path": "customAttributes.plan", "code": "invalid_enum", "message": "Invalid option" }
    ]
  }
}
```

Sanitization rules:

- The 500 body contains `code`, a fixed message `"Unexpected error"`, and `requestId`. It MUST NOT contain the exception message, the stack, SQL, or bound parameters.
- Zod issues are mapped to `{ path, code, message }` where `path` is the joined Zod path. Internal Zod objects are not returned.
- PostgreSQL errors contribute their SQLSTATE to the log line and contribute only the mapping above to the client. Constraint names MAY be logged. They MUST NOT be required by the client.
- Logs include the stack for unexpected errors, plus `requestId`, `tenantId`, and `userId`. Logs omit the request body on authentication and ingest routes.

Controllers do not catch errors except to add a more specific `AppError`. They let the middleware serialize.

### 4.5 HTTP API surface

All JSON routes are under `/api/v1`. Identifiers in paths are UUIDs. List endpoints accept `limit` (default 50, max 200) and `cursor`. Responses use `{ data, nextCursor }`.

| Method | Path | Permission |
| --- | --- | --- |
| POST | `/auth/login` | public |
| POST | `/auth/refresh` | refresh token |
| POST | `/auth/logout` | authenticated |
| GET, POST | `/customers` | matrix |
| GET, PATCH | `/customers/:id` | matrix |
| GET, POST | `/customers/:id/contacts` | matrix |
| GET, POST | `/opportunities` | matrix |
| PATCH | `/opportunities/:id` | matrix, includes status change |
| GET, POST | `/orders` | matrix |
| PATCH | `/orders/:id` | matrix |
| POST | `/orders/:id/lines` | matrix |
| PATCH | `/order-lines/:id` | matrix, procurement status |
| GET | `/procurement` | account manager, admin, technician read |
| GET, POST | `/tickets` | matrix |
| PATCH | `/tickets/:id` | matrix |
| POST | `/tickets/:id/comments` | matrix |
| GET, POST | `/nodes` | matrix |
| PATCH | `/nodes/:id` | matrix |
| GET, POST | `/alert-rules` | admin, technician |
| GET | `/incidents` | matrix |
| POST | `/incidents/:id/acknowledge` | admin, technician |
| POST | `/incidents/:id/resolve` | admin, technician |
| GET | `/dashboard` | authenticated, data already scoped |
| PUT | `/dashboard/layout` | personal layout, or role layout for admin |
| GET, POST | `/custom-fields` | read: internal; write: admin |
| POST | `/custom-fields/:id/archive` | admin |
| GET, POST | `/custom-entities` | read: internal; write: admin |
| GET, POST | `/custom-entities/:key/records` | matrix plus client scope |
| GET, PUT | `/status-lifecycles/:entity` | read: internal; write: admin |
| POST | `/ingest/credentials` | admin, technician |
| POST | `/ingest/credentials/:id/revoke` | admin, technician |
| POST | `/ingest/metrics` | ingest credential |
| POST | `/ingest/heartbeats` | ingest credential |
| GET | `/audit-logs` | admin |

Websocket namespace: `/realtime`.

Unknown routes return 404 `NOT_FOUND`. A disabled feature returns 404 rather than a partial payload.

## 5. Telemetry pipeline

### 5.1 Flow

```
 Agent or scheduler                Express ingest                         PostgreSQL                         Angular
 ─────────────────                 ──────────────                         ──────────                         ───────

 POST /api/v1/ingest/metrics
 Authorization: Bearer <token>
 {
   nodeId, idempotencyKey,
   samples: [{ metric, value,
     recordedAt, attributes }]
 }
        │
        ▼
 request id, body limit, rate limit
        │
        ▼
 SHA-256(token) → lookup_ingest_credential
 reject when missing or revoked
 resolve tenantId, allowed node
        │
        ▼
 withTenant(tenantId)
   │
   ├─ insert ingest_receipts
   │    conflict → return prior ack, stop
   │
   ├─ Zod MetricBatch
   │    metric name in catalog
   │    value finite, attributes object
   │
   ├─ INSERT telemetry_metrics
   │    ON CONFLICT DO NOTHING
   │
   ├─ UPDATE monitored_nodes
   │    last_seen_at, status
   │
   ├─ load alert rules for node
   │    (indexed by tenant, cached by revision)
   │
   ├─ evaluate thresholds
   │    single sample, or window query
   │    <= 15 minutes, same transaction
   │
   ├─ INSERT alert_incidents
   │    partial unique: one open per source
   │    audit row if an incident changed
   │
   ├─ pg_notify('dynamic_crm_events', …)
   │
   └─ COMMIT
        │
        ▼
 202 { accepted, incidents }
 p95 < 500 ms for <= 20 samples
        │
        │  NOTIFY delivered at commit
        ▼
 each API replica LISTENs
 and emits to local sockets
        │
        ├─ room tenant:{tid}                 internal users
        └─ room tenant:{tid}:customer:{cid}  that customer's viewers
                                                     │
                                                     ▼
                                            RealtimeStore signals
                                            dashboard computed()
```

### 5.2 Ingest contract

A batch:

```json
{
  "nodeId": "6f1c0c5a-1d0e-4a7b-9c2d-111111111111",
  "idempotencyKey": "agent-1:6f1c0c5a:1710000000000",
  "samples": [
    {
      "metric": "cpu.util_pct",
      "value": 93.2,
      "recordedAt": "2026-10-22T11:40:00.000Z",
      "attributes": {}
    }
  ]
}
```

Rules the Zod schema enforces, matching FR-MON-09:

- `samples` length is 1 to 100.
- `metric` is a member of the catalog.
- `value` is a finite number. For `*.util_pct` it is between 0 and 100 inclusive. For `*.up` and `heartbeat.ok` it is 0 or 1.
- `recordedAt` is an ISO instant within the last 24 hours and not more than 5 minutes in the future. This rejects replay of ancient batches and clock-skewed future stamps.
- `attributes` is an object of string values, at most 20 keys. `disk.util_pct` requires `mount`. `app.error_count` and `app.ex_rate` require `service`.
- `idempotencyKey` is 8 to 200 characters.

The credential check:

- A node-scoped credential MUST present that `nodeId`.
- A tenant-scoped credential MUST present a node in the same tenant. RLS plus an explicit `tenant_id` predicate enforces the tenant. The service still compares the loaded node's tenant to the credential tenant and throws 404 on mismatch.
- A body field named `tenantId` is not part of the schema and fails `.strict()`.

Idempotency: the primary key of `ingest_receipts` is `(tenant_id, idempotency_key)`. A conflict returns the previous acceptance with 202 and does not insert samples again. Receipts older than 48 hours are deleted by a daily statement. The idempotency store is PostgreSQL so two replicas share it.

Sample identity: the primary key of `telemetry_metrics` is `(tenant_id, node_id, metric_name, recorded_at)`. A retry with the same stamp is `ON CONFLICT DO NOTHING`. Two different values with the same stamp keep the first. Agents MUST use distinct timestamps per metric per node.

### 5.3 Alert evaluation

Rules applicable to a sample are those whose metric matches and whose scope is either that node id or a kind/customer filter the node satisfies. The rule cache key is `(tenantId, revision)` where revision bumps when `alert_rules` change, using the same notify channel (`schema.invalidated` is for field definitions; `alerts.invalidated` is for rules). On miss, load from PostgreSQL.

For `window_seconds = 0`, compare the sample value.

For a positive window, aggregate the stored rows, including the row just inserted in this transaction:

```sql
SELECT avg(value) AS avg_value,
       min(value) AS min_value,
       max(value) AS max_value
FROM telemetry_metrics
WHERE tenant_id = $1
  AND node_id = $2
  AND metric_name = $3
  AND recorded_at > now() - make_interval(secs => $4);
```

The last-value aggregation uses the current sample and does not query. The query above is bounded by the composite index `(tenant_id, node_id, metric_name, recorded_at DESC)`.

When the comparison is true and the node is not in maintenance, insert an incident. The partial unique index makes a concurrent insert lose; the loser swallows `23505` and continues. When the comparison is false, resolve the open incident for that rule and node if one exists.

Cooldown: if an incident for that source was resolved less than `cooldown_seconds` ago, do not open another. The check is `MAX(resolved_at)` for that source key.

Batches of more than 20 samples insert metrics and node touch in the request transaction, commit, and run evaluation on a `setImmediate` follow-up transaction. The follow-up is still in-process. Phase 2 does not add a queue service for this. A process crash between commit and evaluation can delay an alert until the next sample, which is acceptable inside the 15-second-and-up check intervals.

### 5.4 Pull scheduler

The scheduler loop runs in the same process. Every replica runs it. Claims do not double-execute because `claim_due_probes(limit)` is a `SECURITY DEFINER` function that updates `next_check_at` with `FOR UPDATE SKIP LOCKED` and returns the claimed rows.

The loop:

1. Call `claim_due_probes(50)`.
2. For each claimed node, perform the HTTP, TCP, or TLS probe **outside** a transaction.
3. `withTenant` of that node's tenant to write samples, status, and incidents, reusing the ingest service so pull and push share evaluation.
4. Sleep 1 second when the claim returned no rows. Otherwise loop immediately.

Probe timeouts are 10 seconds. The HTTP client MUST set a hard timeout and MUST follow the redirect rule in FR-MON-03. Failures are samples (`http.up = 0`), not thrown errors that skip the node forever. The claim already moved `next_check_at` forward, so a failed write retries on the next interval rather than hot-looping.

The heartbeat scanner calls `claim_stale_heartbeats(100)`. That function sets `stale_claimed_until` one minute ahead and returns the rows. The process then opens incidents and sets `status = 'down'` inside `withTenant`. The claim column is what keeps a second replica from selecting the same node before the incident exists. The partial unique index on heartbeat incidents is the backstop if the claim expires and the row is selected again.

### 5.5 SLA and escalation scanners

These scanners iterate tenant ids from `list_active_tenant_ids()` and then use `withTenant`, because their volume is tickets and incidents, not samples. The conditional update in FR-CRM-08 makes two replicas safe.

Escalation uses the same loop. A step is due when `opened_at + after_seconds <= now()` and `last_escalation_step` on the incident is lower than the step index and the incident is still `open`. The update increments `last_escalation_step` only if it still matches the expected value. The replica that updates calls `Notifier.notify`.

### 5.6 Realtime

Channel: `dynamic_crm_events`. Payload is JSON text under 7000 bytes so it stays under the PostgreSQL notify limit with room to spare.

Event types: `metric.sample`, `node.status`, `incident.opened`, `incident.updated`, `schema.invalidated`, `alerts.invalidated`.

A `metric.sample` event carries one node, not the whole batch: `{ type, tenantId, nodeId, customerId, metric, value, recordedAt }`. When a batch has many metrics, the transaction emits one event per metric name, capped at 20 events, and then one summary event. Dashboards that need history call `GET /nodes/:id/metrics`.

Each replica holds one dedicated listener connection. On notification it:

- Drops the event when no local socket is in the relevant room.
- Emits `incident.opened` and similar to `tenant:{tenantId}` for internal users.
- Emits the same event to `tenant:{tenantId}:customer:{customerId}` when `customerId` is present.
- Drops custom-field values from realtime payloads entirely. Live events carry operational fields only, so an internal-only attribute cannot leak through a socket that the REST layer would have filtered.

Socket authentication is the access token in the Socket.io `auth` payload during the handshake. The gateway calls the same session load as HTTP. Internal roles join the tenant room. Client viewers join only their customer room. Tokens are re-checked on each subscription and the gateway disconnects the socket when `load_session` fails. Clients refresh the access token and reconnect. Phase 2 does not silently swap tokens on a live socket.

Angular `RealtimeStore` holds `ReadonlyMap` signals for nodes and incidents. Updates replace the map with a new map so `computed` consumers see a consistent snapshot. The store ignores events whose `tenantId` does not match the signed-in session, as a defense in case a room join is wrong.

### 5.7 Dashboard read path

`GET /dashboard` returns the resolved layout and the data for each widget in one response so the shell does not fan out into eight waterfalls. The service runs the widget queries inside one `withTenant` transaction with `SET LOCAL statement_timeout = '1500ms'`.

Metric charts read `telemetry_1m` when that relation exists:

```sql
SELECT bucket, avg_value, min_value, max_value
FROM telemetry_1m
WHERE tenant_id = $1
  AND node_id = $2
  AND metric_name = $3
  AND bucket >= $4
  AND bucket < $5
ORDER BY bucket;
```

When the relation is absent (local PostgreSQL without Timescale), the repository runs the `date_trunc('minute', recorded_at)` query documented in the schema. The service interface is `loadMetricBuckets` either way. Widgets do not embed SQL.

Chart.js renders pipeline and count widgets. ECharts renders `metric_chart` with a line series, a tooltip, and data zoom. The component also renders a visually hidden table of the same buckets for NFR-08.

## 6. Security architecture

### 6.1 Roles in PostgreSQL

| Role | Attributes | Used by |
| --- | --- | --- |
| `dynamic_crm_migrator` | `NOLOGIN` is flipped to `LOGIN` only in the migration environment, `BYPASSRLS` | Migration job, owner of functions that must cross tenants |
| `dynamic_crm_runtime` | `NOLOGIN` plus a password login in the deployment, `NOBYPASSRLS` | API process |

Table owner is the migrator. `FORCE ROW LEVEL SECURITY` is set, which subjects the owner except that the migrator's `BYPASSRLS` still bypasses. The runtime role is not the owner and does not bypass, so RLS always applies to the application.

`SECURITY DEFINER` functions are owned by the migrator, use `SET search_path = pg_catalog, public`, and are executable only by the runtime role. The allowlist is in the schema document. Application code calls them through named wrappers in `packages/backend/src/db/privileged.ts`. A pull request that adds a string of SQL calling a function outside that file is a review failure.

### 6.2 Tokens

Access tokens are EdDSA-signed JWTs. The private key is an environment variable. Refresh tokens are 32 random bytes, base64url, stored as SHA-256. The cookie for the refresh token is `HttpOnly`, `Secure`, `SameSite=Strict`, path `/api/v1/auth`. The access token is held in memory in the Angular app and sent as `Authorization: Bearer`. It is not written to `localStorage`.

Ingest tokens are 32 random bytes, shown once, stored as SHA-256. Lookup is by hash.

Argon2id parameters are fixed in FR-AUTH-01. The hash string includes its own parameters so a later raise of the memory cost still verifies old hashes.

### 6.3 Revocation

`users.token_version` increments when the user is disabled, when their role changes, and when an admin chooses "sign out everywhere." `load_session` returns the current version, role, status, tenant, and customer id. Middleware rejects the request when the token version differs, the status is not `active`, or the tenant claim does not match the row. That check is one primary-key read per request and closes the 15-minute window in which a disabled user would otherwise keep an access token.

Refresh reuse detection: each refresh row stores `family_id`. Rotation marks the old row `replaced_by`. Presenting a row that already has `replaced_by` sets `revoked_at` on every row with that `family_id`.

### 6.4 Redaction

The audit writer and the logger share `redact(value)`. Keys matching `/password|token|authorization|secret|hash/i` are replaced with `[redacted]` at any depth. Metric attributes are not passed through the audit writer.

## 7. Module boundaries

| Module | Owns | Must not |
| --- | --- | --- |
| `auth` | Login, refresh, users, password verify | Read CRM tables except through `load_session` |
| `crm` | Customers, contacts, pipeline, orders, tickets, SLA math | Compile Zod schemas itself; it calls the dynamic engine |
| `monitoring` | Nodes, ingest, probes, metric queries | Open incidents except through the alerts module |
| `alerts` | Rules, incidents, escalation state | Send email; it calls `Notifier` |
| `dynamic-engine` | Field and entity definitions, schema cache, status lifecycles | Know about HTTP status codes beyond `AppError` |
| `dashboards` | Layout persistence, widget query orchestration | Contain SQL for CRM; it calls the other modules' query methods |
| `audit` | Insert and list audit rows | Be skipped by a mutating service |
| `notifications` | `Notifier` port and the intent table | Import Express |

The SLA date walk lives in `crm/sla-clock.ts` as a pure function of `(start, minutes, contract) → Date`. The scanner and the ticket service both call it. It has no database import, which is what makes AC-05 a unit test.

## 8. Frontend architecture

`bootstrapApplication` registers the router, HTTP client with interceptors, and animations required by the CDK drag-drop. There is no root `NgModule`.

State:

- Session is a `signal<Session | null>` in `SessionStore`, updated by login and cleared by 401.
- Server lists use `httpResource` or a small `resource()` wrapper where the Angular version in use provides it. Where a feature needs a mutation followed by a reload, the feature calls the API and writes the result into a signal.
- Live data is `RealtimeStore`, also signals.
- Reactive forms remain the form library, as specified by the dynamic engine. Form value crosses into signals with `toSignal(form.valueChanges)` at the page edge when a preview needs it. Form state itself stays in the `FormGroup`.
- NgRx, Akita, and similar stores are not part of the scaffold. A second state library would split the session and the live maps.

Route guards use `canMatch` and the shared permission matrix. A missing permission redirects to the dashboard, or to login when the session signal is null.

Change detection is OnPush for every standalone component. Lists that can exceed 100 rows use the CDK scrolling viewport. The ticket queue and the node list qualify.

The HTTP interceptor attaches the access token, sets `x-request-id` if absent, and on 401 tries one refresh. A failed refresh clears the session and routes to login. 422 bodies with `details[].path` are handed to the dynamic form error mapper.

## 9. Observability

Logs are one JSON object per line: `time`, `level`, `msg`, `requestId`, `tenantId`, `userId`, `route`, `status`, `durationMs`. The probe scheduler logs `nodeId` and the check result, not the URL query string when it contains credentials (targets MUST NOT embed userinfo; the ingest schema and the node writer reject `user:pass@host`).

Health endpoints:

- `GET /healthz` returns 200 when the process is up. The load balancer uses it.
- `GET /readyz` returns 200 when a `SELECT 1` on the runtime pool succeeds and the notify listener is connected.

Both skip authentication and MUST NOT touch tenant tables.

OpenTelemetry traces are a Phase 2 stretch. The request id is the correlation story that MUST exist. Spans MAY be added without changing the log fields.

## 10. Verification requirements

Phase 2 is not done because the UI renders. It is done when the following exist and pass.

| Test | What it locks |
| --- | --- |
| RLS integration, two tenants, runtime role | AC-01, NFR-01. Includes a connection that never calls `set_config` and expects zero rows. |
| Client viewer repository tests | AC-02 |
| SLA clock unit tests | AC-05 |
| SLA scanner concurrency, two transactions | AC-06 |
| Ingest idempotency and forged tenant field | AC-07 |
| Heartbeat scanner | AC-08 |
| Custom field compile and merge | AC-10, AC-11, dynamic engine spec |
| Audit rollback | AC-13 |
| Token version | AC-14 |
| Boot assertion refuses a superuser `DATABASE_URL` | NFR-01 |

CI runs those tests against PostgreSQL 17. The Timescale policies are applied in a nightly job that builds the Timescale image, because not every developer machine will load the extension. The `date_trunc` fallback test runs in CI on vanilla PostgreSQL.

A latency smoke test posts 20-sample batches for one minute against a local database and records p95. CI fails that smoke only above 2 seconds, which catches accidental full-table scans. The 500 ms p95 in NFR-02 is measured in staging on the reference shape and recorded in the release notes.

## 11. Phase 2 build order

Implement in this order. Each step leaves the test suite green before the next starts.

1. Workspace scaffold, compose file, environment parser, migration runner, boot-time role assertion.
2. Apply the schema, including RLS. Land the isolation integration test before any CRM feature.
3. Auth: provision, login, refresh rotation, `load_session`, authorize middleware.
4. Dynamic engine: field CRUD, revision bump, Zod compiler, archive, client-exposure filter.
5. Customers and contacts through the dynamic form, including the audit transaction.
6. Pipeline, orders, lines, procurement list, block hours.
7. Tickets, comments, SLA clock, SLA scanner.
8. Nodes, ingest, scheduler, heartbeat scanner, metric read with the aggregate fallback.
9. Alert rules, incidents, escalation intents, websocket fan-out.
10. Dashboard layout and widgets.
11. Staging measurement of NFR-02 and NFR-03.

A step that needs a column that is not in the schema document stops and updates the schema document in the same change. Agents MUST NOT add an undocumented column "temporarily."

## 12. Repository agent rules

Phase 2 copies the following into `.cursorrules` at the repository root. It is the working agreement for later changes.

```
Dynamic CRM agent rules

Read docs/01_PRD.md, docs/02_ARCHITECTURE.md, docs/03_DATABASE_SCHEMA.md,
and docs/04_DYNAMIC_ENGINE.md before changing behavior.

Tenancy
- Take tenant id from request context. Never from the body or query string.
- Open tenant SQL only inside withTenant. Use the PoolClient you are given.
- set_config third argument is always true.
- Client viewers are filtered by customer id in the repository as well as by RLS.
- New cross-tenant SQL is a SECURITY DEFINER function on the schema allowlist.

Data
- Parameterized SQL only. No string concatenation of values.
- Money on relational columns is integer minor units.
- Status values are status keys looked up for the tenant, not new Postgres enums.
- Custom attributes are validated with compileCustomAttributesSchema on the merged object.
- Mutating services write audit_logs in the same transaction.
- Do not add a column the schema document does not describe. Update the document first.

API
- Throw AppError with a stable code. Do not send stacks or SQL to the client.
- Zod .strict() on request bodies.
- Permission checks use @dynamic-crm/shared-types. A new route updates the matrix and the PRD table together.

Frontend
- Standalone components, OnPush, signals for state.
- Reactive forms for inputs. The dynamic form factory is the only custom-field renderer.
- Do not introduce a new global state library.
- The access token stays in memory.

Scope
- Stay inside the phase described in the PRD out-of-scope list.
- Do not add Redis, Kafka, or a second database for the Phase 2 envelope.
```

## 13. Failure behavior

| Failure | Behavior |
| --- | --- |
| Runtime database unreachable | `/readyz` fails, load balancer stops traffic, in-flight transactions roll back, clients retry |
| Notify listener disconnects | Reconnect with backoff. HTTP ingest still succeeds. Live widgets pause until the listener returns. History reads still work |
| One API replica dies | The other replica continues. In-memory Zod caches rebuild on demand. Socket clients reconnect |
| Probe target hangs | The 10-second timeout records a down sample and releases the claim |
| Clock skew on an agent | Samples more than 5 minutes ahead or 24 hours behind are rejected with 422, and the node is not marked up |
| Tenant suspended | `load_session` and ingest lookup reject. `tenants.status` other than `active` fails closed |

Suspended tenants remain in the database. The scanner functions skip statuses other than `active`.
