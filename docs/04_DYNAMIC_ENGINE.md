# Dynamic CRM — Dynamic configuration engine

| | |
| --- | --- |
| Status | Approved for Phase 2 implementation |
| Version | 1.0 |
| Date | 22 October 2026 (Asia/Calcutta) |
| Audience | Engineering and AI implementation agents |
| Governs | Custom fields, runtime validation, dynamic forms, and JSONB filters |

Product rules are FR-DYN-01 through FR-DYN-06 in [01_PRD.md](01_PRD.md). Storage is `custom_field_definitions`, `custom_entity_definitions`, `custom_records`, `entity_schema_revisions`, and the `custom_attributes` columns in [03_DATABASE_SCHEMA.md](03_DATABASE_SCHEMA.md). The module boundary is `dynamic-engine` in [02_ARCHITECTURE.md](02_ARCHITECTURE.md).

The engine has one job: a tenant admin changes a form, a lifecycle, or a dashboard by saving rows. The next request observes the change. No migration runs, and no backend process restarts.

## 1. Contract

`@dynamic-crm/shared-types` exports the types below. The database row uses snake_case. The HTTP body and the TypeScript types use camelCase. The repository is the only place that maps between them.

```ts
export type CustomFieldType =
  | "text"
  | "number"
  | "boolean"
  | "enum"
  | "date"
  | "currency";

export type FieldWidth = "half" | "full";

export interface EnumOption {
  value: string;
  label: string;
  retired?: boolean;
}

export interface FieldValidation {
  minLength?: number;
  maxLength?: number;
  min?: number;
  max?: number;
  pattern?: string;
  precision?: number;
  currencyCode?: string;
}

export interface FieldLayout {
  section: string;
  width: FieldWidth;
}

export interface CustomFieldDefinition {
  id: string;
  targetEntity: string;
  customEntityId: string | null;
  key: string;
  label: string;
  dataType: CustomFieldType;
  required: boolean;
  exposedToClient: boolean;
  helpText: string | null;
  enumOptions: EnumOption[];
  validation: FieldValidation;
  layout: FieldLayout;
  sortOrder: number;
  archivedAt: string | null;
}
```

Wire values for `dataType` are the enum labels. The UI calls `enum` a dropdown. Keys match `^[a-z][a-z0-9_]{0,39}$` and are immutable after insert, along with `dataType`, `targetEntity`, and `customEntityId`. The database trigger and the API both enforce that. The API returns `409 TYPE_IMMUTABLE` when the trigger would raise, by checking the change before the update so the client receives the stable code.

### 1.1 Stored JSON values

| Type | JSON value | Example |
| --- | --- | --- |
| `text` | string, already trimmed | `"Acme-West"` |
| `number` | finite JSON number | `12` |
| `boolean` | JSON boolean | `true` |
| `enum` | string equal to an option `value` | `"gold"` |
| `date` | `YYYY-MM-DD` | `"2026-10-22"` |
| `currency` | decimal string, no exponent | `"1999.50"` |

Currency is a string so the value never passes through binary floating point. Relational money elsewhere in the schema stays integer minor units. A custom currency field is a tenant-defined amount, not an order total.

Optional fields are omitted from the object. They are not stored as `null`. A boolean that has been set is always `true` or `false`. Required does not mean true: a required boolean may be `false`.

### 1.2 Who can write definitions

Only `tenant_admin` creates, updates, or archives definitions, entities, statuses, and role layouts. Internal roles read definitions for entities they can see. `client_viewer` receives the subset where `exposedToClient` is true, and receives neither archived definitions nor the validation pattern. The pattern is an internal constraint. The client still receives `required`, `dataType`, `enumOptions` that are not retired, `label`, `helpText`, and `layout`, because the form has to render.

## 2. Definition intake

Saving a definition is itself a Zod parse, against a fixed schema, before the row is written. Limits from the PRD:

| Rule | Limit |
| --- | --- |
| Active fields on one target | 50, also enforced by trigger |
| Custom entities | 20, also enforced by trigger |
| Enum options | 1 to 100 for `enum`, and an empty array otherwise |
| Label | 1 to 120 characters |
| Help text | at most 400 characters |
| Pattern | at most 200 characters, and it must compile as a JavaScript regular expression |
| `maxLength` | at most 2000 |
| `precision` | integer 0 to 4, default 2 for currency |
| Section name | 1 to 60 characters |
| Layout width | `half` or `full` |

The pattern is compiled once at save time with `new RegExp(pattern, "u")`. A pattern that does not compile is `422 VALIDATION_ERROR`. The engine later applies that pattern only to a string that has already been trimmed and rejected when longer than `maxLength` (or 2000 when `maxLength` is absent). Tenant patterns never see an unbounded string.

Removing an enum option is not a delete. The admin sets `retired: true`. Retired options stay in the stored array so existing rows still name a known value. Create forms hide retired options. An update may keep a retired value when it is unchanged and must reject it when the value changes. Section 3.3 states that rule in the compiler.

Archiving sets `archived_at`. The row remains. The partial unique index allows a later active field to reuse the key. Historical JSON that used the old key is preserved by the merge in section 4.

## 3. Runtime Zod compilation

The backend compiles a Zod schema from active definitions on each cache miss. Zod 3.24 is the API used here (`z.object`, `.strict()`, `.safeParse`). The server schema is the authority. The Angular validators in section 5 mirror it so the form fails early, and they are not trusted.

### 3.1 Cache

```ts
interface CompiledEntry {
  revision: number;
  schema: z.ZodType<Record<string, unknown>>;
}

const compiled = new Map<string, CompiledEntry>();

function cacheKey(tenantId: string, entityKey: string): string {
  return `${tenantId}:${entityKey}`;
}
```

`entityKey` is the `target_entity` string, or `custom_record:<uuid>` for a custom entity. The revision is the row in `entity_schema_revisions`. A miss, or a revision that does not match, loads the active definitions and compiles again.

Field writes bump the revision inside the same transaction as the definition change, then `pg_notify('dynamic_crm_events', { type: 'schema.invalidated', tenantId, entityKey })`. Every API replica drops that cache key when the notification arrives. A replica that missed the notification still recompiles because the next request compares revisions. The revision read is one primary-key lookup.

### 3.2 Compiler

```ts
import { z } from "zod";

const KEY = /^[a-z][a-z0-9_]{0,39}$/;
const ISO_DATE = /^(\d{4})-(\d{2})-(\d{2})$/;
const DECIMAL = /^-?\d+(\.\d+)?$/;

export interface CompileOptions {
  mode: "create" | "update";
  /** Current stored value for this key, used to allow an unchanged retired option. */
  previous?: Record<string, unknown>;
  /** When true, enum options with retired=true are hidden from acceptance of new values. */
  enforceRetired: boolean;
}

export function compileCustomAttributesSchema(
  definitions: CustomFieldDefinition[],
  options: CompileOptions,
): z.ZodType<Record<string, unknown>> {
  const active = definitions.filter((field) => field.archivedAt === null);
  const shape: Record<string, z.ZodTypeAny> = {};

  for (const field of active) {
    const previous = options.previous?.[field.key];
    shape[field.key] = wrapPresence(fieldSchema(field, previous, options), field);
  }

  return z.object(shape).strict();
}

function wrapPresence(schema: z.ZodTypeAny, field: CustomFieldDefinition): z.ZodTypeAny {
  if (field.required) {
    return schema;
  }
  return schema.optional();
}

function fieldSchema(
  field: CustomFieldDefinition,
  previous: unknown,
  options: CompileOptions,
): z.ZodTypeAny {
  const rules = field.validation;
  switch (field.dataType) {
    case "text":
      return textSchema(rules);
    case "number":
      return numberSchema(rules);
    case "boolean":
      return z.boolean();
    case "enum":
      return enumSchema(field, previous, options);
    case "date":
      return z.string().regex(ISO_DATE, "Use YYYY-MM-DD").refine(isRealDate, "Invalid date");
    case "currency":
      return currencySchema(rules);
    default: {
      const exhaustive: never = field.dataType;
      throw new Error(`Unknown field type ${exhaustive}`);
    }
  }
}

function textSchema(rules: FieldValidation): z.ZodTypeAny {
  const max = Math.min(rules.maxLength ?? 2000, 2000);
  let schema = z.string().trim().max(max);
  if (rules.minLength !== undefined) {
    schema = schema.min(rules.minLength);
  }
  if (rules.pattern !== undefined) {
    schema = schema.regex(new RegExp(rules.pattern, "u"));
  }
  return schema;
}

function numberSchema(rules: FieldValidation): z.ZodTypeAny {
  let schema = z.number().finite();
  if (rules.min !== undefined) {
    schema = schema.min(rules.min);
  }
  if (rules.max !== undefined) {
    schema = schema.max(rules.max);
  }
  return schema;
}

function enumSchema(
  field: CustomFieldDefinition,
  previous: unknown,
  options: CompileOptions,
): z.ZodTypeAny {
  const allowed = new Set(
    field.enumOptions
      .filter((option) => options.enforceRetired === false || option.retired !== true || option.value === previous)
      .map((option) => option.value),
  );
  return z.string().refine((value) => allowed.has(value), "Select a listed option");
}

function currencySchema(rules: FieldValidation): z.ZodTypeAny {
  const scale = rules.precision ?? 2;
  return z
    .string()
    .regex(DECIMAL, "Enter a decimal amount")
    .refine((value) => decimalScale(value) <= scale, `Use at most ${scale} decimal places`)
    .refine((value) => rules.min === undefined || Number(value) >= rules.min, "Below the minimum")
    .refine((value) => rules.max === undefined || Number(value) <= rules.max, "Above the maximum");
}

function decimalScale(value: string): number {
  const dot = value.indexOf(".");
  return dot === -1 ? 0 : value.length - dot - 1;
}

function isRealDate(value: string): boolean {
  const match = ISO_DATE.exec(value);
  if (!match) {
    return false;
  }
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const date = new Date(Date.UTC(year, month - 1, day));
  return (
    date.getUTCFullYear() === year &&
    date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day
  );
}
```

`compileCustomAttributesSchema` is called with the active rows only. Archived rows are consulted by the merge function, not by `.strict()`, so a historical key does not become an "unrecognized key" inside the active schema. See section 4.

`KEY` is checked when the definition is saved, not on every attribute value. Values do not have to match the key pattern.

For a `client_viewer`, the service passes only definitions with `exposedToClient === true`. The merge then refuses patch keys outside that set, which is what keeps an internal field from being overwritten by a client payload that names it.

### 3.3 Retired options

`enforceRetired` is true for creates and for updates whose incoming value differs from `previous`. The `allowed` set includes a retired option only when that option's value equals the previous stored value. A create has no previous value, so retired options are excluded. An update that submits the same retired value still validates. An update that changes `gold` (retired) to `silver` (active) validates. An update that changes `silver` to `gold` fails.

The form hides retired options, so this path is the API backstop.

## 4. Merge on write

Creates and updates both end by validating the **active** attribute object that will be stored. The database column receives that object plus preserved archived keys.

```ts
export function mergeCustomAttributes(input: {
  definitions: CustomFieldDefinition[];
  stored: Record<string, unknown>;
  patch: Record<string, unknown> | undefined;
  mode: "create" | "update";
  /** True for client_viewer. Internal and archived keys are copied from storage and are not writable. */
  clientVisibleOnly: boolean;
}): Record<string, unknown> {
  const writable = input.definitions.filter((field) => {
    if (field.archivedAt !== null) return false;
    if (input.clientVisibleOnly && !field.exposedToClient) return false;
    return true;
  });
  const writableKeys = new Set(writable.map((field) => field.key));
  const archivedKeys = new Set(
    input.definitions.filter((field) => field.archivedAt !== null).map((field) => field.key),
  );
  const patch = input.patch ?? {};

  for (const key of Object.keys(patch)) {
    if (archivedKeys.has(key) || (input.clientVisibleOnly && !writableKeys.has(key))) {
      const code = archivedKeys.has(key) ? "archived" : "unrecognized_keys";
      throw new AppError(422, "VALIDATION_ERROR", "Custom field cannot be written", [
        { path: `customAttributes.${key}`, code, message: "Unknown field" },
      ]);
    }
    if (!writableKeys.has(key)) {
      throw new AppError(422, "VALIDATION_ERROR", "Unknown custom field", [
        { path: `customAttributes.${key}`, code: "unrecognized_keys", message: "Unknown field" },
      ]);
    }
  }

  const merged: Record<string, unknown> = {};
  for (const field of writable) {
    if (Object.prototype.hasOwnProperty.call(patch, field.key)) {
      if (patch[field.key] === null) continue;
      merged[field.key] = patch[field.key];
    } else if (input.mode === "update" && Object.prototype.hasOwnProperty.call(input.stored, field.key)) {
      merged[field.key] = input.stored[field.key];
    }
  }

  const parsed = compileCustomAttributesSchema(writable, {
    mode: input.mode,
    previous: input.stored,
    enforceRetired: true,
  }).safeParse(merged);
  if (!parsed.success) {
    throw zodToAppError(parsed.error);
  }

  const preserved: Record<string, unknown> = {};
  if (input.mode === "update") {
    for (const field of input.definitions) {
      const keep = field.archivedAt !== null || (input.clientVisibleOnly && !field.exposedToClient);
      if (keep && Object.prototype.hasOwnProperty.call(input.stored, field.key)) {
        preserved[field.key] = input.stored[field.key];
      }
    }
  }

  return { ...preserved, ...parsed.data };
}
```

`preserved` is applied first and `parsed.data` second, so a writable key always wins over a stale preserved copy. Internal keys are never in `parsed.data` for a client caller, because those definitions were not compiled into the schema.

Consequences, all required:

- A create body with an unknown key is 422.
- A patch that names an archived key is 422. The stored value stays until a later successful write. Because the patch is rejected entirely, the archived value is not cleared by a client that still has the old form open.
- A patch that omits a key leaves the stored active value in place.
- A patch that sends `null` for an optional key removes it. `null` for a required key fails the compiled schema because the key is then absent.
- After the merge, required active keys must be present. Adding a required field makes the next save of an old record fail until the form supplies it. The read path still returns the old record.
- A `client_viewer` write with `clientVisibleOnly: true` validates only exposed active keys and copies every other stored key through `preserved`. The caller passes the full stored object so retired-option checks still see that viewer's previous value for exposed fields.

`zodToAppError` maps each issue to `{ path: "customAttributes." + issue.path.join("."), code, message }` and status 422. The Angular form binder in section 5.4 writes those paths back onto controls.

Empty strings are handled before merge. The HTTP layer trims text. A trimmed empty string becomes `null` in the patch, which clears an optional text field and fails a required one.

## 5. Angular dynamic form

The form is a standalone component. It does not generate source code. It builds a `FormGroup` from the same definition list the API returns.

State around the form uses signals. The form itself stays a reactive `FormGroup`, which is the Phase 2 form API. `NgRx` and other global stores are not introduced for field state.

### 5.1 Factory

```ts
import { Injectable } from "@angular/core";
import { FormControl, FormGroup, ValidatorFn, Validators } from "@angular/forms";

@Injectable({ providedIn: "root" })
export class DynamicFormFactory {
  buildGroup(
    fields: readonly CustomFieldDefinition[],
    value: Record<string, unknown>,
  ): FormGroup {
    const group = new FormGroup({});
    const ordered = [...fields].sort((a, b) => a.sortOrder - b.sortOrder);
    for (const field of ordered) {
      group.addControl(
        field.key,
        new FormControl(displayValue(field, value[field.key]), {
          nonNullable: field.dataType === "boolean" || field.dataType === "text",
          validators: validatorsFor(field),
        }),
      );
    }
    return group;
  }
}

function displayValue(field: CustomFieldDefinition, raw: unknown): unknown {
  if (raw === undefined || raw === null) {
    return field.dataType === "boolean" ? false : "";
  }
  return raw;
}

function validatorsFor(field: CustomFieldDefinition): ValidatorFn[] {
  const rules = field.validation;
  const validators: ValidatorFn[] = [];
  if (field.required && field.dataType !== "boolean") {
    validators.push(Validators.required);
  }
  if (field.dataType === "text") {
    if (rules.minLength !== undefined) validators.push(Validators.minLength(rules.minLength));
    validators.push(Validators.maxLength(Math.min(rules.maxLength ?? 2000, 2000)));
    if (rules.pattern !== undefined) validators.push(Validators.pattern(rules.pattern));
  }
  if (field.dataType === "number" || field.dataType === "currency") {
    if (rules.min !== undefined) validators.push(Validators.min(rules.min));
    if (rules.max !== undefined) validators.push(Validators.max(rules.max));
  }
  if (field.dataType === "date") validators.push(Validators.pattern(/^\d{4}-\d{2}-\d{2}$/));
  if (field.dataType === "currency") validators.push(Validators.pattern(/^-?\d+(\.\d+)?$/));
  if (field.dataType === "enum") validators.push(enumValidator(field));
  return validators;
}
```

`enumValidator` rejects a value that is not in the non-retired options, and it accepts the control's current value when that value is a retired option already present. Currency scale uses a small `ValidatorFn` that mirrors `decimalScale`. Date reality uses the same UTC calendar check as `isRealDate`.

Boolean controls are `nonNullable` and default to `false`. A required boolean is satisfied by `false`. The factory does not add `Validators.required` for booleans, matching the Zod schema, which treats `false` as present.

Number controls hold `number | null`. The template binds `type="number"`. On submit, an empty numeric input is sent as `null`.

### 5.2 Page wiring

The customer page owns core controls. The factory owns only `customAttributes`.

```ts
import { ChangeDetectionStrategy, Component, effect, inject, signal } from "@angular/core";
import { FormControl, FormGroup, Validators } from "@angular/forms";

@Component({
  selector: "app-customer-page",
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: "./customer-page.component.html",
})
export class CustomerPageComponent {
  readonly fields = signal<CustomFieldDefinition[]>([]);
  readonly record = signal<{ name: string; customAttributes: Record<string, unknown> } | null>(null);
  readonly form = signal<FormGroup | null>(null);

  private readonly factory = inject(DynamicFormFactory);

  constructor() {
    effect(() => {
      const fields = this.fields();
      const record = this.record();
      if (!record) return;
      this.form.set(
        new FormGroup({
          name: new FormControl(record.name, { nonNullable: true, validators: [Validators.required] }),
          customAttributes: this.factory.buildGroup(fields, record.customAttributes),
        }),
      );
    });
  }
}
```

`record` is a signal populated by the HTTP resource. Rebuilding the `FormGroup` when definitions change discards in-progress edits, which is acceptable because a definition change is rare and the revision notification is the signal to reload. The effect lists only signals it reads.

Submit maps the nested group back to JSON:

```ts
const raw = this.form()?.getRawValue();
const customAttributes: Record<string, unknown> = {};
for (const field of this.fields()) {
  const value = raw.customAttributes[field.key];
  if (field.dataType === "text" && typeof value === "string" && value.trim() === "") {
    customAttributes[field.key] = null;
    continue;
  }
  if ((field.dataType === "number" || field.dataType === "currency" || field.dataType === "date" || field.dataType === "enum") && value === "") {
    customAttributes[field.key] = null;
    continue;
  }
  customAttributes[field.key] = field.dataType === "text" && typeof value === "string" ? value.trim() : value;
}
```

The page posts `{ name, customAttributes }`. Core Zod on the route parses `name`. `mergeCustomAttributes` parses `customAttributes`.

### 5.3 Renderer

`DynamicFormComponent` is standalone, `OnPush`, and imports `ReactiveFormsModule`. Inputs are signals.

```ts
@Component({
  selector: "app-dynamic-form",
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [ReactiveFormsModule],
  templateUrl: "./dynamic-form.component.html",
})
export class DynamicFormComponent {
  readonly fields = input.required<CustomFieldDefinition[]>();
  readonly group = input.required<FormGroup>();

  readonly sections = computed(() => {
    const groups = new Map<string, CustomFieldDefinition[]>();
    for (const field of [...this.fields()].sort((a, b) => a.sortOrder - b.sortOrder)) {
      const name = field.layout.section;
      const list = groups.get(name) ?? [];
      list.push(field);
      groups.set(name, list);
    }
    return [...groups.entries()].map(([label, fields]) => ({ label, fields }));
  });
}
```

The template groups sections in definition order and lays fields out on a 1-column grid that becomes 2 columns from the `md` breakpoint. `width: "full"` spans both columns. This is the per-tenant layout from FR-DYN-03. Two tenants with different `layout.section` values render different headings without a code change.

```html
<div [formGroup]="group()" class="space-y-8">
  @for (section of sections(); track section.label) {
    <section>
      <h2 class="text-sm font-semibold text-slate-900">{{ section.label }}</h2>
      <div class="mt-4 grid grid-cols-1 gap-4 md:grid-cols-2">
        @for (field of section.fields; track field.key) {
          <div [class.md:col-span-2]="field.layout.width === 'full'">
            <label class="block text-sm font-medium text-slate-800" [attr.for]="controlId(field.key)">
              {{ field.label }}
              @if (field.required) { <span class="text-red-700">*</span> }
            </label>

            @switch (field.dataType) {
              @case ("text") {
                <input
                  [id]="controlId(field.key)"
                  type="text"
                  class="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-sky-700 focus:outline-none focus:ring-2 focus:ring-sky-700/30"
                  [formControlName]="field.key"
                  [attr.aria-invalid]="invalid(field.key)"
                  [attr.aria-describedby]="describedBy(field)"
                />
              }
              @case ("number") {
                <input [id]="controlId(field.key)" type="number" step="any"
                  class="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
                  [formControlName]="field.key" [attr.aria-invalid]="invalid(field.key)" />
              }
              @case ("boolean") {
                <input [id]="controlId(field.key)" type="checkbox" class="mt-2 h-4 w-4"
                  [formControlName]="field.key" />
              }
              @case ("date") {
                <input [id]="controlId(field.key)" type="date"
                  class="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
                  [formControlName]="field.key" [attr.aria-invalid]="invalid(field.key)" />
              }
              @case ("currency") {
                <input [id]="controlId(field.key)" type="text" inputmode="decimal"
                  class="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
                  [formControlName]="field.key" [attr.aria-invalid]="invalid(field.key)" />
              }
              @case ("enum") {
                @if (activeOptions(field).length > 15) {
                  <app-enum-listbox [id]="controlId(field.key)" [field]="field" [formControlName]="field.key" />
                } @else {
                  <select [id]="controlId(field.key)"
                    class="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
                    [formControlName]="field.key" [attr.aria-invalid]="invalid(field.key)">
                    <option value="">Select</option>
                    @for (option of activeOptions(field); track option.value) {
                      <option [value]="option.value">{{ option.label }}</option>
                    }
                  </select>
                }
              }
            }

            @if (field.helpText) {
              <p class="mt-1 text-sm text-slate-600" [id]="helpId(field.key)">{{ field.helpText }}</p>
            }
            @if (errorMessage(field.key); as message) {
              <p class="mt-1 text-sm text-red-700" [id]="errorId(field.key)">{{ message }}</p>
            }
          </div>
        }
      </div>
    </section>
  }
</div>
```

`app-enum-listbox` is a standalone CDK listbox (`@angular/cdk/listbox`) inside a `CdkConnectedOverlay`, and it implements `ControlValueAccessor` so `formControlName` binds the option `value` string. It is used when a dropdown has more than 15 options, which is the point where a native `<select>` stops being comfortable to scan. The listbox supports typeahead through the CDK listbox keyboard model. Options with `retired === true` are omitted by `activeOptions`, unless the control's current value equals that retired option, in which case the current option is included and disabled so the user can see it and change it.

Control ids are `cf-<key>` and are unique inside the form. `aria-describedby` points at the help id and the error id when those elements exist. `aria-invalid` is true when the control is invalid and touched, or when a server error is set.

### 5.4 Server errors

```ts
export function applyServerFieldErrors(
  group: FormGroup,
  details: readonly { path: string; message: string }[],
): void {
  for (const detail of details) {
    const prefix = "customAttributes.";
    if (!detail.path.startsWith(prefix)) {
      continue;
    }
    const key = detail.path.slice(prefix.length);
    const control = group.get(key);
    control?.setErrors({ server: detail.message });
    control?.markAsTouched();
  }
}
```

`errorMessage` prefers the `server` error, then required, min, max, minlength, maxlength, and pattern. The message text for client-side errors is fixed in the component. The server message is shown as sent, and the API already uses short field messages rather than SQL or Zod internals.

### 5.5 Validator parity

| Constraint | Zod | Angular |
| --- | --- | --- |
| Required text, number, enum, date, currency | key must be present after merge | `Validators.required` |
| Required boolean | `z.boolean()`, `false` allowed | control defaults to `false`, no `required` validator |
| Text length | `.trim().min().max()` with a hard cap of 2000 | `minLength` / `maxLength` |
| Text pattern | `.regex` after the length cap | `Validators.pattern` |
| Number bounds | `.finite().min().max()` | `Validators.min` / `max` plus a finite check |
| Enum membership | refine against options, retired rule in 3.3 | `enumValidator` |
| Date | regex and UTC calendar check | `type="date"` plus the same calendar validator |
| Currency scale | decimal string, scale ≤ precision | `inputmode="decimal"` plus the same scale validator |

When the two sides disagree, the server result is the one that is stored. The form displays it.

### 5.6 Dashboard layout editor

The dashboard editor is the other dynamic surface. It is not the field form. `DashboardLayoutComponent` loads the resolved layout and edits a `widgets` signal. Reorder and move use `@angular/cdk/drag-drop`. Each widget is a drag item on a 12-column grid. Dropping updates `{x, y, w, h}` in the signal. Save `PUT`s the array. The body is validated by a fixed Zod schema: at most 8 widgets, known `type` from the PRD catalog, grid numbers inside the 12-column frame. Unknown widget types are 422.

Chart widgets receive buckets from `GET /dashboard` or from the node series endpoint. Chart.js draws pipeline and count widgets. ECharts draws `metric_chart`. The series input is a signal. The chart component is `OnPush` and updates when that signal changes, including when `RealtimeStore` replaces a node snapshot.

## 6. Querying custom attributes

Every repository statement includes `tenant_id = $1` from the request context. RLS repeats that restriction. Soft-deleted rows are excluded unless the caller is a tenant admin reading history.

Containment uses the GIN index (`jsonb_ops`):

```sql
SELECT id, name
FROM crm_customers
WHERE tenant_id = $1
  AND deleted_at IS NULL
  AND custom_attributes @> '{"plan":"gold"}'::jsonb;
```

Several keys in one containment object are an AND:

```sql
SELECT id, name
FROM crm_customers
WHERE tenant_id = $1
  AND deleted_at IS NULL
  AND custom_attributes @> '{"plan":"gold","region":"east"}'::jsonb;
```

Key existence, also served by `jsonb_ops`:

```sql
SELECT id, name
FROM crm_customers
WHERE tenant_id = $1
  AND deleted_at IS NULL
  AND custom_attributes ? 'circuit_id';
```

Extraction for equality on a single text or enum value:

```sql
SELECT id, name
FROM crm_customers
WHERE tenant_id = $1
  AND deleted_at IS NULL
  AND custom_attributes ->> 'plan' = 'gold';
```

Numeric and date comparisons cast the extracted text. These predicates do not use the GIN index. They are correct filters; they become index scans only after the expression index in section 6.1 exists.

```sql
SELECT id, name
FROM crm_customers
WHERE tenant_id = $1
  AND deleted_at IS NULL
  AND (custom_attributes ->> 'seat_count') ~ '^-?[0-9]+(\.[0-9]+)?$'
  AND (custom_attributes ->> 'seat_count')::numeric >= 50;
```

```sql
SELECT id, name
FROM crm_customers
WHERE tenant_id = $1
  AND deleted_at IS NULL
  AND custom_attributes ->> 'renewal_on' >= '2026-01-01';
```

A node filter joined back to its customer, still inside one tenant:

```sql
SELECT n.id, n.name, c.name AS customer_name
FROM monitored_nodes AS n
JOIN crm_customers AS c
  ON c.id = n.customer_id
 AND c.tenant_id = n.tenant_id
WHERE n.tenant_id = $1
  AND n.deleted_at IS NULL
  AND c.deleted_at IS NULL
  AND n.custom_attributes @> '{"site_code":"BLR-1"}'::jsonb;
```

The list endpoint for a custom field filter accepts a JSON body:

```json
{ "contains": { "plan": "gold" }, "equals": { "region": "east" }, "min": { "seat_count": 50 } }
```

The repository allows `contains` and `equals` keys only when a definition exists for that target and the value's JSON type matches the field type. It builds the containment object with bound parameters, not with string concatenation. `min` and `max` are emitted as the cast predicate above, and only for `number` and `currency`. A key that is not a definition is 422. A `client_viewer` filter that names a field with `exposedToClient = false` is 422, the same as an unknown key, so the response does not reveal that the field exists.

Currency lower bounds compare the decimal string only after a scale check. The SQL casts `->>` to `numeric`, which is exact.

### 6.1 Expression index for a hot range

When a tenant actually filters a numeric key often enough to show up in a slow-query sample, add a partial expression index in a new migration. Do not add it to `001_core.sql`. The predicate avoids indexing rows whose historical text would not cast.

```sql
CREATE INDEX crm_customers_seat_count_idx
  ON crm_customers (
    tenant_id,
    ((custom_attributes ->> 'seat_count')::numeric)
  )
  WHERE deleted_at IS NULL
    AND (custom_attributes ->> 'seat_count') ~ '^-?[0-9]+(\.[0-9]+)?$';
```

The matching query must repeat the regex predicate so the planner can use the partial index. The filter builder does that for every numeric `min` / `max`.

GIN remains the index for `@>` and `?`. The expression index is an additional structure for one known key. The engine does not create it automatically in Phase 2.

## 7. Custom entities and statuses

A custom entity is a definition plus rows in `custom_records`. Fields whose `custom_entity_id` matches are compiled with entity key `custom_record:<uuid>`. Record create and update call `mergeCustomAttributes` the same way customers do. The optional `customer_id` is a real foreign key, validated by `custom_records_same_tenant`, not a custom field.

Status lifecycles are configuration of a different shape. They are not compiled to Zod from field definitions. The ticket service loads `status_transitions` for the tenant and rejects a `statusKey` with no edge from the current key. The cache revision is `status:crm_ticket` (and the sibling entity keys). A client viewer may only traverse edges with `client_allowed = true`. The initial status on create is the single row with `is_initial` and `archived_at` null.

## 8. Failure modes

| Situation | Result |
| --- | --- |
| Payload key has no active definition | 422 on `customAttributes.<key>` |
| Payload names an archived key | 422, stored value unchanged because the request is rejected |
| Required key missing after merge | 422 |
| Type of an existing definition changed | 409 `TYPE_IMMUTABLE` |
| 51st active field | 422 from the API count check, or the trigger if a race passes it |
| Client sends an internal key | 422 unrecognized key |
| Definition saved on replica A, request arrives on replica B before notify | B reads the new revision and recompiles |
| Historical value no longer matches a tightened regex | Read succeeds. The next write must produce a valid active object |

Reads do not run the write schema. A list of customers returns stored `custom_attributes` with internal keys removed for `client_viewer` by a projection, not by Zod rejection. The projection drops keys whose definition is missing, archived, or `exposedToClient = false` when the caller is a client viewer. Internal callers receive the stored object, including archived keys, so a report can still show a retired circuit id.
