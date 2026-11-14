# UI consistency contract

This is the app-side contract for finishing the Prism UI migration. It preserves
Throne's routes, settings, state and platform contracts. A visual cleanup must
not create a second theme or a second settings/data path.

## References

- [Prism UI v0.1.2, commit `5d8ed7ab`](https://github.com/chen08209/prism_ui/tree/5d8ed7ab674ed2011adf94a7e41aff6d705e9cb6): source of the vendored primitives and their measurements.
- [FlClash surface specification](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/.agents/surfaces.md): the surface document referenced by Prism's source comments.
- [FlClash UI implementation conventions](https://github.com/chen08209/FlClash/blob/7fd417fb9a9a277c6a9339a8ac87f907df7c25f7/.agents/skills/ui-work/SKILL.md): shape, component and testing conventions.

These are reference specifications, not instructions to replace Throne's feature
set or copy FlClash's providers and data layer. The application-owned components
in `lib/widgets.dart` and `lib/components/` are the compatibility layer. Prefer
using or extending those over editing the vendored `lib/ui/` implementation.

## Surfaces and state

Use `SurfaceLevel` and `SurfaceScope`, not a page-specific fill palette:

| Level | Light role | Dark role | Content |
| --- | --- | --- | --- |
| `page` | `surfaceContainer` | `surface` | Page bodies and ordinary sheets |
| `card` | `surfaceBright` | `surfaceContainer` | Cards, grouped rows, light floating surfaces |
| `block` | `surfaceContainer` | `surfaceContainerHigh` | Tiles, wells and unselected segments in a card |
| `inset` | `surfaceContainerHighest` | `surfaceContainerHighest` | Small glyph wells, badges and tracks |

A shared surface reads `context.raisedSurfaceLevel` and gives that level to its
children with `SurfaceScope`. Do not select a different color based on whether
the same widget happens to be in a page or a sheet. Dark sheets retain the
existing elevated color scheme; floating surfaces use `SurfaceLevel.floatingOf`.

Use lightness steps for structure. Ordinary scrolling-list cards have no shadow.
Only floating surfaces and the dashboard's elevated cards may carry the existing
measured shadows. Do not introduce structural outlines or tonal-container fills
as substitutes for surface levels.

- Selection keeps the surface fill and adds a primary `SelectionCheck` or
  `SelectionBadge`. Only a chosen segment in a segmented group uses a solid
  primary fill with `onPrimary`.
- Status belongs on text, a glyph or a small chip, not a whole card. Error rows
  use `errorContainer` and `onErrorContainer`; destructive alerts use
  `colorScheme.destructive`.
- Titles and values use `onSurface`; secondary text uses `onSurfaceVariant`.
  `outline` and primary-tinted body text are not text-role substitutes.
- The first chart series is primary. The second is primary at 45% over the card,
  not an unrelated tertiary color. Preserve semantic route/action colors.

## Shape and spacing

Radii come from `AppCorner` / `AppShape`, never a new call-site radius:

| Content | Token |
| --- | --- |
| Small controls | `sm` (8) |
| Interactive chrome | `md` (16) |
| Medium cards | `lg` (20) |
| Full-width panels and record cards | `xl` (24) |
| Large sheets | `xxl` (28) |
| Alerts | `alert` (34) |
| Pills | `full` |

`AppCorner.fit(shortestSide)` handles size-dependent shapes. Derive a nested
radius from the parent's inset when the parent has a fixed token. An alert is
not a sizing reference for a normal card.

Use `boxPagePadding` for ordinary page bodies: 16 dp horizontal gutters,
`contentTopPadding`, and 24 dp plus `bottomInset` at the foot. A page starting
with a grouped section may use `sectionsTopPadding` instead. Preserve intentional
maximum content widths and grid-column calculations; unify the gutters rather
than forcing every information-dense page into one column.

Use `AppTextStyle` and the semantic `listTitleStyle`, `listSubtitleStyle`,
`listCaptionStyle`, `cardHeaderStyle` and `listValueStyle`. Tabular figures are
appropriate for changing numeric values. JetBrains Mono remains appropriate for
code, JSON and terminal content. Do not add hard-coded UI font sizes.

Keyboard and remote focus retain Prism's 2 dp primary ring and its stand-off.
Icon-only buttons need tooltips. Text scaling from 0.8 through 1.4, light/dark,
pure black and Liquid Glass remain supported.

## Components and routes

- Ordinary pages use `BoxPage`; bespoke grids and slivers may retain their
  `Scaffold` but use `boxPagePadding` and the same section primitives.
- Content panels use `BoxPanel`. Grouped rows use `generateSection`,
  `generateGroup` and `ListItem`. There is no `BoxListItem` component.
- Alerts use `showAppDialog` (the typed wrapper over `showFloatingDialog`) and
  Prism `AlertDialog`. Use its normal text/field/action layout instead of
  hand-padding a dialog hosted by a Material route.
- Single-choice lists use `showOptionSheet`; preserve the option identifiers,
  typed result, current selection, cancellation and dismissal behavior.
- Use `openPage` for secondary pages and `openForm` for forms. Keep
  `BoxEditGuard`, dirty/busy state and the originating navigator intact.
- Grouped fields use `FormRowTextField`. Standalone fields use the themed
  `AppShape.input`; search and alert fields use their Prism filled treatment.
  Preserve keyboard type, suggestions, obscured text and formatters.
- Primary actions use the appropriate Prism `TonalButton` or `FilledButton`;
  alert actions use `TextButton`; overflow actions use `BoxMenu`.
- Use `ActivityIndicator`, not Material's progress indicator. Prefer
  `EmptyState` / `ErrorState`; retain `NullStatusSwitcher` where its sliver
  sizing is required and document why.

## Deliberate exceptions

Speed gauges, charts, theme previews, dashboard drag previews, proxy stack
previews, code/terminal rendering and app-icon artwork may need custom painting.
That does not permit a separate visual vocabulary for their surrounding panels.
Preserve these implementations unless a concrete overflow, contrast or token
violation is being fixed. Keep `route_texts.dart`'s semantic action palette,
but name it rather than treating it as a generic surface color.

Do not change bridge methods, settings keys, state semantics, provider/data
code, localization keys or public form/page signatures as part of this work.
If a shared primitive lacks a necessary capability, report it to the
coordinator instead of creating a page-local alternative.

## Verification

Run `flutter analyze --fatal-infos` and all Flutter tests with coverage. Use
`test/support/test_app.dart`, `host_scaffold.dart` and `errors.dart` for focused
widget tests. Extend the existing `RepaintBoundary` screenshot coverage for
360, 600, 840 and 1280 dp, light/dark and text scales 1.0/1.4. Do not introduce
cross-platform pixel goldens; font rasterization differs between Windows and
Linux. Screenshots remain under the ignored `flutter/build/screenshots/`.

Inspect the rendered results for missing surface scopes, surviving tonal
container fills, text overflow, contrast, keyboard focus, selection marks and
navigation occlusion. Passing widget tests is not a substitute for that review.
