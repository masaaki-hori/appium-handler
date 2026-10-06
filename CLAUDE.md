# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. It states the rules; the reasons and history behind them are in [docs/design-notes.md](docs/design-notes.md).

## What this is

`appium_handler` is a Dart/Flutter **package** (not an app) embedded into a Flutter app under test. It is the app-side part of a customized stack that lets Appium Inspector and generated test scripts drive Flutter apps (`"automationName": "flutter"`):

- `appium-flutter-driver` (customized) forwards `getWindowRect`/`getPageSource`/`performActions`/`findElement` to the app via the `flutter:requestData` VM-service call (`driver/lib/commands/screen.ts`, `executeCommand` in `driver/lib/driver.ts`).
- `appium-inspector` (customized) renders the page source, hit-tests clicks against its `bounds`, records actions and generates code (`lib/client-frameworks/dart-common.js`, `js-wdio.js`).
- `appium-handler` (this repo) runs inside the app, answers those commands and drives widgets through flutter_driver.

The app wires it in with:

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

## Commands

- `fvm flutter pub get` / `fvm flutter analyze` (should report no issues) / `fvm flutter test`
- Flutter is pinned in [.fvmrc](.fvmrc) (3.38.9; the `.fvm/version` file is stale — `.fvmrc` is authoritative). Use `fvm flutter ...`, not a bare `flutter`.
- Check another SDK without changing the pin: `fvm spawn <version> analyze` / `fvm spawn <version> test` (no `flutter` word), then `fvm flutter pub get` to restore. Run both the pinned version and the newest one you care about when touching framework internals.
- `pubspec.yaml` lists only what `lib/` and `test/` import (`flutter`, `flutter_driver`, `flutter_test`, `xml`; `flutter_lints`/`test` as dev deps). Don't add packages "just in case" — a larger dependency list used to break `pub get` on newer SDKs.

## Protocol contract (keep in sync with appium-inspector and appium-flutter-driver)

These strings and formats are never validated at either end, so a mismatch fails silently. Grep the other two repos for the same literal before renaming anything.

- **`foundBy` values**: `byTooltip`, `bySemanticsLabel`, `byValueKey` (value = the plain string of a `ValueKey<String>`), `byFieldLabel` (value `<Type>|<label>`), `byText`, `byType` (value `<Type>` or `<Type>#<N>`) — matched by `dart-common.js#getFlutterFinderExpression`.
- **`performActions` action types**: W3C `pointerMove`/`pointerDown`/`pointerUp`/`pause`, plus `tap`, `tapDirect`, `checkExistence`, `enterText`, `checkText`, with optional `elementId` (a page-source `id`) and/or `foundBy`/`value` (replay without coordinates). Matched by the Inspector's `SCREENSHOT_INTERACTION_MODE`/`actions/SessionInspector.js`.
- **Response** (`_actionResult`): `{text, elementId, type, foundBy, value, submitted}`; `submitted: true` after `enter_text` sent `done` (the Inspector emits a matching `TextInputAction.done` step).
- **Page-source attributes**: `bounds="[x1,y1][x2,y2]"` (parsed by the Inspector's `element-hit-testing.js`), `typeIndex` (see below), `label`/`hint` on `TextField`/`TextFormField`, and diagnostics on the root `<tree>`: `offstageFilter`, `hiddenElements`, `skippedNodes`, `unresolvedNodes`, `collapsedNodes`.
- `getFinderType`/`findByPosition` exist but have no caller in the sibling repos.

## Architecture

- **`lib/appium_handler.dart`** — `AppiumHandler.appiumHandler(String? cmd)` switches on the command: `getScreenSize`, `getPageSource`, `performActions`, `findElement`, `getFinderType`, `findByPosition`. `getPageSource` builds the XML in two passes (`layoutTree()` for bounds, `visitorTree()` for nodes) and caches it as `_document`; actions resolve their target node against it (`_resolveNode`, `_getNodeFromOffset` → `_hitTestNodeFromOffset`, `_findNodeByLocator`) and run through `_execCommandWithFinder`.
- **`lib/widget_tree.dart`** — `AppiumWidgetInspectorService` (mixes in `WidgetInspectorService`): the summary tree and per-node layout. Rebuilds the assert-guarded serialization so it also works in Profile/Release. Its property method is named `myGetProperties` on purpose (`getProperties` would be an invalid override). Relies on `@visibleForTesting` internals (silenced file-wide).
- **`lib/appium_handler_extension.dart`** — custom finders `ById`/`ByTypeIndex`, and `AppiumHandlerDriverExtension`, a public copy of flutter_driver's internal `_FlutterDriverExtension` so the handler can call it directly. **On an SDK bump, diff it against `packages/flutter_driver/lib/src/extension/extension.dart`** — signature changes there are the most likely breakage (e.g. `deserializeFinder`/`deserializeCommand` gained an optional `{String? path}` between Flutter 3.24 and 3.44).

## Rules and gotchas

**Page source**
- Debug builds emit the summary tree (only the app's own widgets); Profile/Release emit everything, framework internals included. **Never make locators depend on the page source's shape** — read what they need from the live tree (`typeIndex`, `label`/`hint`, tap-target text). Test both shapes when changing tree output.
- Subtrees hidden at the screen level (routes covered by an opaque route, `Offstage(offstage: true)`, unselected `IndexedStack` children, `SliverOffstage`) are left out (`_collectScreenHiddenElements`). List items scrolled out of view are kept but have an empty `typeIndex`.
- In Profile/Release only, identity-less pass-through wrappers and zero-size identity-less leaves are dropped (`_isCollapsibleWrapper`; `debugForcePruneWrappers` forces it in tests). Never drop types callers search for by tag (`Text`, `Icon`, `InkWell`, `TextFormField`, `Container`, `Padding`, app widgets).
- `label`/`hint` are the field's `InputDecoration.labelText`/`hintText` (`_inputDecorationTexts`), not rendered text.

**Recording and driving**
- Actions are driven by page-source id (`ById`) first; the reported locator is computed separately by `_computeRecordableLocator`: tooltip → semantics label → value key → field label → text → tap-target label → `Type#N`.
- `Type#N`'s N is the **live, finder-order** index (`_computeLiveTypeIndex`, emitted as `typeIndex`) — the same N as `find.byType(Type).at(N)`. Don't count same-typed page-source nodes instead. Callers that send `Type#N` themselves should read `typeIndex`.
- `byValueKey` is recorded only for a `ValueKey<String>`, as its plain string (`_valueKeyString`). Never record the key attribute verbatim: a `GlobalKey`/`UniqueKey`/`ObjectKey` prints an identity hash that changes on every launch, and `[<'x'>]` isn't what `find.byKey(const Key('x'))` matches. Replay also accepts the older raw `[<'x'>]` form.
- `byFieldLabel` (`_fieldLabelLocatorFor`) and the tap-target label (`_tapTargetTextFor`) are only recorded when unique on screen; otherwise fall back to `Type#N`. The tap-target label also covers a child-less InkWell laid over its content (`Stack[content, Positioned.fill(InkWell)]`): text drawn inside the tap target's area counts. A replayed `byText` that isn't on the resolved node is driven with flutter_driver's `ByText`, and one whose text is covered by an overlay (not hit-testable) is tapped at the text's center — flutter_driver would otherwise wait forever for it to become hit-testable.
- The `ById` finder needs the `AppiumWidgetInspectorService` that minted the id, which is why it lives in the `_inspectorService` field.
- All finder-based driver calls go through `_callDriverExtension` (frame sync off while animations tick, 2 s `_driverCallTimeout`) — calling `_driverExtension.call` directly can hang forever on an animated screen.

**`enter_text`**
- flutter_driver's `EnterText` ignores the finder and types into the focused field: always focus via `_focusForTextEntry`, which **registers text-entry emulation before tapping** (the other order silently drops the text).
- After entering text, `_submitTextEntry` sends `done` and the response carries `submitted: true`.
- If the id-based attempt fails, return the failure — don't fall through to the type chain (it can type into the wrong field while reporting success).

**Debugging on a device**
- Grep device logs by the `[appium_handler]` prefix, not a substring of one message.
- `verboseHitTestLogging = true` (set in the app's `main.dart`) logs each coordinate hit test (`[appium_handler][hitTest]`); off by default because it is noisy.
- If a fix seems to have no effect, first check that the device runs the current handler: a `<tree>` without the diagnostic attributes means an old install (uninstall the app before the next run).

## Native OS dialogs — don't add native code here

Permission dialogs, `BiometricPrompt`/screen-lock PIN prompts and some in-app dialogs never appear in this package's XML. Use the driver's `NATIVE_APP` context instead (proxied to UiAutomator2/XCUITest, see `appium-flutter-driver/CLAUDE.md`):

1. In `FLUTTER` context, tap whatever opens the native prompt.
2. `POST /session/:id/context {"name": "NATIVE_APP"}`.
3. `GET /session/:id/source` returns the native `<hierarchy>`; find the target `resource-id` (e.g. `com.android.systemui:id/lockPassword`).
4. `POST /session/:id/element {"using":"id","value":"<resource-id>"}`, then `POST /session/:id/element/:id/value {"text":"1234"}`.
5. Submit (e.g. `adb shell input keyevent KEYCODE_ENTER`).
6. `POST /session/:id/context {"name":"FLUTTER"}`.

Starting a new session with `appium:noReset: true` fails with `No observatory URL matching ...` if the app is already running — `adb shell am force-stop <appPackage>` first.

## Repo layout notes

- [docs/design-notes.md](docs/design-notes.md) — why the rules above exist and how the problems behind them were found.
- `Qiita.md` (Japanese) / `README.md` (English) and `images/` — the published article about this project, not architecture docs.
