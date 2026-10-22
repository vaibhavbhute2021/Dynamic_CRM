---
trigger: always_on
description: Binding Dynamic CRM color scheme and UI shell. Apply on every task.
---

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
