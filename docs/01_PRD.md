# Dynamic CRM — Product Requirements

| | |
| --- | --- |
| Status | Approved for Phase 2 implementation |
| Version | 1.0 |
| Date | 22 October 2026 (Asia/Calcutta) |
| Audience | Product, engineering, and AI implementation agents |
| Governs | Behavior of the Phase 2 application |

Related: [architecture](02_ARCHITECTURE.md), [schema](03_DATABASE_SCHEMA.md), [dynamic engine](04_DYNAMIC_ENGINE.md).

## 1. Product vision

Dynamic CRM is one operational system for a small IT managed service provider (MSP) or tech consultancy. It holds the client relationship, the commercial agreement, the support work, and the health of the systems that agreement covers.

A five- to thirty-person MSP currently stitches that work across a PSA or ticketing tool, a separate RMM or uptime checker, a spreadsheet or billing app for retainers and block hours, and a shared inbox for "the server is down." Each tool has its own login, its own client list, and its own idea of status. The owner cannot see, on one screen, that a client's firewall is down, that their retainer has four hours left, and that the response SLA clock has twenty minutes remaining.

Dynamic CRM replaces that split with a shared client record:

- The account, its contacts, its pipeline, its orders, and its SLA live on the client.
- The servers, sites, certificates, and applications that the MSP watches are attached to the same client.
- A threshold breach and an SLA breach become incidents in the same queue a technician already works.
- Each tenant extends the record with its own fields, entities, statuses, and dashboard widgets. Those extensions are configuration, stored as data. They do not require a database migration or a backend deploy.

The product is multi-tenant from the first schema. Many MSPs share one database. One MSP must never read or write another MSP's rows.

### 1.1 Problem statement

Small IT providers feel the fragmentation in four places.

1. **The client exists three times.** Sales has a pipeline row, support has a ticket account, and monitoring has a device group. Renames, new sites, and ended contracts drift. Technicians open a ticket against the wrong asset because the monitoring tool's name and the PSA's name diverged.
2. **Money and work are disconnected.** Recurring retainers, annual licenses, hardware that still has to be ordered, and block-hour banks live in a spreadsheet. A technician closes a two-hour ticket and nobody decrements the bank. The account manager discovers the overrun at invoice time.
3. **Alerts arrive in a different product than the work.** A heartbeat failure creates an email. Someone copies it into a ticket if they see it. SLA clocks start late, or they start in the ticketing tool with no knowledge that the monitoring tool already knew the site was down.
4. **The last mile is a custom column.** Every MSP tracks something the product did not ship: a circuit ID, a backup-vendor contract number, a preferred remote-access tool, a site code. Teams either abuse a notes field, which cannot be filtered, or they pay for a migration to add a column. A small tenant will not wait for a vendor release to track a circuit ID.

Dynamic CRM addresses those four gaps with a single tenant-scoped client record, orders that understand recurring and block-hour billing, monitoring that opens incidents in the same tenant, and a dynamic configuration engine for fields, entities, statuses, and dashboards.

### 1.2 Design envelope

Requirements in this document are sized for the Phase 1 capacity envelope. Implementations must meet the functional requirements inside this envelope. They must not add infrastructure whose only purpose is a larger envelope.

| Dimension | Envelope |
| --- | --- |
| Tenants on one shared database | 200 active |
| Typical tenant | 40 client accounts, 300 monitored nodes, checks about once a minute |
| Aggregate metric ingest | About 1,000 samples per second average, burst to 5,000 samples per second for one minute |
| API shape | Two stateless API replicas |
| Custom fields | At most 50 active fields per target entity per tenant |
| Custom entities | At most 20 per tenant |
| Enum options | At most 100 per field |
| Custom attribute payload | At most 16 KiB per row |
| Dashboard | At most 8 widgets on a layout |

### 1.3 Phase 2 is explicitly out of scope for behavior

The following are real later products. Phase 2 must not half-build them.

- Card charging, tax calculation, and invoice PDF generation. Orders store amounts and procurement state. They do not collect payment.
- Delivery of email or SMS. Phase 2 records a notification intent and calls a `Notifier` port whose default adapter writes an audit row. An SMTP adapter is a later phase.
- SNMP, WMI, SSH, or agentless credential storage for customer servers. Collection is push from a tenant-hosted agent, or pull of HTTP, TCP, and TLS endpoints by the platform scheduler.
- A per-tenant database or per-tenant schema. Isolation is row-level. Every tenant-owned row carries `tenant_id`, which keeps a later physical split possible.
- Native mobile applications, white-label marketing sites, customer-written plugins, and arbitrary tenant JavaScript.
- Multi-factor authentication. Access tokens are short-lived so MFA can be added at login without a new resource model.
- Kafka, a dedicated metrics database, and multi-region active-active. The envelope above does not require them.

## 2. Personas

Permissions are normative in [section 6](#6-authorization-matrix). Personas describe the job to be done.

### 2.1 MSP Owner

The owner runs a 5- to 30-person consultancy. They are the tenant administrator. They buy the tools, hire technicians, and answer when a client escalates past the queue.

| | |
| --- | --- |
| Goals | See which clients are unhealthy, which contracts are about to breach, and which retainers are running out, without opening a second product. Add the fields the business already tracks on paper. |
| Frustrations | A monitoring console that does not know the contract. A CRM that does not know the server is down. Waiting on a vendor to add a column. |
| Success | The morning starts on one dashboard. A down node and a burning SLA are both visible. A new circuit-ID field is available to the team the same day, without a deploy. |
| Role | `tenant_admin` |

### 2.2 Tier 1 / Tier 2 Support Technician

The technician works the queue. Tier 1 triages and answers. Tier 2 takes server, network, and application incidents. The product uses one role for both tiers in Phase 2. Seniority is a management concern, not a permission bit.

| | |
| --- | --- |
| Goals | Know what is broken, who owns the client, how long the SLA clock has, and which asset is implicated. Acknowledge an alert and turn it into work without retyping it. |
| Frustrations | Alert emails that do not become tickets. Monitoring names that do not match the account. No visibility into whether the work is covered by block hours. |
| Success | A failed check is an incident in the tenant queue within the ingest budget. The ticket shows the node, the client, and the SLA deadline. Logging time decrements the right block-hour bank. |
| Role | `technician` |

### 2.3 Account / Billing Manager

The account manager owns the commercial relationship. They build the quote, turn it into a recurring order or a block-hour bank, track hardware and licenses that still have to be purchased, and watch margin.

| | |
| --- | --- |
| Goals | Move a deal from lead to an active order. See procurement that is stuck. See block hours before they overrun. Read tickets well enough to talk to the client, without living in the technical queue. |
| Frustrations | A spreadsheet of renewals. Hardware that was sold and never ordered. Learning about an SLA miss from the client. |
| Success | Pipeline stage, order term, line items, and procurement state are on the account. A block-hour bank shows purchased, consumed, and remaining. |
| Role | `account_manager` |

### 2.4 Client Viewer

The client viewer is an employee of the MSP's customer, not of the MSP. They check status on their own company: open tickets, whether a site is up, when a certificate expires. They must not see other customers of the same MSP, internal-only notes, or commercial fields the MSP marked internal.

| | |
| --- | --- |
| Goals | Open a ticket, see that it is being worked, and see the health of their own sites. |
| Frustrations | Sending email into a void. Being forwarded a screenshot from a tool they cannot log into. |
| Success | They sign in and see only their company's tickets, orders, and nodes. Internal custom fields are absent from the payload, not merely hidden in the page. |
| Role | `client_viewer` |

A client viewer user MUST reference exactly one `crm_customers` row in the same tenant. Internal roles MUST NOT reference a customer.

## 3. Tenancy and identity concepts

These terms are used with the meanings below everywhere else.

| Term | Meaning |
| --- | --- |
| Tenant | One MSP or consultancy. The isolation boundary. Stored in `tenants`. |
| User | A person who can sign in. Belongs to exactly one tenant in Phase 2. |
| Customer | A client account of the MSP. Stored in `crm_customers`. This is not the tenant. |
| Contact | A person at a customer. |
| Internal role | `tenant_admin`, `technician`, or `account_manager`. Sees all customers in the tenant. |
| Client scope | A `client_viewer` sees only rows whose `customer_id` equals their own. |
| Node | A monitored asset: server, switch, website, API, certificate, cloud instance, or application. |
| Custom attribute | A value for a tenant-defined field, stored in `custom_attributes` JSONB on the row. |
| Status key | A tenant-defined lifecycle state, such as `waiting_on_customer`. Not a PostgreSQL enum. |

An email address is globally unique across the deployment. A person who works for two MSPs has two accounts. Login is email plus password. The tenant is resolved from the user row, so the login form does not ask for a tenant slug.

The tenant slug is for URLs and future inbound mail. It MUST match `^[a-z0-9]+(?:-[a-z0-9]+)*$` and be 3 to 48 characters.

## 4. Functional requirements — CRM and orders

### FR-CRM-01 Client accounts

Internal users MUST be able to create, read, update, and soft-delete customer accounts. A customer has a display name, optional legal name, optional slug unique among live customers in the tenant, a lifecycle status, an optional account owner (an internal user), a billing email, an ISO currency, an IANA timezone, notes, and `custom_attributes`.

Default customer statuses, created with the tenant: `prospect`, `active`, `paused`, `former`. Allowed transitions are defined in the schema provisioning function. `former` MAY transition back to `active`.

Soft-deleted customers disappear from default lists and release their slug. They remain readable by a tenant admin who asks for deleted records.

### FR-CRM-02 Contacts

A customer has many contacts. A contact has a name, email, phone, optional job title, a primary flag, and `custom_attributes`. Among live contacts, a tenant MUST NOT store the same email twice. Exactly one live contact per customer SHOULD be primary; the service enforces this by clearing the previous primary in the same transaction when a new primary is set.

Client viewers MAY read contacts on their own customer. They MUST NOT create internal-only contacts. Phase 2 treats every contact as visible to the client viewer of that customer. Sensitive MSP-only notes belong in `notes` on the customer or in a custom field with `exposed_to_client = false`, not in a contact row.

### FR-CRM-03 Pipeline

A pipeline opportunity belongs to a customer. It has a name, an optional amount stored as integer minor currency units, a currency code, an expected close date, an owner, a status key, and `custom_attributes`.

Default stages, in order: `lead`, `qualified`, `proposal`, `negotiation`, `won`, `lost`. `won` and `lost` are terminal. The service MUST reject a status change that has no row in `status_transitions` for that tenant and entity.

A tenant admin MUST be able to rename stage labels, reorder stages, add a stage, and add or remove a transition. A tenant admin MUST NOT delete a stage that is still referenced by a live opportunity. They archive it. Archived stages remain valid on existing rows and MUST NOT be offered for new opportunities.

Winning an opportunity does not silently create an order. The account manager creates the order from the opportunity, and the order stores `opportunity_id`. This keeps the commercial document explicit.

### FR-CRM-04 Orders and billing intervals

An order belongs to a customer and optionally to an opportunity. It has a status key, a billing interval, a currency, optional term start and end dates, and `custom_attributes`.

Billing intervals:

| Interval | Meaning |
| --- | --- |
| `one_time` | A single charge. Hardware and project work use this. |
| `monthly` | Recurs each month from `term_starts_on`. |
| `quarterly` | Recurs each quarter. |
| `annual` | Recurs each year. |
| `block_hours` | A prepaid hour bank. `block_hours_purchased` is required and MUST be greater than zero. |

Default order statuses: `draft`, `quoted`, `approved`, `active`, `expired`, `cancelled`. Transitions are in the provisioning function. `expired` and `cancelled` are terminal.

Every line on an order MUST use the order's currency. Amounts on relational columns are **minor units** (`bigint`): cents for USD, yen for JPY. The application owns the ISO 4217 exponent map. The database stores the integer the application computed. The service MUST reject a line whose currency differs from the order.

The order stores `recurring_amount_minor`, maintained by the service whenever lines change, equal to the sum of `quantity * unit_amount_minor` for lines on a recurring interval order. `one_time` and `block_hours` orders store that column as null. The column exists so the pipeline and retainer dashboard do not re-sum lines on every page view.

### FR-CRM-05 Hardware and license procurement

Each order line has a kind:

| Kind | Use |
| --- | --- |
| `service` | Labor or a managed service. No procurement. |
| `hardware` | A physical device to purchase and deploy. |
| `license` | A software license or subscription key to purchase. |
| `block_hours` | The hour bank on a `block_hours` order. An order of this interval MUST have exactly one such line. |

`hardware` and `license` lines carry a procurement status: `to_order`, `ordered`, `received`, `deployed`. `service` lines and `block_hours` lines use `not_required`. The service MUST reject any other combination.

A line MAY store a vendor name and a serial number or license reference. Those values are visible to internal roles. A client viewer MAY see the line description, quantity, and kind. A client viewer MUST NOT see vendor cost. Phase 2 has a single unit amount, which is the sell amount. Cost tracking is out of scope, so there is no cost column to leak. Vendor name and serial or license reference are internal: the client payload omits them.

Account managers need a tenant-wide list of lines where procurement status is `to_order` or `ordered`, across customers. That list is a first-class view, not a custom report.

### FR-CRM-06 Block-hour consumption

A ticket MAY reference an order line of kind `block_hours` and MUST record `time_spent_hours` as a non-negative number with up to two decimal places. When time is logged or changed, the service, in the same transaction, sets `block_hours_consumed` on the order to the sum of `time_spent_hours` over live tickets that reference lines on that order.

The block-hour widget and the order page show purchased, consumed, and remaining (`purchased - consumed`). Remaining MAY be negative. The service MUST NOT reject a ticket because the bank is empty. The MSP decides whether to keep working. The product surfaces the overrun.

Thresholds for the block-hour indicator:

- Remaining at or below 20 percent of purchased: warning.
- Consumed at or above purchased: critical.

These indicators are computed on read. They also create an `alert_incidents` row of source `block_hours` the first time the order crosses each threshold, so the technician queue shows the overrun even if nobody opens the order.

### FR-CRM-07 Support tickets

A ticket belongs to a customer. It MAY reference a contact, a monitored node, an order line, and an opportunity. It has a priority, a status key, a title, a description, time spent, SLA columns from [FR-CRM-08](#fr-crm-08-sla-contracts-and-breach-timers), and `custom_attributes`.

Priority is fixed for Phase 2: `low`, `normal`, `high`, `urgent`. Priority selects the SLA target and the default queue sort. Status is tenant-defined because the work steps differ by MSP. Priority is not tenant-defined because the breach calculator and the queue depend on a stable set.

Default ticket statuses:

| Key | Category | Pauses SLA | Terminal |
| --- | --- | --- | --- |
| `new` | open | no | no, initial |
| `triaged` | open | no | no |
| `in_progress` | open | no | no |
| `waiting_on_customer` | pending | yes | no |
| `waiting_on_vendor` | pending | yes | no |
| `resolved` | closed | no | no |
| `closed` | closed | no | yes |

`resolved` is not terminal so a technician can reopen to `in_progress`. `closed` MAY transition to `in_progress` for the same reason. The full transition list is created by `provision_tenant` in the schema document.

Client viewers MAY create a ticket on their own customer, read those tickets, and add comments. They MUST NOT set priority above `normal`, assign a node that belongs to another customer, change SLA fields, or move status to anything other than a transition the tenant marked `client_allowed`. By default, the only client-allowed transition is from `resolved` or `closed` back to `in_progress` (reopen) and the initial create, which lands on `new`.

### FR-CRM-08 SLA contracts and breach timers

An SLA contract has a name, a customer (or null for the tenant-wide default), a clock mode, a timezone, weekly business hours, holiday dates, per-priority targets, and an escalation policy.

Clock modes:

- `24x7` — the clock runs on elapsed wall time.
- `business_hours` — the clock runs only inside the weekly windows, and it skips holiday dates.

Targets are required for all four priorities. Each target has `response_minutes` and `resolution_minutes`, integers greater than zero, and the resolution target MUST be greater than or equal to the response target.

At most one live default contract exists per customer, and at most one live tenant-default contract exists (`customer_id` null).

When a ticket is created, the service resolves the contract in this order: the customer's default contract, then the tenant default, then no SLA. A ticket with no SLA has null deadlines and is ignored by the breach scanner.

Deadline calculation:

1. Convert the start instant to the contract timezone.
2. For `24x7`, add the target minutes to the start instant.
3. For `business_hours`, walk forward through local windows until the target minutes are consumed. A window is a half-open local interval `[start, end)` written `HH:MM`. Windows on one day do not overlap and are stored in order. A holiday date, or a day with no windows, contributes nothing. The walk jumps from gap to gap. It does not iterate every minute.
4. Store the resulting UTC instant on `response_due_at` and `resolution_due_at`.

Pause and resume:

- Entering a status with `pauses_sla = true` stores the remaining whole seconds for response (if not yet responded) and resolution (if not yet resolved), sets `sla_paused_at`, and sets both due instants to null so the scanner does not pick the ticket up.
- Leaving a pausing status recomputes the due instants by running the same walk from "now" with the stored remaining seconds, clears the remaining-second columns, and clears `sla_paused_at`.
- A breach that already happened stays breached across a later pause.

First response is the first ticket comment authored by an internal user. That comment sets `first_responded_at` if it is null. A client comment does not stop the response clock. Resolution is the first transition into a status whose category is `closed`. That transition sets `resolved_at` if it is null. Reopening clears nothing about the historical breach flags. It MUST NOT restart a clock that already breached. It MAY start a fresh resolution clock only when `resolved_at` is cleared by the reopen transition. Reopen clears `resolved_at` and, if the contract still applies and the resolution had not breached, starts a new resolution walk from the reopen instant using the full resolution target. The response clock is not restarted if `first_responded_at` is already set.

The breach scanner runs at least every 30 seconds. For each active tenant it marks tickets whose `response_due_at` or `resolution_due_at` is at or before the scan time, sets the matching breach flag, opens an incident of source `sla` if one is not already open for that ticket and breach type, and writes an audit row. All of that is one transaction per tenant. The scanner MUST be safe when two API replicas run it: a conditional update that sets the breach flag only if it is still false is the lock. Exactly one replica observes the row as changed and only that replica opens the incident.

Escalation policies are ordered steps. Each step has `after_seconds` relative to incident open, and a list of notification targets. A target is a role, a specific user, or a webhook URL stored for a later delivery phase. Phase 2 persists the intent via the `Notifier` port at the moment the step becomes due. A second scanner, at least every 30 seconds, claims due steps with a conditional update so two replicas do not double-send.

Business hours, holidays, and the walk algorithm are product behavior. Implementations MUST cover them with unit tests: a deadline that lands inside a window, a deadline that skips a weekend, a deadline that skips a holiday, a pause that freezes remaining time, and a resume that continues the walk.

### FR-CRM-09 Comments

Comments are append-only in Phase 2. Authors MAY NOT edit or delete a comment through the API. A comment has a body, an author, a timestamp, and a visibility of `internal` or `client`. Client viewers MUST NOT read or write `internal` comments. The default visibility for a client author is `client`. The default for an internal author is `internal`, and the composer offers a control to switch to `client`.

## 5. Functional requirements — monitoring

### FR-MON-01 Monitored nodes

A node belongs to a tenant and MAY belong to a customer. A node without a customer is an internal asset of the MSP (their own domain controller, their own website). Client viewers MUST NOT see nodes with a null customer, and MUST NOT see another customer's nodes.

A node has a name, a kind, a check type, a target, a check interval, a status, schedule columns, optional `ssl_expires_at`, probe configuration in `metadata`, and `custom_attributes`.

Kinds: `server`, `network_switch`, `website`, `api_endpoint`, `ssl_certificate`, `cloud_instance`, `application`.

Check types and who performs them:

| Check | Performed by | Target |
| --- | --- | --- |
| `heartbeat` | Tenant-hosted agent, push | Agent identity. Target MAY be a hostname for display. |
| `http` | Platform scheduler, pull | Absolute `http` or `https` URL. |
| `tcp` | Platform scheduler, pull | `host:port`. |
| `ssl` | Platform scheduler, pull | Hostname, optional port, default 443. |
| `ping` | Platform scheduler, pull | Hostname or address. Implemented as a TCP connect timed handshake to the configured port, default 443, so the platform does not require raw ICMP sockets. |
| `resource` | Tenant-hosted agent, push | The agent reports CPU, memory, and disk. The target is a hostname for display. |

Intervals are integers from 15 to 86400 seconds. The scheduler MUST NOT run pulls faster than the interval. Agents SHOULD post on the interval. The stale-heartbeat rule uses the interval stored on the node, not the agent's claim.

Node status values: `unknown`, `up`, `degraded`, `down`, `maintenance`. `maintenance` suppresses opening a new incident for that node. It does not drop samples. Leaving maintenance allows the next evaluation to open an incident if the current sample is still bad.

### FR-MON-02 Heartbeat probes

An agent authenticates with an ingest credential and posts a heartbeat for a node the credential is allowed to update. The service sets `last_seen_at`, sets status to `up` when the node is not in maintenance, and writes a `heartbeat.ok` sample with value `1`.

A stale scanner runs at least every 15 seconds. A node whose check type is `heartbeat` or `resource` and whose `last_seen_at` is older than three intervals (or who has never been seen and was created more than three intervals ago) transitions to `down` and opens one open incident of source `heartbeat`. A later heartbeat resolves that incident and sets the node to `up`. The three-interval multiple is the default `missed_heartbeat_threshold` and MUST be stored on the node so a tenant admin can raise it for a chatty network.

### FR-MON-03 API and HTTP endpoint monitoring

The scheduler claims due `http` nodes with `FOR UPDATE SKIP LOCKED` inside the privileged claim function described in the architecture. For each claim it performs the request with a timeout of 10 seconds, follows at most three redirects, and records:

- `http.up` as `1` when the status code is in the node's expected set (default `{200}`), otherwise `0`.
- `http.latency_ms` as the elapsed milliseconds when a response arrived. A timeout records `http.up = 0` and omits latency.

`http.up = 0` sets node status to `down` and opens or refreshes an incident. `http.up = 1` sets status to `up` and resolves an open check incident for that node. The expected status set, the HTTP method, and a optional match substring live in `metadata`. Headers in `metadata` MUST NOT be returned to client viewers. The pull worker MUST NOT send tenant cookies to the target. Redirects MUST NOT be followed onto a different registrable domain than the original target. This stops a tenant from turning the scheduler into an open proxy.

### FR-MON-04 Server resource checks

The agent pushes samples for a `resource` node:

| Metric | Unit | Value |
| --- | --- | --- |
| `cpu.util_pct` | percent | 0 to 100 |
| `mem.util_pct` | percent | 0 to 100 |
| `disk.util_pct` | percent | 0 to 100, with `attributes.mount` set to the mount path |

A push of any of these also refreshes `last_seen_at` and satisfies the heartbeat rule for that node. The platform evaluates alert rules against the samples. The platform does not scrape the server itself.

### FR-MON-05 SSL expiration

An `ssl` check opens a TLS socket, reads the leaf certificate `notAfter`, and writes:

- `ssl.days_remaining` as the whole days from the check time to `notAfter`, which MAY be negative.
- `ssl_expires_at` on the node, denormalized so the expiring-certificate widget is an indexed query and not a scan of raw metrics.

Default alert rules created with the tenant, enabled, for every `ssl` node via a tenant-level rule with node kind scope `ssl_certificate`:

- Warning when `ssl.days_remaining` is less than 30.
- Critical when `ssl.days_remaining` is less than 7.

A failed handshake sets the node to `down` and records `ssl.days_remaining` as null for that sample (no metric row) plus `http.up`-equivalent `ssl.up = 0`.

### FR-MON-06 Application error logs

An `application` node accepts pushed counter samples:

| Metric | Unit | Meaning |
| --- | --- | --- |
| `app.error_count` | count | Errors observed by the agent during the interval. `attributes.service` names the process. |
| `app.ex_rate` | count per minute | Optional rate the agent already computed. |

Phase 2 stores counts, not log lines. A log pipeline, retention of message bodies, and stack-trace search are out of scope. The incident is the spike, via an alert rule on `app.error_count`.

### FR-MON-07 Alert rules

A tenant admin or technician MUST be able to create an alert rule with:

- A metric name from the catalog in the architecture document.
- A comparator: `gt`, `gte`, `lt`, `lte`, `eq`, `neq`.
- A numeric threshold.
- An aggregation: `last`, `avg`, `min`, `max`.
- A window in seconds. `0` means the current sample only.
- A severity: `info`, `warning`, `critical`.
- A scope: one node, or a filter of node kind and optional customer.
- A cooldown in seconds, default 300, during which a still-true rule does not open a second incident.
- An escalation policy.

Evaluation happens on the ingest path for the sample that just arrived, inside the ingest budget in [NFR-02](#nfr-02-metric-ingestion-latency). Windowed rules query the stored samples for that node, metric, and window. They MUST constrain the query by tenant, node, metric, and time so the composite index answers it.

A rule in `maintenance` on the node does not open an incident. It still stores the sample.

### FR-MON-08 Incidents and escalation

An incident is the operational object a technician works. Sources are `rule`, `heartbeat`, `check`, `sla`, and `block_hours`. An incident has a severity, a status (`open`, `acknowledged`, `resolved`), timestamps, the last observed value when a metric applies, a summary, and the node or ticket or order it refers to.

At most one unresolved incident exists for a given source key. The source key is `(rule, node)` for rules, `(heartbeat, node)`, `(check, node)`, `(sla, ticket, breach type)`, or `(block_hours, order, threshold)`. A partial unique index enforces this. Resolving the incident allows a later breach to open a new row.

Technicians and tenant admins MAY acknowledge and resolve incidents. Account managers MAY read incidents. Client viewers MAY read incidents on their own nodes and tickets, and the summary MUST be the same text internal users see for check and heartbeat incidents. SLA incident summaries visible to the client MUST omit internal comment text.

Escalation steps fire from incident `opened_at` plus `after_seconds`, using the policy on the rule, the SLA contract, or the tenant default policy. Acknowledging an incident MUST stop later escalation steps. Resolving an incident stops them as well.

Notification delivery in Phase 2 is the `Notifier` port. The port implementation writes `notification_intents` (see schema) and an audit row. It does not open a socket to an email server.

### FR-MON-09 Metric catalog

Producers MUST use these metric names. The ingest schema rejects unknown names so a typo cannot create an unbounded series.

| Name | Unit | Producer |
| --- | --- | --- |
| `heartbeat.ok` | 1 or 0 | Agent |
| `ping.rtt_ms` | milliseconds | Scheduler |
| `http.latency_ms` | milliseconds | Scheduler |
| `http.up` | 1 or 0 | Scheduler |
| `ssl.up` | 1 or 0 | Scheduler |
| `ssl.days_remaining` | days | Scheduler |
| `cpu.util_pct` | percent | Agent |
| `mem.util_pct` | percent | Agent |
| `disk.util_pct` | percent | Agent |
| `app.error_count` | count | Agent |
| `app.ex_rate` | count per minute | Agent |

Labels ride in the sample `attributes` object. `disk.util_pct` MUST include `mount`. `app.error_count` MUST include `service`. Other metrics MAY send an empty attributes object.

## 6. Functional requirements — dynamic engine

The engine lets a tenant admin change the shape of the product without a migration. Behavior of compilation, forms, and queries is specified in [04_DYNAMIC_ENGINE.md](04_DYNAMIC_ENGINE.md). This section is the product contract.

### FR-DYN-01 Custom fields

A tenant admin MUST be able to define fields on `crm_customer`, `crm_contact`, `crm_opportunity`, `crm_order`, `crm_order_line`, `crm_ticket`, `monitored_node`, and on a custom entity.

Each definition has:

| Property | Rule |
| --- | --- |
| Key | Immutable. `^[a-z][a-z0-9_]{0,39}$`. Unique among active fields for that target. |
| Label | Mutable. Shown in the form. |
| Data type | One of `text`, `number`, `boolean`, `enum`, `date`, `currency`. Immutable after create. The UI calls `enum` a dropdown. |
| Required | Mutable boolean. |
| Exposed to client | Mutable boolean, default false. Client viewers neither receive nor submit fields where this is false. |
| Enum options | Required for `enum`. Each option has a stable `value`, a `label`, and a `retired` flag. Cap 100. |
| Validation | Optional bounds: string length, numeric min and max, regex pattern, currency scale, currency code. |
| Layout | Section name and width (`half` or `full`) plus sort order. This is the per-tenant field layout. |
| Help text | Optional short string. |

Archiving a field removes it from forms and rejects new writes of that key. The stored JSONB value remains so history is readable. The key MAY be reused by a new active definition. Changing the data type of an existing key is rejected with `TYPE_IMMUTABLE`.

### FR-DYN-02 Field types

| Type | Stored JSON | Form control | Empty optional value |
| --- | --- | --- | --- |
| `text` | string | single-line input | key omitted |
| `number` | JSON number | numeric input | key omitted |
| `boolean` | JSON boolean | checkbox | key omitted. A boolean is never "blank" once set. Required booleans MUST be present. They MAY be false. |
| `enum` | string, one of the option values | select, or a CDK listbox when there are more than 15 options | key omitted |
| `date` | `YYYY-MM-DD` | date input | key omitted |
| `currency` | decimal string such as `"1999.50"` | text input with numeric input mode | key omitted |

Currency is a string so the payload does not pass through binary floating point. The scale MUST be less than or equal to the field precision, default 2. The currency code on the field defaults to the customer currency when the field is on a customer-scoped row, otherwise to the tenant currency.

Required means the key is present in the merged `custom_attributes` object after the write. Optional means the key MAY be absent. An explicit null in a patch clears an optional key and is rejected for a required key.

### FR-DYN-03 Per-tenant layouts

Field layout is configuration on the field definition (section, width, order). The customer form for tenant A and tenant B MAY group fields into different sections. The renderer groups active fields by section and places `half` fields in a two-column grid from the `md` breakpoint upward. `full` fields span both columns.

Dashboard layout is a separate object. Each internal role has one tenant layout, and a user MAY have one personal layout that overrides it. A layout has up to eight widgets. A widget has a type, a title, and a grid rectangle `{x, y, w, h}` on a 12-column grid.

Widget types for Phase 2:

| Type | What it shows |
| --- | --- |
| `ticket_queue` | Open tickets in client scope, oldest SLA risk first |
| `sla_risk` | Tickets whose response or resolution deadline falls within four hours, plus those already breached and unresolved |
| `node_health` | Counts of nodes by status |
| `metric_chart` | A time series for one node and metric, default last 24 hours |
| `open_incidents` | Unresolved incidents |
| `pipeline_value` | Sum of open opportunity amounts by stage |
| `block_hours` | Orders whose remaining hours are under 20 percent |
| `expiring_ssl` | Certificates with `ssl_expires_at` inside 30 days |
| `procurement` | Hardware and license lines not yet received |
| `custom_record_count` | Count of records for one custom entity |

A client viewer receives the `client_viewer` role layout only, and widgets in that layout MUST apply client scope. A client viewer MUST NOT save a layout that targets another customer. Phase 2 ships a default layout per role from `provision_tenant`. Tenant admins MAY edit role layouts. Any internal user MAY edit their personal layout.

The layout editor uses Angular CDK drag-and-drop to move widgets. Saving replaces the widget array after Zod validation.

### FR-DYN-04 Custom entities

A tenant admin MUST be able to create a custom entity with a key, a singular label, and a plural label. The key is immutable and uses the same pattern as field keys. Records of that entity have a title and `custom_attributes`, validated by the fields whose target is that entity.

Custom records are tenant-wide lists. They MAY optionally reference a customer so an MSP can attach, for example, a "site" or a "circuit" to an account. Client viewers see only records linked to their customer, and they do not see records with a null customer.

Phase 2 custom entities are not a general relational model. A custom record MUST NOT grow its own child tables. Associations are the optional customer reference plus custom fields of type `text` holding an identifier the tenant chooses to store. Richer relations are a later phase.

### FR-DYN-05 Status lifecycles

A tenant admin MUST be able to edit status definitions and transitions for `crm_customer`, `crm_opportunity`, `crm_order`, and `crm_ticket`. Each status has a key, a label, a sort order, a category (`open`, `pending`, `closed`), `is_initial`, `is_terminal`, `pauses_sla` (tickets only; ignored elsewhere), and `client_allowed` on transitions.

Exactly one status per entity is initial. The service rejects a second initial status. Terminal statuses have no outbound transitions except where the default ticket lifecycle explicitly allows reopen. Tenant edits MUST preserve that invariant: a transition from a terminal status is allowed only when the definition says `is_terminal = false`, or when the entity is `crm_ticket` and the transition is the reopen into `in_progress`.

Removing a status that live rows still use is rejected. Archiving it is the supported path.

### FR-DYN-06 Validation authority

The browser validates for responsiveness. The server validates for correctness. Every create and update MUST run the merged `custom_attributes` object through the Zod schema compiled from the tenant's active definitions. A payload that passes the form and fails the server MUST surface the server's field paths back on the form. The server MUST ignore a client-supplied `tenant_id` and MUST ignore custom-attribute keys the caller is not allowed to see.

Reads return stored custom attributes even if a later definition change would reject them, so historical values stay visible. The next successful write MUST leave the object valid against the current definitions.

## 7. Functional requirements — identity and audit

### FR-AUTH-01 Sessions

Login accepts email and password. The password verifier is Argon2id with a memory cost of 19 MiB, time cost of 2, and parallelism of 1. The database stores the hash only.

A successful login issues:

- An access token, lifetime 15 minutes, signed with EdDSA (Ed25519).
- A refresh token, lifetime 14 days, stored only as a hash, rotated on every refresh.

The access token claims are `sub` (user id), `tid` (tenant id), `role`, `cid` (customer id or null), `ver` (token version), `iat`, and `exp`. The issuer is `dynamic-crm`.

Presenting a refresh token that was already rotated revokes every refresh token in that family. Disabling a user increments `token_version`. The next request's session load MUST reject a token whose version lags the row. Logout revokes the presented refresh token.

### FR-AUTH-02 Ingest credentials

A tenant admin creates an ingest credential, sees the bearer token once, and the service stores only its SHA-256 hash. A credential is bound either to one node or to the tenant (a collector that may post for any node of the tenant). Revoking a credential sets `revoked_at` and subsequent presents fail with 401. Ingest credentials are not user sessions and MUST NOT be accepted on CRM routes.

### FR-AUD-01 Audit

Every successful mutation of CRM records, field definitions, status lifecycles, dashboard layouts, alert rules, users, and ingest credentials writes an `audit_logs` row in the **same database transaction** as the mutation. A failure to write the audit row rolls the mutation back.

The row records the actor, the action name (`crm.customer.update`), the entity type and id, `before_state`, `after_state`, the request id, and the caller IP. Secrets MUST be redacted before they are stored: password hashes, ingest token hashes, and authorization headers are replaced with the string `[redacted]`.

Audit rows are append-only for the runtime database role. The application exposes read access to tenant admins only. Client viewers MUST NOT read the audit log.

Ingest of metrics does not write a per-sample audit row. It writes an audit row when it opens or resolves an incident. High-rate samples are already stored in `telemetry_metrics`, and auditing each one would exceed the ingest budget.

## 8. Non-functional requirements

### NFR-01 Multi-tenant data segregation

Every tenant-owned table MUST include `tenant_id` and MUST have row-level security enabled and forced. The application runtime role MUST NOT have `BYPASSRLS`. The application process MUST refuse to boot if `current_user` is a superuser or has `BYPASSRLS`.

The request path MUST set `app.tenant_id` with `set_config(..., true)` so the value is local to the transaction and cannot leak across pooled connections. Repositories MUST take the tenant id from the server context, never from the JSON body or from a query string.

A client viewer MUST be constrained a second time, in the query, to their `customer_id`, on every table that carries `customer_id`. RLS isolates tenants. Customer scope isolates clients inside a tenant. Both are required.

Cross-tenant access to a specific id MUST return **404**. The response body MUST NOT reveal that the row exists in another tenant. An authenticated user who lacks the role for a route MUST receive **403**. A missing or invalid token MUST receive **401**.

Privileged cross-tenant reads are an allowlist of `SECURITY DEFINER` functions in the schema document: login lookup, session load, ingest-credential lookup, and the probe claim. New cross-tenant queries require a new function on that allowlist and a review of its `search_path`.

### NFR-02 Metric ingestion latency

For a batch of at most 20 samples for a single node, the API MUST acknowledge within **500 ms at p95** and within **1000 ms at p99**, measured at the HTTP boundary on the reference shape (two API replicas, database in the same region, the envelope in section 1.2). The acknowledgement is sent only after the transaction commits. The budget includes Zod validation, the insert, single-sample rule evaluation, and a windowed rule query when the window is at most 15 minutes.

Batches larger than 20 samples MAY commit the insert and enqueue evaluation. The 500 ms budget applies to the steady-state agent post, which is the MSP heartbeat and resource push.

The realtime fan-out happens by `LISTEN/NOTIFY` issued inside the transaction, so a rollback cannot emit. The HTTP handler MUST NOT wait for browser sockets to flush.

### NFR-03 Dashboard rendering

The summary endpoint that feeds the default role layout MUST respond within **200 ms at p95** for a tenant at the typical size, reading incidents, ticket SLA columns, node status counts, and the one-minute continuous aggregate (or the `date_trunc` fallback) rather than raw samples.

After the application shell is cached, the default dashboard of at most eight widgets MUST reach a usable state within **one second** on a broadband connection. Usable means the widget titles and their data are painted. The implementation uses OnPush change detection, signals for widget state, and a chart that consumes the aggregate buckets rather than every raw sample.

### NFR-04 Audit logging

See [FR-AUD-01](#fr-aud-01-audit). In addition, API logs are structured JSON and include `requestId`, `tenantId`, `userId`, and the route. Logs MUST omit authorization headers, cookies, ingest tokens, and password fields. A request id is generated when the caller did not send `x-request-id`, and it is echoed on the response.

### NFR-05 Availability and recovery targets

These are design targets for the Phase 2 deployment, not a contractual SLA to tenants.

| Target | Value |
| --- | --- |
| API availability | 99.9 percent monthly, excluding planned maintenance |
| Recovery point | 15 minutes, via continuous database archiving |
| Recovery time | 4 hours for a single-region restore |
| Backup | Daily base backup, seven days of point-in-time retention |

### NFR-06 Security baseline

- TLS 1.2 or newer on every public interface.
- Passwords hashed as in FR-AUTH-01. Bearer tokens stored only as SHA-256 hashes.
- Access tokens signed with EdDSA. Private keys come from the environment, not from a table.
- JSON bodies limited to 64 KiB on CRM routes and 256 KiB on ingest routes.
- Login and ingest routes rate-limited per source address and per account or credential.
- CORS allowlist configured by environment. Credentials are not accepted from a reflected origin.
- Dependency installation uses a lockfile. The runtime image contains production dependencies only.

### NFR-07 Time

Persisted instants are `timestamptz` in UTC. Dates without a time of day are `date`. The UI formats instants in the user timezone, then the tenant timezone, then UTC. Business-hour math uses the SLA contract timezone, not the viewer's timezone.

### NFR-08 Accessibility and responsive layout

Interactive pages MUST be usable at a 375 px wide viewport and at 1280 px. Form controls built by the dynamic form have associated labels, visible focus, and error text tied to the control. Color is not the only indicator of node status or severity. Charts expose a data table alternative of the same buckets.

## 9. Acceptance criteria

These are the scenarios Phase 2 treats as the definition of done. Identifiers are stable.

**AC-01 Tenant isolation.** Given two tenants each with a customer, when tenant A's runtime session requests tenant B's customer id, then the response is 404 and tenant B's audit log has no row from tenant A's user.

**AC-02 Client scope.** Given a client viewer for customer A, when they list tickets, nodes, and orders, then every row belongs to customer A, internal comments are absent, and custom fields with `exposed_to_client = false` are absent from the JSON.

**AC-03 Pipeline to order.** Given an opportunity in `proposal`, when the account manager moves it to `won` and creates an annual order with a license line in `to_order`, then the procurement list shows that line and a direct jump from `proposal` to `active` on the order is rejected if that transition was not defined.

**AC-04 Block hours.** Given a 10-hour bank and a ticket that logs 8.5 hours against it, when the ticket is saved, then consumed is 8.5 and the order is in the block-hour warning set. A second ticket of 2 hours moves the order to the critical set and opens one `block_hours` incident.

**AC-05 SLA walk.** Given a business-hours contract in `America/New_York`, windows Monday to Friday 09:00–17:00, and a ticket opened Friday at 16:00 local with a 4-hour response target, when deadlines are computed, then the response deadline is Monday at 12:00 local. Moving the ticket to `waiting_on_customer` clears the deadline. Moving it back continues from the remaining time.

**AC-06 SLA breach.** Given a ticket whose response deadline has passed and that has no internal comment, when the scanner runs, then `response_breached` is true and exactly one SLA incident exists. A second scanner pass does not create a second incident.

**AC-07 Ingest and alert.** Given a resource node and a rule "cpu.util_pct gt 90 for a single sample", when the agent posts 95, then the sample is readable, the node is `up`, an incident is open, and a websocket client in that tenant receives the incident after the HTTP acknowledgement. A post with a forged `tenant_id` in the body still writes the tenant bound to the ingest credential.

**AC-08 Heartbeat miss.** Given a heartbeat interval of 60 seconds and a threshold of 3, when no heartbeat arrives for 180 seconds, then the node becomes `down` and one heartbeat incident is open. A later heartbeat resolves it.

**AC-09 SSL widget.** Given a certificate whose `notAfter` is 10 days away, when the ssl check runs, then `ssl_expires_at` is set, `ssl.days_remaining` is 10, and the default critical rule is able to open an incident because 10 is not less than 7 and the warning rule opens because 10 is less than 30.

**AC-10 Custom field round trip.** Given a required enum field `plan` on customers with options `gold` and `silver`, when a customer is created with `plan = gold`, then the row's JSONB contains that key. A create without `plan` returns 422 with path `customAttributes.plan`. A filter for customers containing `plan = gold` returns that customer and no other tenant's customers.

**AC-11 Type immutability.** When a tenant admin attempts to change `plan` from `enum` to `text`, the response is 409 `TYPE_IMMUTABLE` and existing customers are unchanged.

**AC-12 Layout.** Given two tenants, when each saves a different section layout for the customer form, then each tenant's form renders its own sections and widths, and neither tenant's field definitions appear in the other's form metadata.

**AC-13 Audit atomicity.** When a customer update is forced to fail after the row write and before commit (test hook), neither the customer change nor an audit row is visible.

**AC-14 Revocation.** When an admin disables a technician, the technician's next API call with the old access token receives 401, even if the token's `exp` is still in the future.

**AC-15 Dashboard budget.** The summary endpoint for a fixture tenant of 40 customers, 300 nodes, and 1,000 open-or-recent tickets responds within the NFR-03 budget on the reference staging shape. CI uses a looser bound so a laptop run does not flap; the 200 ms figure is enforced in staging.

## 10. Requirement index

| ID | Summary | Primary store | Spec |
| --- | --- | --- | --- |
| FR-CRM-01 | Customer accounts | `crm_customers` | Schema |
| FR-CRM-02 | Contacts | `crm_contacts` | Schema |
| FR-CRM-03 | Pipeline | `crm_opportunities`, `status_*` | Schema |
| FR-CRM-04 | Orders and intervals | `crm_orders` | Schema |
| FR-CRM-05 | Procurement lines | `crm_order_lines` | Schema |
| FR-CRM-06 | Block hours | `crm_orders`, `crm_tickets` | Schema |
| FR-CRM-07 | Tickets | `crm_tickets` | Schema |
| FR-CRM-08 | SLA | `sla_contracts`, ticket SLA columns | Schema, this document |
| FR-CRM-09 | Comments | `ticket_comments` | Schema |
| FR-MON-01 | Nodes | `monitored_nodes` | Architecture scheduler |
| FR-MON-02 | Heartbeat | nodes, `telemetry_metrics` | Architecture |
| FR-MON-03 | HTTP checks | nodes, telemetry | Architecture |
| FR-MON-04 | CPU, memory, disk | telemetry | Dynamic engine catalog |
| FR-MON-05 | SSL | nodes.`ssl_expires_at`, telemetry | Schema |
| FR-MON-06 | App error counts | telemetry | Architecture |
| FR-MON-07 | Alert rules | `alert_rules` | Architecture |
| FR-MON-08 | Incidents, escalation | `alert_incidents`, `notification_intents` | Schema |
| FR-MON-09 | Metric names | ingest Zod schema | Architecture |
| FR-DYN-01 | Field definitions | `custom_field_definitions` | Dynamic engine |
| FR-DYN-02 | Field types | JSONB values | Dynamic engine |
| FR-DYN-03 | Layouts | field `layout`, `dashboard_layouts` | Dynamic engine |
| FR-DYN-04 | Custom entities | `custom_entity_definitions`, `custom_records` | Dynamic engine |
| FR-DYN-05 | Status lifecycles | `status_definitions`, `status_transitions` | Schema |
| FR-DYN-06 | Server-side validation | compiled Zod | Dynamic engine |
| FR-AUTH-01 | Sessions | `users`, `refresh_tokens` | Architecture |
| FR-AUTH-02 | Ingest credentials | `ingest_credentials` | Architecture |
| FR-AUD-01 | Audit | `audit_logs` | Architecture |
| NFR-01 | Segregation | RLS, `app.tenant_id` | Architecture, schema |
| NFR-02 | Ingest latency | pipeline | Architecture |
| NFR-03 | Dashboard | aggregates, signals | Architecture |
| NFR-04 | Audit and logs | `audit_logs` | Architecture |
| NFR-05 | Recovery targets | operations | Architecture |
| NFR-06 | Security baseline | platform | Architecture |
| NFR-07 | Time | `timestamptz` | Schema |
| NFR-08 | Accessibility | frontend | Dynamic engine |

## 11. Authorization matrix

"Own" means rows with the viewer's `customer_id`. "Read" for an internal role means every customer in the tenant.

| Capability | Tenant admin | Technician | Account manager | Client viewer |
| --- | --- | --- | --- | --- |
| Customers | Create, read, update, archive | Read, update notes and custom fields | Create, read, update, archive | Read own |
| Contacts | Full | Full | Full | Read own customer |
| Opportunities | Full | Read | Full | None |
| Orders | Full | Read | Full | Read own, without vendor and serial |
| Procurement list | Full | Read | Full | None |
| Tickets | Full | Full | Read | Create and read own, client transitions only |
| Comments | Full | Full | Read, write client-visible | Read and write client-visible on own tickets |
| SLA contracts | Full | Read | Full | Read own customer contract targets only |
| Nodes | Full | Full | Read | Read own |
| Ingest credentials | Full | Create and revoke for a node | None | None |
| Alert rules | Full | Full | None | None |
| Incidents | Acknowledge, resolve, read | Acknowledge, resolve, read | Read | Read own |
| Custom fields, entities, statuses | Full | Read | Read | Read the client-exposed subset |
| Users and roles | Full | None | None | None |
| Role dashboard layouts | Edit | Read | Read | Read the client layout |
| Personal dashboard layout | Edit own | Edit own | Edit own | None |
| Audit log | Read | None | None | None |

The shared package `packages/shared-types` MUST encode this matrix once. The API middleware and the Angular route guards both import it. A route that is missing from the matrix is denied.
