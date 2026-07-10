import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter_driver/flutter_driver.dart';
import 'package:flutter_test/flutter_test.dart';

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
