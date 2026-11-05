# Generated UI models

`models.freezed.dart` is the Freezed companion for `../models.dart`. The source
model file declares its classes with `@freezed` and pulls this file in with
`part 'generated/models.freezed.dart';`.

## Where it came from

The file was produced by `build_runner` / `freezed` from `../models.dart` and
checked into the repository. It is generated code: do not edit it by hand.

## Why it is not regenerated in this repository

`flutter/pubspec.yaml` deliberately has no `build_runner` or `freezed`
dev dependency, and `pubspec.lock` is frozen because CI scans the built AAR's
public API and relies on a locked dependency set. Adding a generator or changing
the lock file would break that gate, so there is no in-repo regeneration step.
The generated file is kept as a checked-in artifact and is only refreshed when
the model source changes.

## How to check / regenerate manually

1. Run the static consistency check from the repository root:

   ```
   python3 tools/diagnostics/generated_models_check.py
   ```

   It compares the `@freezed` class names in `../models.dart` with the
   `mixin _$X` / `class _X` shapes in `models.freezed.dart`. Exit code 1 with a
   list of missing or stale names means the two files are out of sync.

2. If the check fails (or a `@freezed` model was added, removed or changed),
   regenerate `models.freezed.dart` in a scratch checkout that has
   `build_runner` and `freezed` available:

   ```
   dart run build_runner build --delete-conflicting-outputs
   ```

   Copy only the resulting `models.freezed.dart` back, then re-run the check
   above. Do not commit the generator dependencies or a changed `pubspec.lock`.

3. Keep `models.freezed.dart` marked as generated (`coverage:ignore-file`,
   `ignore_for_file`) so `flutter analyze --fatal-infos` and the widget tests
   treat it as-is.
