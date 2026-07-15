import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter_driver/flutter_driver.dart' hide find;
import 'package:flutter_test/flutter_test.dart';

import 'widget_tree.dart';

/// A `ByType` finder narrowed to the Nth widget (in element-tree evaluation order) with that
/// runtime type, for when plain `ByType` is ambiguous (matches more than one widget - the common
/// case for types like `Icon`/`Text`/`Container`, which flutter_test's own `ByType` finder can't
/// resolve to a single target on its own).
class ByTypeIndexFinder extends SerializableFinder {
  const ByTypeIndexFinder(this.type, this.index);

  final String type;
  final int index;

  @override
  String get finderType => 'ByTypeIndex';

  @override
  Map<String, String> serialize() =>
      super.serialize()..addAll({'type': type, 'index': index.toString()});
}

class ByTypeIndexFinderExtension extends FinderExtension {
  @override
  String get finderType => 'ByTypeIndex';

  @override
  SerializableFinder deserialize(
    Map<String, String> params,
    DeserializeFinderFactory finderFactory,
  ) {
    return ByTypeIndexFinder(params['type']!, int.parse(params['index']!));
  }

  @override
  Finder createFinder(SerializableFinder finder, CreateFinderFactory finderFactory) {
    final byTypeIndex = finder as ByTypeIndexFinder;
    return find
        .byElementPredicate(
          (element) => element.widget.runtimeType.toString() == byTypeIndex.type,
          description:
              'widget with runtimeType "${byTypeIndex.type}" at index ${byTypeIndex.index}',
        )
        .at(byTypeIndex.index);
  }
}

/// Resolves a widget by the same `id` `appium_handler.dart` already puts on every page-source
/// XML node (a `WidgetInspectorService` diagnostics-reference id), rather than by any observable
/// property of the widget - unambiguous by construction, unlike `ByTooltipMessage`/
/// `BySemanticsLabel`/`ByValueKey`/`ByText`/`ByType`, which can all be missing or match more than
/// one widget. Only meaningful for driving the *live* Inspector session: there's no `find.byId`
/// in real flutter_test, so this can't be emitted into generated test code, unlike the others.
class ByIdFinder extends SerializableFinder {
  const ByIdFinder(this.id);

  final String id;

  @override
  String get finderType => 'ById';

  @override
  Map<String, String> serialize() => super.serialize()..addAll({'id': id});
}

class ByIdFinderExtension extends FinderExtension {
  ByIdFinderExtension(this._getInspectorService);

  // A getter rather than a fixed instance: `appium_handler.dart` replaces its
  // `AppiumWidgetInspectorService` every `getPageSource` call, and only *that* instance's own id
  // registry (`toObject`) can resolve the ids it minted.
  final AppiumWidgetInspectorService? Function() _getInspectorService;

  @override
  String get finderType => 'ById';

  @override
  SerializableFinder deserialize(
    Map<String, String> params,
    DeserializeFinderFactory finderFactory,
  ) {
    return ByIdFinder(params['id']!);
  }

  @override
  Finder createFinder(SerializableFinder finder, CreateFinderFactory finderFactory) {
    final byId = finder as ByIdFinder;
    // ignore: invalid_use_of_protected_member
    final object = _getInspectorService()?.toObject(byId.id);
    return find.byElementPredicate(
      (element) => identical(element, object),
      description: 'widget with page-source id "${byId.id}"',
    );
  }
}

// A copy of flutter_driver's internal `_FlutterDriverExtension`, exposed as a public class so
// `AppiumHandler` (appium_handler.dart) can hold a reference to it and call `.call(params)`
// directly to drive widgets (tap/scroll/enter_text) once it has resolved a Flutter finder for a
// given screen position. `enableFlutterDriverExtension()` from `flutter_driver` does not expose
// its extension instance, hence this duplicate.
class AppiumHandlerDriverExtension
    with
        DeserializeFinderFactory,
        CreateFinderFactory,
        DeserializeCommandFactory,
        CommandHandlerFactory {
  AppiumHandlerDriverExtension(
    this._requestDataHandler,
    this._silenceErrors,
    this._enableTextEntryEmulation, {
    List<FinderExtension> finders = const <FinderExtension>[],
    List<CommandExtension> commands = const <CommandExtension>[],
  }) {
    if (_enableTextEntryEmulation) {
      registerTextInput();
    }

    for (final FinderExtension finder in finders) {
      _finderExtensions[finder.finderType] = finder;
    }

    for (final CommandExtension command in commands) {
      _commandExtensions[command.commandKind] = command;
    }
  }

  final WidgetController _prober = LiveWidgetController(
    WidgetsBinding.instance,
  );
  WidgetController get prober => _prober;

  final DataHandler? _requestDataHandler;
  final bool _silenceErrors;
  final bool _enableTextEntryEmulation;

  final Map<String, FinderExtension> _finderExtensions =
      <String, FinderExtension>{};
  final Map<String, CommandExtension> _commandExtensions =
      <String, CommandExtension>{};

  void _log(String message) {
    driverLog('FlutterDriverExtension', message);
  }

  Future<Map<String, dynamic>> call(Map<String, String> params) async {
    final String commandKind = params['command']!;
    try {
      final Command command = deserializeCommand(params, this);
      assert(
        WidgetsBinding.instance.isRootWidgetAttached ||
            !command.requiresRootWidgetAttached,
        'No root widget is attached; have you remembered to call runApp()?',
      );
      Future<Result> responseFuture = handleCommand(command, _prober, this);
      if (command.timeout != null) {
        responseFuture = responseFuture.timeout(command.timeout!);
      }
      final Result result = await responseFuture;
      return _makeResponse(result.toJson());
    } on TimeoutException catch (error, stackTrace) {
      final String message =
          'Timeout while executing $commandKind: $error\n$stackTrace';
      _log(message);
      return _makeResponse(message, isError: true);
    } catch (error, stackTrace) {
      final String message =
          'Uncaught extension error while executing $commandKind: $error\n$stackTrace';
      if (!_silenceErrors) {
        _log(message);
      }
      return _makeResponse(message, isError: true);
    }
  }

  Map<String, dynamic> _makeResponse(dynamic response, {bool isError = false}) {
    return <String, dynamic>{'isError': isError, 'response': response};
  }

  @override
  SerializableFinder deserializeFinder(Map<String, String> json, {String? path}) {
    final String? finderType = json['finderType'];
    if (_finderExtensions.containsKey(finderType)) {
      return _finderExtensions[finderType]!.deserialize(json, this);
    }
    return super.deserializeFinder(json, path: path);
  }

  @override
  Finder createFinder(SerializableFinder finder) {
    final String finderType = finder.finderType;
    if (_finderExtensions.containsKey(finderType)) {
      return _finderExtensions[finderType]!.createFinder(finder, this);
    }
    return super.createFinder(finder);
  }

  @override
  Command deserializeCommand(
    Map<String, String> params,
    DeserializeFinderFactory finderFactory, {
    String? path,
  }) {
    final String? kind = params['command'];
    if (_commandExtensions.containsKey(kind)) {
      return _commandExtensions[kind]!.deserialize(params, finderFactory, this);
    }
    return super.deserializeCommand(params, finderFactory, path: path);
  }

  @override
  @protected
  DataHandler? getDataHandler() {
    return _requestDataHandler;
  }

  @override
  Future<Result> handleCommand(
    Command command,
    WidgetController prober,
    CreateFinderFactory finderFactory,
  ) {
    final String kind = command.kind;
    if (_commandExtensions.containsKey(kind)) {
      return _commandExtensions[kind]!.call(
        command,
        prober,
        finderFactory,
        this,
      );
    }
    return super.handleCommand(command, prober, finderFactory);
  }
}
