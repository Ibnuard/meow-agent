# DESIGN_2.md — Meow Agent Design System

> Visual identity, layout, spacing, and component rules — grounded in the
> ACTUAL implementation (`lib/app/theme.dart`, `lib/app/widgets/`,
> `lib/app/shell.dart`). When this conflicts with feel-good prose elsewhere,
> the code is the source of truth and this doc tracks it.
>
> Companion: **[AGENTS_2.md](./AGENTS_2.md)** (dev rules), **[ARCHITECTURE_2.md](./ARCHITECTURE_2.md)** (runtime).

---

## 1. Identity

Meow Agent is a **modern Android-native AI companion OS** — calm, futuristic,
lightweight, ambient, premium, minimal, approachable.

It is NOT a developer dashboard, terminal, enterprise admin panel, or
hacker/cyberpunk UI. Inspiration: OpenAI mobile, Arc Search, Linear, Perplexity,
Raycast, Nothing OS, visionOS floating surfaces.

Design test for anything you build:
> "Does this feel like a calm futuristic AI companion?" — if no, simplify.

---

## 2. Core Principles

1. **Controlled emptiness** — the UI breathes. Spacing, rhythm, hierarchy, subtle
   contrast. Never overfill or tightly stack.
2. **Floating surfaces** — cards detached from the background: rounded, soft
   shadow, translucent, subtle depth. No flat harsh containers or heavy dividers.
3. **Soft futuristic** — futuristic without neon/cyberpunk overload or excessive
   gradients. Ambient, not loud.
4. **Calm interaction** — smooth, subtle, premium motion. No aggressive bounce or
   flashy transitions.

---

## 3. Theme Tokens (from `lib/app/theme.dart`)

**Never hardcode these in a widget.** Read them via `context.cs` (ColorScheme)
and `context.extras` (`MeowExtras` ThemeExtension, `theme.dart:125-128`).

### 3.1 Accent

| Token | Value |
|-------|-------|
| Accent (light) | `0xFF2563EB` (`_accentLight`) |
| Accent (dark) | `0xFF3B82F6` (`_accentDark`) |

### 3.2 ColorScheme (dark — primary target)

| Role | Value |
|------|-------|
| surface | `0xFF020817` (deep navy) |
| onSurface (text primary) | `0xFFE5E7EB` |
| onSurfaceVariant (text secondary) | `0xFF94A3B8` |
| outline | `0xFF374151` |
| error | `0xFFEF4444` |

### 3.3 `MeowExtras` (custom tokens)

| Token | Dark | Light |
|-------|------|-------|
| `card` | `0xD90F172A` (navy 85%) | `0xFFF7F8FA` |
| `subtleText` | `0xFF64748B` | `0xFF94A3B8` |
| `subtleBorder` | `0x14FFFFFF` | `0xFFF1F5F9` |
| `success` | `0xFF22C55E` | `0xFF22C55E` |
| `navBackground` | `0xBF0F172A` (75%) | `0xE6FFFFFF` |
| `navInactive` | `0xFF64748B` | `0xFF94A3B8` |
| `navActive` | white | `0xFF0F172A` |
| `navBorder` | `0x14FFFFFF` | `0x1A000000` |
| `gradientEnd` | `0xFF1E3A8A` | `0xFF1E40AF` |
| `inputFill` | `0xFF0F172A` | `0xFFF1F5F9` |
| `inputBorder` | `0x14FFFFFF` | `0xFFE2E8F0` |
| `inputFocusBorder` | `0xFF3B82F6` | `0xFF3B82F6` |
| `inputFocusGlow` | `0x333B82F6` | `0x1A3B82F6` |

Rule: never use thick borders, bright outlines, or hard dividers. Borders are
faint (`subtleBorder` / `navBorder`).

---

## 4. Radii

No named constants — these are the established per-component values. Match them.

| Component | Radius |
|-----------|--------|
| Cards (`MeowCard`) | 20 |
| Buttons | 16 |
| Inputs (`MeowInput`) | 18 |
| Dialogs | 24 |
| Dropdown | 14 (dense) / 18 (normal) |
| Floating dock | 40 |
| FAB | 16 (rounded rectangle) — **never** `CircleBorder()` |

The visual language is **rounded rectangles**, not circles (the one exception is
the featured center chat button, which is intentionally circular).

---

## 5. Spacing Scale

| Context | Value |
|---------|-------|
| Section title → subtitle | 10–14 |
| Subtitle → input | 8–10 |
| Input → input | 14–18 |
| Section → section | 24–32 |
| Card internal padding | 18–24 (default 20) |

`MeowSection` (`meow_section.dart`) encodes this with `bottomSpacing` default 28.
Use it to group fields rather than stacking raw `SizedBox`es.

---

## 6. Typography

Font: `GoogleFonts.inter` (`theme.dart:178,193`). Modern, calm, readable. Avoid
oversized headings, heavy bold, compressed text.

| Role | Style |
|------|-------|
| AppBar / screen title | 17 / w600 |
| Section title | 15 / w600 |
| Section subtitle | 13 |
| Body button | 15 / w600 |
| Field label | small, muted (secondary hierarchy) |
| Helper text | 12 |

---

## 7. Components (`lib/app/widgets/`, exported from `widgets.dart`)

Use these; do not rebuild equivalents. (Names below are the REAL ones — there is
no `AppScaffold`/`GlassCard`/`MeowTextField`/`PrimaryButton`/`SectionHeader`.)

| Widget | File | Purpose / key params |
|--------|------|----------------------|
| `MeowSection` | `meow_section.dart:14` | Section container: `title`, `subtitle`, `padding`, `bottomSpacing` (28), `child` |
| `MeowInput` | `meow_input.dart:12` | The text field. `controller`, `label`, `hint`, `helper`, `obscureText`, `keyboardType`, `validator`, `onChanged`, `suffixIcon`, `maxLines`, `errorText`, `maxLength`, `showCounter`. External floating label, focus border shift |
| `MeowDropdown<T>` | `meow_dropdown.dart:39` | Generic dropdown (bottom-sheet or popup). Options `MeowDropdownOption<T>`; static `showSheet<T>()` at `:88`; searchable |
| `MeowAgentIcon` | `meow_agent_icon.dart:13` | Agent avatar from `iconKey`/`colorKey`; `agent`, `size` (30), `iconSize`, `radius` |
| `MeowCard` | `meow_card.dart:14` | Glass-surface card. `padding` (20), `blur` (backdrop blur 16σ), `child`. Uses `extras.card` + `extras.subtleBorder`, radius 20 |
| `MeowPrimaryButton` | `meow_button.dart:8` | Gradient primary CTA w/ glow. `label`, `icon`, `onPressed`, `loading`, `expand` (true) |
| `MeowSecondaryButton` | `meow_button.dart:100` | Outlined button. `+ danger` (→ error color) |
| `showMeowConfirmDialog` | `meow_confirm_dialog.dart:13` | `Future<bool>` confirm dialog (see §10) |

When you need new shared UI, add it here and export from `widgets.dart` — do not
create a one-off styled container in a screen.

---

## 8. Navigation & FAB (`lib/app/shell.dart`)

### 8.1 Floating glass dock (NOT Material `NavigationBar`)

`AppShell` (`shell.dart:18`) uses a custom `_GlassDock` (`:198`):
`BackdropFilter` blur 22σ, radius 40, fill `extras.navBackground`, border
`extras.navBorder`, height 64, lifted above the gesture inset. `extendBody: true`.

5 tabs (`_tabs`, `:27-53`): Home, Activity, **featured center Chat**, Agent,
Settings. The center `_FeaturedChatButton` (`:309`) is a circular gradient button
(`_accentLight`→`_accentDark`) overlapping the dock by 20px, with unread badge /
activity pulse overlays. It is the heart of the app — slightly larger, softly
glowing, never oversized or neon.

Tab labels come from `AppStrings` via `_labelFor(item, strings)` (`:158`).

### 8.2 Material FAB (list screens only)

Screens that own their own `Scaffold` (not inside the bottom-nav shell) use a
unified add-action FAB:

```dart
FloatingActionButton(
  backgroundColor: cs.primary,
  foregroundColor: Colors.white,
  elevation: 0,
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
  child: const Icon(Icons.add_rounded, size: 28),
)
```

Real usages: `provider_list_screen.dart:36`, `notes_list_screen.dart:227`,
`api_store_screen.dart:159`, `workflow_list_screen.dart:213`.

Rules:
- Hide the FAB in multi-select mode (`_selectionMode ? null : FAB`).
- Screens **inside** the bottom-nav shell (e.g. Agent list) use an AppBar action
  instead — the floating dock clips FABs unpredictably.
- Never `CircleBorder()`.

---

## 9. Safe Area & Edge-to-Edge

Always support Android edge-to-edge, gesture navigation, and the floating dock.
UI must never collide with the gesture area, nav bar, or the dock. Use `SafeArea`
and respect the dock's bottom inset.

---

## 10. Dialogs & Snackbars

### 10.1 `showMeowConfirmDialog` (`meow_confirm_dialog.dart:13`)

The reusable confirm/destructive dialog. Returns `Future<bool>` (true =
confirmed). Params: `title`, `message`, `confirmLabel`, `cancelLabel`, `icon`
(default `delete_outline_rounded`), `destructive` (default true). Rounded-24
`AlertDialog` with an icon chip; accent = `cs.error` when destructive, else
`cs.primary`. Labels default from `AppStrings`.

> Note: this helper currently takes an `isId` param. Per AGENTS_2.md §1, callers
> must resolve and pass finished strings rather than threading `isId` from a
> screen; prefer supplying explicit localized `title`/`message`/labels.

### 10.2 Snackbars

No bespoke helper widget. Styled globally via `SnackBarThemeData`
(`theme.dart:296-300`): floating, `inverseSurface` background. Call inline with
`ScaffoldMessenger`, and source the message text from `AppStrings`
(e.g. `s.copiedToClipboard`).

---

## 11. States

### 11.1 Empty states
Educate and guide — friendly, never cold. Structure:
**Icon/illustration → Title → Description → Primary Action.** Copy via `AppStrings`
(e.g. `noAgentsYet` / `noAgentsCreate`).

### 11.2 Loading / error
Use Riverpod `.when()` consistently: a spinner for loading, a localized message
(`errorWithMessage`) for error. Don't silently collapse an error to an empty box
where the user expects content.

### 11.3 Motion
Fade, smooth slide, subtle scale, gentle glow pulse. No spring explosions,
exaggerated bounce, or flashy transitions.

---

## 12. Inputs & Buttons

- **Inputs**: soft, rounded (18), slightly translucent (`inputFill`), faint
  border (`inputBorder`); on focus, glow blue (`inputFocusBorder` +
  `inputFocusGlow`). Never the raw Flutter `TextField` look. Use `MeowInput`.
- **Buttons**: soft, premium, rounded (16), minimal elevation. Primary CTA =
  blue accent with subtle glow (`MeowPrimaryButton`); secondary = outlined
  (`MeowSecondaryButton`, `danger` for destructive). No bulky/enterprise buttons.
- **Icons**: consistent stroke weight, minimal, slightly rounded. Don't mix
  filled/outline/thin/thick randomly.

---

## 13. Quick Checklist

- [ ] Colors/borders read from `context.cs` / `context.extras` — no hex literals.
- [ ] Radii and spacing match §4 / §5.
- [ ] Reused a `Meow*` widget instead of a one-off container.
- [ ] FAB is a rounded rectangle (16), hidden in multi-select; shell screens use
      an AppBar action instead.
- [ ] Copy via `AppStrings`; empty/loading/error states present and localized.
- [ ] Respects SafeArea and the floating dock inset.
- [ ] Feels calm and ambient — not a dashboard.
