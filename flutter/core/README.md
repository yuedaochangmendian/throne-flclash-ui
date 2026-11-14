# Core placeholder

The setup hook's repository probe (`setup_hooks/CoreBuilder.repositoryRoot`)
expects `<repo>/core/` to exist before it honours `build_assets: false`.

This fork does not vendor FlClash's mihomo core: the proxy core is Throne's
sing-box/Xray runtime, built by `buildScript/` into `app/libs/ThroneCore.aar`
and driven through `io.throne.bbox.corehost`. The setup hook is therefore kept
disabled (`build_assets: false` in pubspec) and this directory only marks the
repository root for the hook's validation.
