# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`appium_handler` is a Dart/Flutter **package** (not an app) that gets embedded into a Flutter app under test. It is the app-side counterpart of a customized Appium Flutter Driver + Appium Inspector stack that makes Appium Inspector work against Flutter apps via `"automationName": "flutter"`. This repo is one of three cooperating repos in that project:

- `appium-flutter-driver` (customized) — forwards `getWindowRect`/`getPageSource`/`performActions`/`findElement` to the app-under-test via the `flutter:requestData` VM-service call (see `driver/lib/commands/screen.ts` and the `executeCommand` overrides in `driver/lib/driver.ts` for the counterpart on that side).
- `appium-inspector` (customized) — GUI that renders the page source, hit-tests taps against it client-side (`utils/element-hit-testing.js`, parsing the same `bounds="[x1,y1][x2,y2]"` format `appium_handler.dart` emits), and records/generates test scripts. For a `flutter` session it always performs a coordinate-based tap (`actions/SessionInspector.js#tapFlutterWidgetAtCoordinates`) and reads back the `{foundBy, value}` the device resolved from the `performActions` response, then two Dart-specific code generators (`lib/client-frameworks/dart-integration-test.js`, `dart-patrol.js`, sharing `dart-common.js#getFlutterFinderExpression`) turn that into a `find.byXxx(...)` expression. This depends on exact string agreement with this package — see below.
- `appium-handler` (this repo) — runs inside the test target app, receives commands, and answers them using Flutter's internal widget inspector APIs.

**Protocol contract with the other two repos (verified compatible as of the last cross-check):** the `foundBy` values this package's `_driveFinder`/`_foundByFor` return (`byTooltip`, `bySemanticsLabel`, `byValueKey`, `byText`, `byType`) must exactly match the strings `dart-common.js#getFlutterFinderExpression`'s switch matches on in `appium-inspector`, since they round-trip through the `performActions` response (`{isError, response: {message: '<our _actionResult JSON>'}}`, per `flutter_driver`'s own `RequestDataResult`/`_requestData` wiring — nothing to change there, it's framework-internal) and are never re-validated at either end. `getFinderType`/`findByPosition` are implemented here but currently have **no caller** in either sibling repo — don't assume they're exercised by anything today. When touching finder-name strings in `_execCommandWithFinder`/`_driveFinder`/`_handleGetFinderType`, grep for the same literal in `appium-inspector`'s `dart-common.js` before renaming anything (a `'byToolTip'` vs `'byTooltip'` capitalization mismatch between `_handleGetFinderType` and `_execCommandWithFinder` was found and fixed here for exactly this reason).

The consuming app wires this package in with:

```dart
import 'package:flutter_driver/driver_extension.dart';
import 'package:appium_handler/appium_handler.dart';

void main() {
  final handler = AppiumHandler();
  enableFlutterDriverExtension(handler: handler.appiumHandler);
  handler.buildDriverExtension();
  runApp(const MyApp());
}
```

Managed with FVM; pinned Flutter version is in [.fvmrc](.fvmrc) (currently 3.44.6 stable). Prefer `fvm flutter ...` over a bare `flutter` if `fvm` is installed, so the pinned SDK is used.

## Commands

- Install deps: `fvm flutter pub get`
- Static analysis: `fvm flutter analyze` (uses `flutter_lints` via [analysis_options.yaml](analysis_options.yaml)) — should report no issues
- Run tests: `fvm flutter test` — currently a small smoke test in [test/appium_handler_test.dart](test/appium_handler_test.dart) exercising the unknown-command fallback and `getScreenSize`

`pubspec.yaml` intentionally only lists what `lib/` and `test/` actually import (`flutter`, `flutter_driver`, `flutter_test` as SDK deps, plus `xml`; `flutter_lints`/`test` as dev deps). Resist the urge to add packages "just in case" — a much larger, mostly-unused dependency list was previously the main reason `pub get` failed to resolve against newer Flutter SDKs.

## Architecture

Three files in `lib/` divide the work:

- **`appium_handler.dart`** — `AppiumHandler`. This is the entry point invoked by the driver extension (passed as `handler:` to `enableFlutterDriverExtension`, which registers it as the `flutter:requestData` callback). Its `appiumHandler(String? cmd)` method is a switch over command names sent from the Appium Flutter Driver side:
  - `getScreenSize` — returns logical screen size from `PlatformDispatcher`.
  - `getPageSource` — walks the widget tree twice: `layoutTree()` first collects bounds (position/size) per widget via `AppiumWidgetInspectorService.getLayoutExplorerNode`, then `visitorTree()` builds an XML document (`_document`/`_source`) describing every widget with id, key, text, tooltip, semanticLabel, bounds, and center coordinates. This XML is what Appium Inspector's "App Source" view renders and what later commands query against.
  - `getFinderType` / `findElement` / `findByPosition` — look up nodes in the cached `_document` by id, xpath, or screen coordinates, and decide *how* an element should be addressed. (As of the current `appium-flutter-driver` WIP, only `getPageSource`/`getWindowRect`/`performActions`/`findElement` have a driver-side caller; `getFinderType`/`findByPosition` are kept for completeness/future use.)
  - `performActions` — decodes a W3C Actions-style JSON payload (`pointerMove`/`pointerDown`/`pointerUp`/`enterText`/`checkText`/`checkExistence`) and dispatches the resulting tap/scroll/enter_text/check command through `_execCommandWithFinder`.

  `_execCommandWithFinder` encodes the **finder priority order** used whenever an element must be addressed: tooltip → semantics label → value key → text → widget type (first match wins, falling back down the chain), delegating the actual command construction to the shared `_driveFinder`/`_driveKey` helpers, which call into `AppiumHandlerDriverExtension`.

- **`widget_tree.dart`** — `AppiumWidgetInspectorService` (mixes in Flutter's own `WidgetInspectorService`). Exposes widget-tree/layout data that Flutter's public API doesn't surface directly: `getRootWidgetSummaryTreeWithPreviews` (full tree with text previews) and `getLayoutExplorerNode` (per-node render size + global position, pulled from `RenderBox`/`RenderView` internals). Its property-listing method is named `myGetProperties` (not `getProperties`) **on purpose** — `WidgetInspectorService` already defines a public `getProperties(String, String) -> String` (JSON-encoded) with an incompatible signature, so reusing that name is an invalid override. The whole file relies on `@visibleForTesting` framework internals (`InspectorSerializationDelegate`, `objectToDiagnosticsNode`), silenced file-wide via `ignore_for_file: invalid_use_of_visible_for_testing_member` since that's the entire point of this class.

- **`appium_handler_extension.dart`** — `AppiumHandlerDriverExtension`, a copy of `flutter_driver`'s internal `_FlutterDriverExtension`, kept local (and public) so `appium_handler.dart` can hold a reference to it and call `.call(params)` directly once it has resolved a finder for a screen position — `enableFlutterDriverExtension()` doesn't expose its extension instance otherwise. When bumping the Flutter SDK version, diff this file against the current `_FlutterDriverExtension` in `packages/flutter_driver/lib/src/extension/extension.dart` inside the SDK — its method signatures (e.g. `deserializeFinder`/`deserializeCommand` gaining an optional `{String? path}` parameter between Flutter 3.24 and 3.44) are the most likely source of breakage on an SDK bump.

When modifying finder/command behavior, keep in mind the data flows one direction per call: driver command string → `appiumHandler` switch → (for page source) walk widget tree via `AppiumWidgetInspectorService` → cache as XML in `_document` → later commands resolve elements against that cached XML, not a live widget tree query.

## Repo layout notes

The repo root also contains several near-duplicate long-form write-ups of this project as a Qiita article draft (`README.md`, `Qiita.md`, `ChatGPT.md`, `Gemini.md`, `perplexity.md`, `wrtn.md`, plus `images/`) — these are article drafts for publication, not architecture docs; don't treat divergences between them as bugs to reconcile.
