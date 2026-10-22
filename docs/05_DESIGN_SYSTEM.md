# Dynamic CRM — Color scheme and UI shell

| | |
| --- | --- |
| Status | Binding for every UI task |
| Version | 1.0 |
| Date | 22 October 2026 (Asia/Calcutta) |

This is the only visual language for the product. Cursor, Antigravity, and any other agent apply it on every task. A screen that needs a color not listed here stops and uses the nearest token. It does not add a new hue.

The theme is light. There is no dark theme. Do not add `dark:` variants, a theme toggle, or a second palette.

## 1. Tokens

Phase 2 puts this block in `packages/frontend/src/styles.css` and does not add other color variables.

```css
:root {
  --color-canvas: #f8fafc;
  --color-surface: #ffffff;
  --color-surface-muted: #f1f5f9;
  --color-ink: #0f172a;
  --color-ink-secondary: #1e293b;
  --color-ink-muted: #475569;
  --color-ink-subtle: #64748b;
  --color-border: #cbd5e1;
  --color-border-subtle: #e2e8f0;
  --color-primary: #0369a1;
  --color-primary-hover: #075985;
  --color-primary-soft: #f0f9ff;
  --color-on-primary: #ffffff;
  --color-success: #047857;
  --color-success-soft: #ecfdf5;
  --color-warning: #b45309;
  --color-warning-soft: #fffbeb;
  --color-danger: #b91c1c;
  --color-danger-soft: #fef2f2;
  --color-focus: #0369a1;
  --chart-1: #0369a1;
  --chart-2: #0f766e;
  --chart-3: #b45309;
  --chart-4: #334155;
  --chart-5: #be123c;
  --chart-6: #047857;
}
```

Tailwind utilities are the way components paint. Use only the classes in the tables below. They match the variables. Arbitrary values such as `bg-[#112233]` and `text-purple-600` are outside the scheme.

## 2. Allowed Tailwind classes

### Surfaces, text, borders

| Role | Classes |
| --- | --- |
| App canvas | `bg-slate-50` |
| Card, nav, top bar | `bg-white` |
| Muted well | `bg-slate-100` |
| Primary text | `text-slate-900` |
| Secondary text | `text-slate-800` or `text-slate-700` |
| Muted text | `text-slate-600` |
| Subtle text, unknown status | `text-slate-500` |
| Default border | `border-slate-200` |
| Stronger border, inputs | `border-slate-300` |
| Divider | `divide-slate-200` |

### Primary action

| Role | Classes |
| --- | --- |
| Primary button | `bg-sky-700 text-white hover:bg-sky-800` |
| Primary soft wash | `bg-sky-50 text-sky-800` |
| Link | `text-sky-700 hover:text-sky-800` |
| Focus | `focus:border-sky-700 focus:outline-none focus:ring-2 focus:ring-sky-700/30` |

### Status

Color is never the only signal. Pair it with a word or an icon.

| State | Text | Wash |
| --- | --- | --- |
| Up, success, resolved | `text-emerald-700` | `bg-emerald-50` |
| Degraded, warning, SLA risk | `text-amber-700` | `bg-amber-50` |
| Down, critical, error | `text-red-700` | `bg-red-50` |
| Maintenance, unknown, paused | `text-slate-600` | `bg-slate-100` |
| Info | `text-sky-700` | `bg-sky-50` |

Incident severity uses the same mapping: `info` → sky, `warning` → amber, `critical` → red.

### Buttons

| Kind | Classes |
| --- | --- |
| Primary | `inline-flex items-center rounded-md bg-sky-700 px-3 py-2 text-sm font-medium text-white hover:bg-sky-800 focus:outline-none focus:ring-2 focus:ring-sky-700/30` |
| Secondary | `inline-flex items-center rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-800 hover:bg-slate-50` |
| Danger | `inline-flex items-center rounded-md border border-red-700 bg-white px-3 py-2 text-sm font-medium text-red-700 hover:bg-red-50` |
| Danger confirm | `inline-flex items-center rounded-md bg-red-700 px-3 py-2 text-sm font-medium text-white hover:bg-red-800` |

`bg-red-800` is allowed only on the danger-confirm hover. No other red background is allowed.

## 3. Chart series

Chart.js and ECharts use these hex values, in this order, and no library default palette.

| Token | Hex | Use |
| --- | --- | --- |
| `--chart-1` | `#0369a1` | Primary series |
| `--chart-2` | `#0f766e` | Second series |
| `--chart-3` | `#b45309` | Third series |
| `--chart-4` | `#334155` | Fourth series |
| `--chart-5` | `#be123c` | Fifth series |
| `--chart-6` | `#047857` | Sixth series |

`#0f766e` and `#be123c` appear only inside charts. They are not button, badge, or link colors.

Grid lines are `#e2e8f0`. Axis labels are `#475569`. The tooltip surface is `#ffffff` with border `#cbd5e1` and text `#0f172a`.

## 4. Shape, type, and shell

| Decision | Value |
| --- | --- |
| Font | Tailwind's default sans. No webfont, no `font-serif`. |
| Identifiers and metric numbers | `font-mono text-sm` |
| Control radius | `rounded-md` |
| Card and dialog radius | `rounded-lg` |
| Pill radius | `rounded-full` only for a status dot or an avatar |
| Control shadow | `shadow-sm` |
| Card shadow | `shadow-sm` |
| Page title | `text-xl font-semibold text-slate-900` |
| Section title | `text-sm font-semibold text-slate-900` |
| Body | `text-sm text-slate-700` |

The signed-in shell is fixed:

- Canvas: `min-h-screen bg-slate-50 text-slate-900`
- Left navigation: `w-60 shrink-0 border-r border-slate-200 bg-white`
- Top bar: `flex h-14 items-center border-b border-slate-200 bg-white px-4`
- Main: `flex-1 p-6`
- Active nav item: `bg-sky-50 text-sky-800`
- Inactive nav item: `text-slate-700 hover:bg-slate-50`
- Card: `rounded-lg border border-slate-200 bg-white p-4 shadow-sm`

Inputs follow the dynamic form classes in [04_DYNAMIC_ENGINE.md](04_DYNAMIC_ENGINE.md): white surface, `border-slate-300`, sky focus ring, `text-sm`, `rounded-md`. Error text is `text-sm text-red-700`. Help text is `text-sm text-slate-600`.

## 5. What agents must not add

- A new brand color, gradient, glass effect, or illustration style.
- Purple, indigo, pink, orange, lime, or fuchsia utilities.
- A dark theme.
- A component library (Material, PrimeNG, Bootstrap, daisyUI, shadcn). Styling is Tailwind utilities from this document plus Angular CDK for behavior.
- A second button style or a one-off hex in a component.

When a status is shown, include the status word. The wash color supports the word. It does not replace it.
