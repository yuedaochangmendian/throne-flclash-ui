# Prism UI: provenance

`flutter/lib/ui` is a fork of [`chen08209/prism_ui`](https://github.com/chen08209/prism_ui),
a Flutter UI kit, vendored into this repository. This document records where the copy
came from and what the license obligations are. It is a provenance record, not a
drift policy: the UI layer is owned by this project and evolves freely.

## Provenance

| Field | Value |
| --- | --- |
| Repo | `https://github.com/chen08209/prism_ui.git` |
| Originally vendored from | `5d8ed7ab674ed2011adf94a7e41aff6d705e9cb6` (2026-11-06, v0.1.2) |
| Files taken | 145 (`lib/**/*.dart`) |
| License | GPL-3.0 (third-party portions per `NOTICE`) |

## Why vendored

The kit was vendored rather than consumed from pub.dev because the app adds product
features inside the same layer and needs to change kit internals:

- The app-authored modules that live alongside the kit: the JSON-schema editor
  (`json/`, `json/engine/`), QR rendering (`qr_code.dart`, `qr_matrix.dart`), the
  page scaffold (`scaffold/`), the glyph set (`icons/app_glyphs.dart`), the fonts
  barrel, and the module barrel `ui.dart`.
- Shader assets move from `packages/prism_ui/shaders/...` to `shaders/...` because
  the kit is compiled into the app rather than resolved from a package namespace.

## Ownership

The vendored layer is **owned by this project**. There is no drift gate and no
requirement to keep any file byte-identical to upstream. Files may be rewritten,
merged, split or deleted as the app requires. Upstream remains a reference for
fixes worth taking, not an authority over the tree's shape.

## License obligations

`lib/ui` and `lib/ui/hct`, `lib/ui/shapes`, `lib/ui/sliver_list` derive from GPL-3.0
and MIT/Apache-2.0 sources. Do not remove:

- the repository `NOTICE` file;
- the `LicenseRegistry` entries registered in `flutter/lib/main.dart`;
- the per-file copyright headers carried over by the vendored files.
