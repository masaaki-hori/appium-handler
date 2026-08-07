import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:xml/xml.dart';

import 'appium_handler_extension.dart';
import 'widget_tree.dart';

/// Callback handler for the appium-flutter-driver `flutter:requestData` command, used to make
/// Appium Inspector (and any other client that talks the W3C `findElement`/actions protocol) work
/// against the FLUTTER context. Register it via:
///
/// ```dart
/// void main() {
///   final handler = AppiumHandler();
///   enableFlutterDriverExtension(handler: handler.appiumHandler);
///   handler.buildDriverExtension();
///   runApp(const MyApp());
/// }
/// ```
///
/// See the driver-side counterpart in `driver/lib/commands/screen.ts`
/// (getWindowRect/getPageSource/performActions) and `driver/lib/driver.ts` (`findElement`,
/// `performActions` interception in `executeCommand`).
class AppiumHandler {
  int _index = 0;
  String _source = '';
  XmlDocument? _document;
  AppiumHandlerDriverExtension? _driverExtension;
  final Map<String, List<Offset>> _treeItemOffsets = {};

  // Kept as an instance field (not a local variable in `_getPageSource`) so `ByIdFinderExtension`
  // can resolve a page-source `id` back to the exact widget it came from via `toObject(id)`,
  // which is only valid for the same `WidgetInspectorService` instance that minted that id -
  // `_idToReferenceData` (the id registry `toObject` reads) is an instance field of the mixin,
  // not shared/static across instances.
  AppiumWidgetInspectorService? _inspectorService;

  void buildDriverExtension() {
    _driverExtension = AppiumHandlerDriverExtension(
      appiumHandler,
      true,
      false,
      finders: [ByTypeIndexFinderExtension(), ByIdFinderExtension(() => _inspectorService)],
    );
  }

  Future<String> appiumHandler(String? cmd) async {
    final cmdAndArg = cmd?.split(':');
    final msg = cmdAndArg?[0];
    debugPrint('[appium_handler] Received command: $msg');
    switch (msg) {
      case 'getScreenSize':
        return _getScreenSize();
      case 'getPageSource':
        return _getPageSource();
      case 'performActions':
        return _handlePerformActions(cmd!);
      case 'getFinderType':
        return _handleGetFinderType(cmd!);
      case 'findElement':
        return _handleFindElement(cmdAndArg!);
      case 'findByPosition':
        return _handleFindByPosition(cmd!);
    }
    return jsonEncode({});
  }

  String _getScreenSize() {
    final FlutterView view = PlatformDispatcher.instance.views.first;
    final double devicePixelRatio = view.devicePixelRatio;
    final double screenWidth = view.physicalSize.width / devicePixelRatio;
    final double screenHeight = view.physicalSize.height / devicePixelRatio;
    return jsonEncode({
      'width': screenWidth.toInt(),
      'height': screenHeight.toInt(),
    });
  }

  /// Builds an XML page-source tree by walking Flutter's widget summary tree
  /// (see widget_tree.dart), attaching a global pixel `bounds` rect to each node so that
  /// `_getNodeFromOffset` can later resolve a screen coordinate back to a widget.
  String _getPageSource() {
    try {
      _inspectorService = AppiumWidgetInspectorService();
      final tree = _inspectorService!;

      // Computes and caches this node's bounds in `_treeItemOffsets`. Failures here are
      // per-widget (e.g. a widget with no RenderBox/layout data yet) - logged and skipped
      // rather than aborting the whole tree, so one problematic widget doesn't take down
      // page source retrieval for the entire app. Recursion into children always happens,
      // even if this node's own bounds lookup failed.
      void layoutTree(Map<String, dynamic>? element) {
        final valueId = element?['valueId'];
        try {
          // subtreeDepth: 0 - only this node's own size/parentData is read below; its children
          // are covered by this same function's own recursion, not by this call's descendants.
          // A larger depth here would make every one of these per-node calls re-serialize that
          // node's entire subtree, redundant with (and far more expensive than) the recursion.
          final layout = tree.getLayoutExplorerNode({
            'id': valueId,
            'subtreeDepth': '0',
            'groupName': 'tree_1',
          });
          final Map<String, dynamic> result =
              layout['result'] as Map<String, dynamic>;
          final Map<String, dynamic> size = result['size'];
          final width = double.parse(size['width']);
          final height = double.parse(size['height']);
          double left = 0.0;
          double top = 0.0;
          if (result['parentData'] != null) {
            final Map<String, dynamic> parentData = result['parentData'];
            left = double.parse(parentData['globalX']);
            top = double.parse(parentData['globalY']);
          }

          final topLeft = Offset(left, top);
          final bottomRight = Offset(left + width, top + height);
          _treeItemOffsets[valueId] = [topLeft, bottomRight];
        } catch (e, stackTrace) {
          debugPrint(
            '[appium_handler] layoutTree failed for widget $valueId: $e\n$stackTrace',
          );
        }

        // 'hasChildren' is absent (null), rather than false, on some leaf widgets - treat
        // that the same as 'no children' instead of letting the cast throw
        if ((element?['hasChildren'] as bool?) ?? false) {
          for (final child in element?['children']) {
            layoutTree(child);
          }
        }
      }

      // Appends this node's XML element (and recurses into its children) to `_source`.
      // Same per-widget resilience as `layoutTree`: a failure while reading this node's own
      // properties still emits a (minimal) element with matching open/close tags, so the XML
      // stays well-formed and the rest of the tree (siblings, children) is unaffected.
      void visitorTree(Map<String, dynamic>? element) {
        final valueId = element?['valueId'];
        var type = 'Unknown';
        try {
          final String runtimeType = element?['widgetRuntimeType'];
          type = runtimeType.replaceAll('<', '-').replaceAll('>', '-');

          final properties = tree.myGetProperties(valueId, 'tree_1');
          String? key;
          String? text;
          String? enabled;
          String? toolTip;
          String? semanticLabel;
          for (final property in properties as List<dynamic>) {
            final description = (property['description'] as String?)
                ?.replaceAll('"', '');
            final value = (description == 'null') ? '' : description;
            switch (property['name']) {
              case 'key':
                key = value;
              case 'data':
                text = value;
              case 'enabled':
                enabled = value;
              case 'tooltip':
                toolTip = value;
              case 'semanticLabel':
                semanticLabel = value;
              case 'controller':
                final txt = property['description'] as String;
                final start = txt.indexOf('┤');
                final end = txt.indexOf('├');
                if (start > 0 && end > 0) {
                  text = txt.substring(start + 1, end);
                }
            }
          }

          final isEditable =
              runtimeType == 'TextField' || runtimeType == 'TextFormField';

          var topLeft = const Offset(0.0, 0.0);
          var bottomRight = const Offset(0.0, 0.0);
          final listOffset = _treeItemOffsets[valueId];
          if (listOffset != null) {
            topLeft = listOffset[0];
            bottomRight = listOffset[1];
          }

          ++_index;
          _source +=
              '<$type id="$valueId" key="$key" index="$_index" class="$type" '
              'text="${text ?? ''}" tooltip="${toolTip ?? ''}" '
              'bounds="[${topLeft.dx.toInt()},${topLeft.dy.toInt()}]'
              '[${bottomRight.dx.toInt()},${bottomRight.dy.toInt()}]" '
              'enabled="${enabled ?? ''}" semanticLabel="${semanticLabel ?? ''}" '
              'input="${isEditable ? 'true' : 'false'}" '
              'centerX="${((topLeft.dx + bottomRight.dx) / 2).toInt()}" '
              'centerY="${((topLeft.dy + bottomRight.dy) / 2).toInt()}">\n';
        } catch (e, stackTrace) {
          debugPrint(
            '[appium_handler] visitorTree failed for widget $valueId ($type): $e\n$stackTrace',
          );
          ++_index;
          _source += '<$type id="$valueId" index="$_index" class="$type">\n';
        }

        // Same null-safety as 'layoutTree' above
        if ((element?['hasChildren'] as bool?) ?? false) {
          for (final child in element?['children']) {
            visitorTree(child);
          }
        }
        _source += '</$type>\n';
      }

      _source = '<?xml version="1.0"?>\n<tree>\n';
      final result = tree.getRootWidgetSummaryTreeWithPreviews({
        'groupName': 'tree_1',
      });
      layoutTree(result['result'] as Map<String, dynamic>?);
      visitorTree(result['result'] as Map<String, dynamic>?);
      _source += '</tree>\n';

      _document = XmlDocument.parse(_source);
      return _document.toString();
    } catch (e, stackTrace) {
      debugPrint('[appium_handler] _getPageSource failed: $e\n$stackTrace');
      rethrow;
    }
  }

  Future<String> _handlePerformActions(String cmd) async {
    final json = cmd.substring(cmd.indexOf(':') + 1).trim();
    final jsonObject = jsonDecode(json);
    if (jsonObject is List) {
      return await _performActions(jsonObject);
    }
    return '';
  }

  /// Resolves the id (assigned in `_getPageSource`) of a previously found element to the finder
  /// type/value Appium Inspector should use when generating a test script (ByType, ByValueKey,
  /// ByTooltipMessage, BySemanticsLabel or ByText, tried in that priority order).
  String _handleGetFinderType(String cmd) {
    final json = cmd.substring(cmd.indexOf(':') + 1).trim();
    final jsonObject = jsonDecode(json) as Map<String, dynamic>;

    String? foundBy;
    String? value;
    for (final node in (_document?.descendants.toList() ?? []).reversed) {
      if (node.getAttribute('id') != jsonObject['id']) {
        continue;
      }
      foundBy = 'byType';
      value = node.getAttribute('class');

      final tooltip = node.getAttribute('tooltip');
      if (tooltip != null && tooltip.isNotEmpty) {
        foundBy = 'byTooltip';
        value = tooltip;
      }
      final semanticLabel = node.getAttribute('semanticLabel');
      if (semanticLabel != null && semanticLabel.isNotEmpty) {
        foundBy = 'bySemanticsLabel';
        value = semanticLabel;
      }
      final key = node.getAttribute('key');
      if (key != null && key.isNotEmpty && key != 'null') {
        foundBy = 'byValueKey';
        value = key;
      }
      final text = node.getAttribute('text');
      if (text != null && text.isNotEmpty) {
        foundBy = 'byText';
        value = text;
      }
    }
    // jsonEncode (not manual string interpolation) so an unmatched id - foundBy/value staying
    // null - encodes as JSON null rather than the literal string "null" (see '_actionResult').
    return jsonEncode({'isError': false, 'foundBy': foundBy, 'text': value});
  }

  /// Resolves a synthetic element id (from a prior `findElement`/`getPageSource` call) back to a
  /// W3C element reference, either by id or by an xpath expression containing `[@id="..."]`.
  String _handleFindElement(List<String> cmdAndArg) {
    final separated = cmdAndArg[1].split(',');
    if (_document == null) {
      return '{}';
    }

    if (separated[0] == 'id') {
      final id = separated[1];
      for (final node in _document!.descendants) {
        if (node.getAttribute('id') == id) {
          return '{"value":{"ELEMENT":"$id","element-6066-11e4-a52e-4f735466cecf":"$id"},'
              '"sessionId":"${separated[2]}"}';
        }
      }
      return '{}';
    }

    if (separated[0] != 'xpath') {
      return '{}';
    }
    final xpath = separated[1];
    final idIdx = xpath.indexOf('[@id=');
    if (idIdx < 0) {
      return '{}';
    }
    final elementName = xpath.substring(2, idIdx);
    var id = xpath.substring(idIdx + '[@id='.length + 1);
    final endIdx = id.indexOf('"]');
    if (endIdx < 0) {
      return '{}';
    }
    id = id.substring(0, endIdx).replaceAll('<', '-').replaceAll('>', '-');

    for (final line in _document!.findAllElements(elementName)) {
      if (line.getAttribute('id') != id) {
        continue;
      }
      final element = _findSizeRoot(line) ?? line;
      final resolvedId = element.getAttribute('id');
      return '{"value":{"ELEMENT":"$resolvedId","element-6066-11e4-a52e-4f735466cecf":"$resolvedId"},'
          '"sessionId":"${separated[2]}"}';
    }
    return '{}';
  }

  /// Resolves a raw screen coordinate to the widget occupying it, for clients that only know
  /// pixel positions (e.g. before Appium Inspector's widget-based recording was added).
  Future<String> _handleFindByPosition(String cmd) async {
    final json = cmd.substring(cmd.indexOf(':') + 1).trim();
    final jsonObject = jsonDecode(json) as Map<String, dynamic>;
    final x = (jsonObject['x'] as num).toDouble();
    final y = (jsonObject['y'] as num).toDouble();
    final node = _getNodeFromOffset(Offset(x, y));
    if (node == null) {
      return '{}';
    }

    final result = <String, dynamic>{'text': await _findNodeText(node)};
    final tooltip = await _findNodeTooltip(node);
    if (tooltip != null && tooltip.isNotEmpty) {
      return jsonEncode({...result, 'foundBy': 'byTooltip', 'value': tooltip});
    }
    final semanticLabel = await _findNodeLabel(node);
    if (semanticLabel != null && semanticLabel.isNotEmpty) {
      return jsonEncode({
        ...result,
        'foundBy': 'bySemanticsLabel',
        'value': semanticLabel,
      });
    }
    final key = node.getAttribute('key');
    if (key != null && key.isNotEmpty && key != 'null') {
      return jsonEncode({...result, 'foundBy': 'byValueKey', 'value': key});
    }
    final text = result['text'];
    if (text != null && (text as String).isNotEmpty) {
      return jsonEncode({...result, 'foundBy': 'byType', 'value': text});
    }
    return jsonEncode({
      ...result,
      'foundBy': 'byType',
      'value': node.getAttribute('class'),
    });
  }

  Future<String> _performActions(List<dynamic> jsonObject) async {
    final Map<String, dynamic> performs = jsonObject[0] is List<dynamic>
        ? jsonObject[0][0]
        : jsonObject[0];
    final List<dynamic> actions = performs['actions'];

    // The last action in the batch that carries an explicit finder (set by Appium Inspector when
    // it already knows which widget it is driving) takes precedence over hit-testing by position.
    String? foundBy;
    String? foundValue;
    for (final Map<String, dynamic> action in actions) {
      final f = action['foundBy'] as String?;
      if (f != null && f.isNotEmpty) {
        foundBy = f;
      }
      final v = action['value'] as String?;
      if (v != null && v.isNotEmpty) {
        foundValue = v;
      }
    }

    int? x, y, x2, y2, duration;
    for (final Map<String, dynamic> action in actions) {
      switch (action['type']) {
        case 'pointerMove':
          // The first pointerMove is the (tap/drag-start) position; a second one, if present, is
          // the drag-end position.
          if (x != null) {
            x2 = action['x'];
            duration = action['duration'];
          } else {
            x = action['x'];
          }
          if (y != null) {
            y2 = action['y'];
          } else {
            y = action['y'];
          }
          break;
        case 'pause':
          duration = action['duration'];
          break;
        case 'pointerUp':
          final node = _getNodeFromOffset(Offset(x!.toDouble(), y!.toDouble()));
          if (node != null) {
            final result = (x2 != null && x != x2) || (y2 != null && y != y2)
                ? await _execCommandWithFinder(
                    x,
                    y,
                    node,
                    'scroll',
                    duration: duration,
                    dx: x2! - x,
                    dy: y2! - y,
                  )
                : await _execCommandWithFinder(
                    x,
                    y,
                    node,
                    'tap',
                    duration: duration,
                  );
            if (result != null && result['isError'] != true) {
              return _actionResult(node, result);
            }
          }
          break;
        case 'enterText':
          // x/y, elementId and foundBy/value are all nullable/optional here - see the 'tap' case
          // below for why, and '_findNodeByLocator' for the foundBy/value-only fallback (e.g. a
          // hand-authored WebdriverIO/Python replay of a recorded locator, with no click point or
          // elementId at all).
          final node =
              _resolveNode(x, y, action['elementId'] as String?) ??
              _findNodeByLocator(foundBy, foundValue);
          if (node != null) {
            final rect = x == null || y == null
                ? _boundsToRect(node.getAttribute('bounds'))
                : null;
            final resolvedX = x ?? rect?.center.dx.toInt() ?? 0;
            final resolvedY = y ?? rect?.center.dy.toInt() ?? 0;
            final result = await _execCommandWithFinder(
              resolvedX,
              resolvedY,
              node,
              'enter_text',
              enterText: action['text'],
              foundBy: foundBy,
              value: foundValue,
            );
            if (result != null && result['isError'] != true) {
              return _actionResult(node, result);
            }
          }
          break;
        case 'checkText':
          final node =
              _resolveNode(x, y, action['elementId'] as String?) ??
              _findNodeByLocator(foundBy, foundValue);
          if (node != null) {
            final rect = x == null || y == null
                ? _boundsToRect(node.getAttribute('bounds'))
                : null;
            final resolvedX = x ?? rect?.center.dx.toInt() ?? 0;
            final resolvedY = y ?? rect?.center.dy.toInt() ?? 0;
            final result = await _execCommandWithFinder(
              resolvedX,
              resolvedY,
              node,
              'check_text',
              enterText: action['text'],
              foundBy: foundBy,
              value: foundValue,
            );
            if (result != null && result['isError'] != true) {
              return _actionResult(node, result);
            }
          }
          break;
        case 'checkExistence':
          // Falling through to '{}' below (see the end of this method) when neither resolution
          // path finds a node is what makes this an actual existence check - not just a "which
          // locator would I use" report - for the foundBy/value-only case same as for
          // elementId/coordinate.
          final node =
              _resolveNode(x, y, action['elementId'] as String?) ??
              _findNodeByLocator(foundBy, foundValue);
          if (node != null) {
            final rect = x == null || y == null
                ? _boundsToRect(node.getAttribute('bounds'))
                : null;
            final resolvedX = x ?? rect?.center.dx.toInt() ?? 0;
            final resolvedY = y ?? rect?.center.dy.toInt() ?? 0;
            final result = await _execCommandWithFinder(
              resolvedX,
              resolvedY,
              node,
              'check_existence',
              enterText: '',
              foundBy: foundBy,
              value: foundValue,
            );
            if (result != null && result['isError'] != true) {
              return _actionResult(node, result);
            }
          }
          break;
        case 'tap':
          // Unlike the plain W3C 'pointerUp' tap above (which always hit-tests the coordinate
          // itself), this supports several elementId/locator-driven callers: Appium Inspector's
          // disambiguation submenu (a real click point plus 'elementId', when more than one
          // element's bounds contained it - x/y are set here from a preceding 'pointerMove'),
          // appium-flutter-driver's standard 'elementClick' passthrough (id only, no click point
          // at all - see 'driver.ts'), and hand-authored WebdriverIO/Python code replaying a
          // recorded foundBy/value locator with neither an id nor a click point. x/y stay nullable
          // through here for all of these.
          final tapElementId = action['elementId'] as String?;
          final node =
              _resolveNode(x, y, tapElementId) ?? _findNodeByLocator(foundBy, foundValue);
          if (node != null) {
            // _execCommandWithFinder wants concrete coordinates (used for its final
            // _driveByCoordinate fallback) - derive them from the resolved node's own bounds
            // when the caller didn't supply a click point.
            final rect = x == null || y == null
                ? _boundsToRect(node.getAttribute('bounds'))
                : null;
            final resolvedX = x ?? rect?.center.dx.toInt() ?? 0;
            final resolvedY = y ?? rect?.center.dy.toInt() ?? 0;
            final result = await _execCommandWithFinder(
              resolvedX,
              resolvedY,
              node,
              'tap',
              foundBy: foundBy,
              value: foundValue,
            );
            if (result != null && result['isError'] != true) {
              return _actionResult(node, result);
            }
          }
          break;
        case 'tapDirect':
          // See `_driveByDirectCallback` below - bypasses hit-testing entirely, for widgets that a
          // normal 'tap' can't reliably reach because something else (a coach-mark overlay, a
          // dialog barrier) visually covers them at that point.
          final directElementId = action['elementId'] as String?;
          final directNode =
              _resolveNode(x, y, directElementId) ?? _findNodeByLocator(foundBy, foundValue);
          if (directNode != null) {
            final id = directNode.getAttribute('id');
            if (id != null && id.isNotEmpty) {
              final result = _driveByDirectCallback(id);
              if (result['isError'] != true) {
                final locator = await _computeRecordableLocator(
                  directNode,
                  foundBy: foundBy,
                  value: foundValue,
                );
                result['foundBy'] = locator.foundBy;
                result['value'] = locator.value;
                return _actionResult(directNode, result);
              }
            }
          }
          break;
      }
    }
    return '{}';
  }

  /// Bypasses flutter_driver's hit-test-based tap entirely by resolving [id] to its underlying
  /// `Element` (the same `WidgetInspectorService.toObject` lookup `ByIdFinderExtension` uses) and
  /// calling the nearest `InkResponse` (which `InkWell` extends) or `GestureDetector` ancestor's
  /// `onTap` callback directly, as a plain Dart function call.
  ///
  /// Every other tap path in this file (`_driveById`/`_driveKey`/`_driveFinder`/
  /// `_driveByTypeIndex`/`_driveByCoordinate`) ultimately goes through `LiveWidgetController.tap`,
  /// which computes a screen coordinate and synthesizes a real pointer gesture there - hit-tested
  /// against whatever is currently painted on top at that point. A locator can resolve to exactly
  /// the right widget and the tap can still land on an unrelated overlay sitting above it (a
  /// coach-mark highlight, a dialog barrier) instead - and flutter_driver's tap command reports
  /// success regardless, since dispatching the gesture didn't throw. This sidesteps that: it never
  /// looks at paint order or screen coordinates at all, so it can't be intercepted by anything
  /// visually on top.
  ///
  /// Opt-in via a distinct 'tapDirect' action type (see `_performActions` above) rather than
  /// folded into the existing tap fallback chain, so every already-recorded script's plain 'tap'
  /// keeps its current, hit-test-based behavior unchanged.
  Map<String, dynamic> _driveByDirectCallback(String id) {
    Object? object;
    try {
      // ignore: invalid_use_of_protected_member
      object = _inspectorService?.toObject(id);
    } catch (e) {
      return {'isError': true, 'response': 'toObject($id) failed: $e'};
    }
    if (object is! Element) {
      return {'isError': true, 'response': 'no live Element for page-source id "$id"'};
    }

    VoidCallback? onTap;
    bool checkWidget(Widget widget) {
      if (widget is InkResponse) {
        onTap = widget.onTap;
      } else if (widget is GestureDetector) {
        onTap = widget.onTap;
      }
      return onTap != null;
    }

    if (!checkWidget(object.widget)) {
      object.visitAncestorElements((ancestor) => !checkWidget(ancestor.widget));
    }

    if (onTap == null) {
      return {
        'isError': true,
        'response':
            'no InkResponse/GestureDetector.onTap found for id "$id" or its ancestors',
      };
    }
    onTap!();
    return {'isError': false};
  }

  String _actionResult(XmlNode node, Map<String, dynamic> result) {
    // 'submitted' is only ever set (by _submitTextEntry's callers) for a successful enter_text -
    // appium-inspector uses it to decide whether the generated code also needs a
    // TextInputAction.done step after entering the text, matching what actually happened live.
    //
    // Built via jsonEncode (not manual string interpolation) so a null field - notably 'foundBy'/
    // 'value' when [result] came from '_driveByCoordinate', which deliberately omits them for a
    // widget with no reliable locator - encodes as JSON null rather than the literal 4-character
    // string "null" that '"${result['foundBy']}"' would produce. That string is truthy on the JS
    // side (both 'parseFlutterFinderFromResponse's 'foundBy && value' check and js-wdio.js's
    // generated 'Boolean(foundBy)' checks), so a tap that deliberately couldn't resolve a locator
    // was being recorded/replayed as if it had - the same string-interpolation trap the 'key'
    // attribute in '_getPageSource' had.
    return jsonEncode({
      'text': node.getAttribute('text'),
      'elementId': node.getAttribute('id'),
      'type': node.getAttribute('class'),
      'foundBy': result['foundBy'],
      'value': result['value'],
      'submitted': result['submitted'] == true,
    });
  }

  Future<Map<String, dynamic>?> _execCommandWithFinder(
    int x,
    int y,
    XmlNode node,
    String command, {
    String? enterText,
    int? duration,
    int? dx,
    int? dy,
    String? foundBy,
    String? value,
  }) async {
    if (command == 'check_text' || command == 'check_existence') {
      final locator = await _computeRecordableLocator(node, foundBy: foundBy, value: value);
      return {'isError': false, 'foundBy': locator.foundBy, 'value': locator.value};
    }

    // Resolving by the widget's own page-source id is unambiguous by construction, unlike
    // tooltip/semanticsLabel/key/text/type below (any of which can be missing, or match more
    // than one widget) - so it's tried first for actually performing the action. It's not usable
    // as a *recorded* locator though (there's no `find.byId` in real flutter_test outside our own
    // `ByIdFinderExtension`), so the recordable foundBy/value is still computed independently of
    // how the action actually got performed.
    final id = node.getAttribute('id');
    if (id != null && id.isNotEmpty) {
      final result = await _driveById(
        command,
        id,
        enterText: enterText,
        duration: duration,
        dx: dx,
        dy: dy,
      );
      if (result != null && result['isError'] != true) {
        final locator = await _computeRecordableLocator(node, foundBy: foundBy, value: value);
        result['foundBy'] = locator.foundBy;
        result['value'] = locator.value;
        return result;
      }
    }

    // Only reached if resolving/acting by id somehow failed - e.g. the
    // `AppiumWidgetInspectorService` that minted this id has since been replaced by a newer
    // `getPageSource` call.
    return _execCommandWithFinderChain(
      x,
      y,
      node,
      command,
      enterText: enterText,
      duration: duration,
      dx: dx,
      dy: dy,
      foundBy: foundBy,
      value: value,
    );
  }

  Future<Map<String, dynamic>?> _driveById(
    String command,
    String id, {
    String? enterText,
    int? duration,
    int? dx,
    int? dy,
  }) async {
    if (command == 'enter_text') {
      await _focusForTextEntry({'finderType': 'ById', 'id': id});
    }
    final params = <String, String>{'command': command, 'finderType': 'ById', 'id': id};
    if (dx != null && dy != null) {
      params['dx'] = dx.toString();
      params['dy'] = dy.toString();
    }
    if (duration != null) {
      params['duration'] = duration.toString();
    }
    if (command == 'scroll') {
      params['frequency'] = '60';
    }
    if (command == 'enter_text') {
      params['text'] = enterText!;
    }
    final result = await _callDriverExtension(params);
    if (command == 'enter_text' && result != null && result['isError'] != true) {
      await _submitTextEntry();
      result['submitted'] = true;
    }
    return result;
  }

  /// Determines the `foundBy`/`value` that should be *reported* for [node] - i.e. what a
  /// generated test's `find.byXxx(...)` locator should use - independent of whichever finder
  /// actually performed the action (see `_execCommandWithFinder`'s `ById` attempt above this).
  /// Same tooltip -> semantics label -> value key -> text -> widget type priority as
  /// `_execCommandWithFinderChain` below, minus the actual driving.
  Future<({String foundBy, String value})> _computeRecordableLocator(
    XmlNode node, {
    String? foundBy,
    String? value,
  }) async {
    if (foundBy == 'byTooltip') {
      return (foundBy: 'byTooltip', value: value!);
    }
    final tooltip = await _findNodeTooltip(node);
    if (tooltip != null && tooltip.isNotEmpty) {
      return (foundBy: 'byTooltip', value: tooltip);
    }
    if (foundBy == 'bySemanticsLabel') {
      return (foundBy: 'bySemanticsLabel', value: value!);
    }
    final semanticLabel = await _findNodeLabel(node);
    if (semanticLabel != null && semanticLabel.isNotEmpty) {
      return (foundBy: 'bySemanticsLabel', value: semanticLabel);
    }
    if (foundBy == 'byValueKey') {
      return (foundBy: 'byValueKey', value: value!);
    }
    final key = node.getAttribute('key');
    if (key != null && key.isNotEmpty && key != 'null') {
      return (foundBy: 'byValueKey', value: key);
    }
    if (foundBy == 'byText') {
      return (foundBy: 'byText', value: value!);
    }
    final text = await _findNodeText(node);
    if (text != null && text.isNotEmpty) {
      return (foundBy: 'byText', value: text);
    }
    final type = foundBy == 'byType' ? value! : node.getAttribute('class')!;
    final index = _typeIndexOf(node, type);
    return (foundBy: 'byType', value: index != null ? '$type#$index' : type);
  }

  /// The tooltip -> semantics label -> value key -> text -> widget type fallback chain, used to
  /// both drive the action *and* determine the reported locator, when acting by page-source id
  /// (see `_execCommandWithFinder` above) isn't available or didn't work.
  Future<Map<String, dynamic>?> _execCommandWithFinderChain(
    int x,
    int y,
    XmlNode node,
    String command, {
    String? enterText,
    int? duration,
    int? dx,
    int? dy,
    String? foundBy,
    String? value,
  }) async {
    if (foundBy == 'byTooltip') {
      return _driveFinder(
        command,
        'ByTooltipMessage',
        'text',
        value!,
        enterText: enterText,
        duration: duration,
        dx: dx,
        dy: dy,
      );
    }
    final tooltip = await _findNodeTooltip(node);
    if (tooltip != null && tooltip.isNotEmpty) {
      return _driveFinder(
        command,
        'ByTooltipMessage',
        'text',
        tooltip,
        enterText: enterText,
        duration: duration,
        dx: dx,
        dy: dy,
      );
    }
    if (foundBy == 'bySemanticsLabel') {
      return _driveFinder(
        command,
        'bySemanticsLabel',
        'label',
        value!,
        enterText: enterText,
        duration: duration,
        dx: dx,
        dy: dy,
      );
    }
    final semanticLabel = await _findNodeLabel(node);
    if (semanticLabel != null && semanticLabel.isNotEmpty) {
      return _driveFinder(
        command,
        'bySemanticsLabel',
        'label',
        semanticLabel,
        enterText: enterText,
        duration: duration,
        dx: dx,
        dy: dy,
      );
    }
    if (foundBy == 'byValueKey') {
      return _driveKey(
        command,
        value!,
        enterText: enterText,
        duration: duration,
        dx: dx,
        dy: dy,
      );
    }
    final key = node.getAttribute('key');
    if (key != null && key.isNotEmpty && key != 'null') {
      return _driveKey(
        command,
        key,
        enterText: enterText,
        duration: duration,
        dx: dx,
        dy: dy,
      );
    }
    if (foundBy == 'byText') {
      return _driveFinder(
        command,
        'ByText',
        'text',
        value!,
        enterText: enterText,
        duration: duration,
        dx: dx,
        dy: dy,
      );
    }
    final text = await _findNodeText(node);
    if (text != null && text.isNotEmpty) {
      return _driveFinder(
        command,
        'ByText',
        'text',
        text,
        enterText: enterText,
        duration: duration,
        dx: dx,
        dy: dy,
      );
    }
    // `value` for `byType` is the combined "Type#index" form produced by `_computeRecordableLocator`
    // (e.g. "InkWell#11"), not a bare type name - it must be split before use, otherwise both the
    // `ByType` finder below and `_typeIndexOf` compare against a type name that can never match
    // (no widget's runtime type literally contains "#11"), and every locator-based tap for a
    // `byType`-recorded action silently falls through to the raw-coordinate last resort, which
    // still taps successfully but reports no `foundBy`/`value` back to the caller.
    String type;
    int? recordedIndex;
    if (foundBy == 'byType') {
      final parts = value!.split('#');
      type = parts[0];
      recordedIndex = parts.length > 1 ? int.tryParse(parts[1]) : null;
    } else {
      type = node.getAttribute('class')!;
    }
    final result = await _driveFinder(
      command,
      'ByType',
      'type',
      type,
      enterText: enterText,
      duration: duration,
      dx: dx,
      dy: dy,
    );
    if (result != null && result['isError'] != true) {
      return result;
    }
    if (command != 'tap' && command != 'scroll') {
      return result;
    }
    // A widget type is rarely unique in a real app (any Icon/Text/Container/etc. commonly has
    // many instances), so plain `ByType` typically fails here with a "Found N widgets" ambiguity
    // from flutter_test. Retry narrowed to this node's position among same-typed nodes in the
    // last-fetched page source - a valid, replayable locator (`find.byType(X).at(N)`) as long as
    // the element tree's evaluation order doesn't change between now and when a generated test
    // using it runs. If the caller already recorded this exact index (a `byType` locator being
    // replayed), reuse it directly instead of recomputing - it's what identified `node` in the
    // first place, so it's already known to resolve correctly right now.
    final index = recordedIndex ?? _typeIndexOf(node, type);
    if (index != null) {
      final indexedResult = await _driveByTypeIndex(
        command,
        type,
        index,
        duration: duration,
        dx: dx,
        dy: dy,
      );
      if (indexedResult != null && indexedResult['isError'] != true) {
        return indexedResult;
      }
    }
    // Last resort: synthesize the gesture directly at the tapped coordinate, bypassing finder
    // resolution entirely. Deliberately reports no foundBy/value, since neither `ByType` nor
    // `ByTypeIndex` proved reliable for this widget.
    return _driveByCoordinate(command, x, y, dx: dx, dy: dy);
  }

  /// The 0-based position of [node] among all `_document` nodes sharing its `class` attribute, in
  /// document order - the same order `find.byElementPredicate` (which `ByType`/`ByTypeIndex` are
  /// both built on) visits elements in, so it lines up with `Finder.at(index)`.
  int? _typeIndexOf(XmlNode node, String type) {
    var index = 0;
    for (final candidate in _document?.descendants ?? const <XmlNode>[]) {
      if (candidate.getAttribute('class') != type) {
        continue;
      }
      if (identical(candidate, node)) {
        return index;
      }
      index++;
    }
    return null;
  }

  Future<Map<String, dynamic>?> _driveByTypeIndex(
    String command,
    String type,
    int index, {
    int? duration,
    int? dx,
    int? dy,
  }) async {
    final params = <String, String>{
      'command': command,
      'finderType': 'ByTypeIndex',
      'type': type,
      'index': index.toString(),
    };
    if (dx != null && dy != null) {
      params['dx'] = dx.toString();
      params['dy'] = dy.toString();
    }
    if (duration != null) {
      params['duration'] = duration.toString();
    }
    if (command == 'scroll') {
      params['frequency'] = '60';
    }
    final result = await _callDriverExtension(params);
    if (result != null && result['isError'] != true) {
      result['foundBy'] = 'byType';
      result['value'] = '$type#$index';
    }
    return result;
  }

  /// How long to wait for a single finder-based command before giving up on it and letting the
  /// caller's fallback chain (ByType -> ByTypeIndex -> raw coordinate) move on to the next tier.
  static const _driverCallTimeout = Duration(seconds: 2);

  /// Sends [params] through [_driverExtension], working around two ways a `flutter_driver`
  /// finder-based command (tap/scroll/enter_text) can hang indefinitely instead of ever
  /// completing, both from `CommandHandlerFactory.waitForElement`:
  ///
  /// 1. It waits for `SchedulerBinding.transientCallbackCount` to reach zero before (and after)
  ///    acting, *if* frame sync is enabled. A widget with a repeating animation (a loading
  ///    spinner, a shimmer effect) keeps registering new transient ticker callbacks forever, so
  ///    that count never reaches zero. Worked around by disabling frame sync (`set_frame_sync`,
  ///    already implemented by the framework's own `CommandHandlerFactory`) for just this one
  ///    call when a transient callback is currently pending, restoring it immediately after -
  ///    unrelated interactions on non-animating screens keep the normal, safer waiting behavior.
  /// 2. Regardless of frame sync, it *always* waits for the finder itself to evaluate to a
  ///    non-empty result. If the target widget is never considered hit-testable while this is
  ///    polled (e.g. it's part of a continuously-rebuilding animation), this wait alone can hang
  ///    forever - `set_frame_sync` has no effect on it. Worked around with our own timeout: Dart
  ///    can't cancel the original call, so it keeps polling harmlessly in the background, but we
  ///    stop waiting on it and report failure so the caller can fall back instead of hanging.
  Future<Map<String, dynamic>?> _callDriverExtension(Map<String, String> params) async {
    final needsFrameSyncOverride = SchedulerBinding.instance.transientCallbackCount > 0;
    if (needsFrameSyncOverride) {
      await _driverExtension?.call({'command': 'set_frame_sync', 'enabled': 'false'});
    }
    try {
      return await _driverExtension?.call(params).timeout(_driverCallTimeout);
    } on TimeoutException {
      return {'isError': true, 'response': 'timed out waiting for the finder to resolve'};
    } finally {
      if (needsFrameSyncOverride) {
        await _driverExtension?.call({'command': 'set_frame_sync', 'enabled': 'true'});
      }
    }
  }

  /// Synthesizes a tap/scroll gesture directly at a screen coordinate via the widget-testing
  /// `WidgetController` (bypassing flutter_driver's finder resolution entirely), for when no
  /// finder-based locator can reliably target the widget under that point.
  Future<Map<String, dynamic>?> _driveByCoordinate(
    String command,
    int x,
    int y, {
    int? dx,
    int? dy,
  }) async {
    final prober = _driverExtension?.prober;
    if (prober == null) {
      return {'isError': true};
    }
    try {
      if (command == 'scroll' && dx != null && dy != null) {
        await prober.dragFrom(
          Offset(x.toDouble(), y.toDouble()),
          Offset(dx.toDouble(), dy.toDouble()),
        );
      } else {
        await prober.tapAt(Offset(x.toDouble(), y.toDouble()));
      }
      return {'isError': false};
    } catch (e) {
      return {'isError': true};
    }
  }

  /// Sends a `flutter_driver` finder-based command (tap/scroll/enter_text) via the driver
  /// extension, or synthesizes a result directly for the read-only `check_text`/`check_existence`
  /// commands (used by Appium Inspector's "Test This Value"/"Verify Existence" actions).
  Future<Map<String, dynamic>?> _driveFinder(
    String command,
    String finderType,
    String finderValueKey,
    String value, {
    String? enterText,
    int? duration,
    int? dx,
    int? dy,
  }) async {
    final foundBy = _foundByFor(finderType);
    if (command == 'check_text' || command == 'check_existence') {
      return {'isError': false, 'foundBy': foundBy, 'value': value};
    }

    final params = <String, String>{
      'command': command,
      'finderType': finderType,
      finderValueKey: value,
    };
    if (dx != null && dy != null) {
      params['dx'] = dx.toString();
      params['dy'] = dy.toString();
    }
    if (duration != null) {
      params['duration'] = duration.toString();
    }
    if (command == 'scroll') {
      params['frequency'] = '60';
    }
    if (command == 'enter_text') {
      await _focusForTextEntry({'finderType': finderType, finderValueKey: value});
      params['text'] = enterText!;
    }
    final result = await _callDriverExtension(params);
    if (result != null && result['isError'] != true) {
      result['foundBy'] = foundBy;
      result['value'] = value;
      if (command == 'enter_text') {
        await _submitTextEntry();
        result['submitted'] = true;
      }
    }
    return result;
  }

  /// `EnterText` (unlike `tap`/`scroll`) ignores whatever finder is sent along with it - it just
  /// types into whichever widget currently has keyboard focus (`TestTextInput.enterText`, see
  /// `handler_factory.dart#_enterText`). Without an actual tap first, nothing has focus (or
  /// something unrelated still does), so the text has nowhere to go.
  ///
  /// Order matters here: text entry emulation (`TestTextInput.register()`) must be enabled
  /// *before* the tap, not after. Registering swaps the platform's `flutter/textinput` channel
  /// handler for a fake one that only learns the active connection's client id by intercepting
  /// the `TextInput.setClient` call the framework makes when a field is focused/attached
  /// (`TestTextInput._client`, set from inside that intercepted call). If the tap (and the
  /// `TextInput.attach` it triggers) happens first, that `setClient` call goes to the real
  /// platform channel instead, `_client` is never captured, and `EnterText` silently has no
  /// connection to send the typed text to - which is exactly what was happening before this was
  /// reordered.
  Future<void> _focusForTextEntry(Map<String, String> finderParams) async {
    await _callDriverExtension({'command': 'set_text_entry_emulation', 'enabled': 'true'});
    await _callDriverExtension({...finderParams, 'command': 'tap'});
  }

  /// Sends the on-screen keyboard's "Done" action after entering text (`send_text_input_action`,
  /// `TestTextInput.receiveAction` under the hood - see `handler_factory.dart#_sendTextInputAction`),
  /// so a field's `onSubmitted`/`onFieldSubmitted` fires the same way it would for a real user
  /// pressing the keyboard's action button. `EnterText` alone only updates the field's text; it
  /// doesn't simulate submitting it.
  Future<void> _submitTextEntry() async {
    await _callDriverExtension({'command': 'send_text_input_action', 'action': 'done'});
  }

  Future<Map<String, dynamic>?> _driveKey(
    String command,
    String rawKey, {
    String? enterText,
    int? duration,
    int? dx,
    int? dy,
  }) async {
    var key = rawKey;
    if (key.startsWith("[<'")) {
      key = key.substring(3, key.indexOf("'>]"));
    } else if (key.startsWith('[')) {
      key = key.substring(1, key.indexOf(']'));
    }

    if (command == 'check_text' || command == 'check_existence') {
      return {'isError': false, 'foundBy': 'byValueKey', 'value': key};
    }

    final params = <String, String>{
      'command': command,
      'finderType': 'ByValueKey',
      'keyValueString': key,
      'keyValueType': 'String',
    };
    if (dx != null && dy != null) {
      params['dx'] = dx.toString();
      params['dy'] = dy.toString();
    }
    if (duration != null) {
      params['duration'] = duration.toString();
    }
    if (command == 'scroll') {
      params['frequency'] = '60';
    }
    if (command == 'enter_text') {
      await _focusForTextEntry({
        'finderType': 'ByValueKey',
        'keyValueString': key,
        'keyValueType': 'String',
      });
      params['text'] = enterText!;
    }
    final result = await _callDriverExtension(params);
    if (result != null && result['isError'] != true) {
      result['foundBy'] = 'byValueKey';
      result['value'] = key;
      if (command == 'enter_text') {
        await _submitTextEntry();
        result['submitted'] = true;
      }
    }
    return result;
  }

  String _foundByFor(String finderType) => switch (finderType) {
    'ByTooltipMessage' => 'byTooltip',
    'bySemanticsLabel' => 'bySemanticsLabel',
    'ByText' => 'byText',
    _ => 'byType',
  };

  XmlElement? _findSizeRoot(XmlElement element) {
    final rect = _boundsToRect(element.getAttribute('bounds'));
    XmlElement? contained = element;
    while (contained?.parentElement != null) {
      final parentRect = _boundsToRect(
        contained?.parentElement?.getAttribute('bounds'),
      );
      if (rect?.left == parentRect?.left && rect?.right == parentRect?.right) {
        contained = contained?.parentElement;
      } else {
        return contained;
      }
    }
    return contained;
  }

  Future<String?> _findNodeLabel(XmlNode node) async {
    final text = node.getAttribute('semanticLabel');
    if (text != null && text.isNotEmpty) {
      return text;
    }
    for (final element in node.childElements) {
      final childText = await _findNodeLabel(element);
      if (childText != null && childText.isNotEmpty) {
        return childText;
      }
    }
    return null;
  }

  Future<String?> _findNodeText(XmlNode node) async {
    return node.getAttribute('text');
  }

  Future<String?> _findNodeTooltip(XmlNode node) async {
    return node.getAttribute('tooltip');
  }

  /// Whether [node] carries an attribute a generated locator could actually use - the same
  /// tooltip/semanticLabel/key/text set `_execCommandWithFinderChain`'s priority chain checks.
  /// Guards against the 'key' attribute's own "null" string quirk (an absent key is serialized
  /// as the literal text "null", not an empty attribute - see `visitorTree` above) as well as
  /// the usual empty-string case.
  bool _hasIdentifyingAttribute(XmlNode node) {
    for (final name in const ['tooltip', 'semanticLabel', 'key', 'text']) {
      final value = node.getAttribute(name);
      if (value != null && value.isNotEmpty && value != 'null') {
        return true;
      }
    }
    return false;
  }

  /// Resolves the widget at [pos]: the most specific (deepest) matching node, unless a
  /// same-bounds ancestor directly above it is the only one in that chain with an identifying
  /// attribute (see `_hasIdentifyingAttribute`). Such ancestors (e.g. a `Semantics` wrapper
  /// around a plain RenderObject-level widget) are otherwise invisible here: their bounds
  /// exactly match their child's, so always taking "the deepest match" silently prefers the
  /// unnamed RenderObject over the widget that's actually nameable, which then can only be
  /// acted on/recorded by raw coordinates. Mirrors `collapsePassThroughAncestors` in
  /// appium-inspector's `element-hit-testing.js`, which applies the same idea client-side for
  /// the right-click disambiguation menu.
  XmlNode? _getNodeFromOffset(Offset pos) {
    XmlNode? best;
    for (final node in (_document?.descendants.toList() ?? []).reversed) {
      final bounds = node.getAttribute('bounds');
      if (bounds == null || !_boundsToRect(bounds)!.contains(pos)) {
        continue;
      }

      if (best == null) {
        best = node;
        continue;
      }

      final isSameTarget = bounds == best.getAttribute('bounds') && best.ancestors.contains(node);
      if (!isSameTarget) {
        // 'node' is outside best's own same-bounds chain (an unrelated overlap, or simply a
        // genuinely larger ancestor) - stop here rather than risk climbing arbitrarily far up
        // the tree looking for a name.
        break;
      }
      if (!_hasIdentifyingAttribute(best) && _hasIdentifyingAttribute(node)) {
        best = node;
      }
    }
    return best;
  }

  /// Resolves the target node for a context-menu action. When the Inspector's disambiguation
  /// submenu was used to pick a specific element among several overlapping candidates at the
  /// same point, [elementId] carries that choice and is looked up directly; otherwise falls back
  /// to coordinate hit-testing, matching the plain single-candidate behavior.
  ///
  /// [id]s (`inspector-N`) aren't stable identifiers for a given widget - they're assigned fresh,
  /// in traversal order, on every `getPageSource` call. The disambiguation submenu captures one
  /// at right-click time, but the action it drives (tap/enterText/checkText/checkExistence) only
  /// fires later, when the user picks an item - if a page-source refresh lands in between (the
  /// periodic auto-refresh, or the user switching to NATIVE_APP context and back), that same id
  /// string can now belong to a completely different widget that happens to occupy it in the
  /// rebuilt tree, rather than the one the user actually selected. Silently trusting a same-id
  /// match after that would act on the wrong widget - which looks indistinguishable from a stray
  /// coordinate-based tap landing wherever that widget happens to be. Cross-checking that the
  /// found node's own bounds still contain the original click point catches this: a genuinely
  /// current id always satisfies it (that's where the user right-clicked), while a stale/reused
  /// one usually won't.
  ///
  /// [x]/[y] are nullable to also serve appium-flutter-driver's standard 'elementClick' passthrough
  /// (see 'driver.ts'), which only has an id - no click point to cross-check against at all, since
  /// it wasn't driven from a screenshot click. In that case the id match is trusted outright.
  XmlNode? _resolveNode(int? x, int? y, String? elementId) {
    if (elementId != null && elementId.isNotEmpty) {
      for (final node in _document?.descendants ?? const <XmlNode>[]) {
        if (node.getAttribute('id') != elementId) {
          continue;
        }
        if (x == null || y == null) {
          return node;
        }
        final pos = Offset(x.toDouble(), y.toDouble());
        final bounds = node.getAttribute('bounds');
        final rect = bounds != null ? _boundsToRect(bounds) : null;
        return (rect != null && rect.contains(pos)) ? node : null;
      }
      return null;
    }
    if (x == null || y == null) {
      return null;
    }
    return _getNodeFromOffset(Offset(x.toDouble(), y.toDouble()));
  }

  /// Resolves a recorded Flutter locator ([foundBy]/[value], the same shape
  /// `_computeRecordableLocator` echoes back to Appium Inspector for code generation) back to a
  /// live node in the current page source - the mirror image of `_computeRecordableLocator`.
  ///
  /// Used as a fallback in `_performActions` when a caller supplies only a recorded locator with
  /// no elementId and no click point at all - e.g. hand-authored WebdriverIO/Python code replaying
  /// a locator captured from an earlier interactive recording, rather than driving live through
  /// Appium Inspector's own screenshot clicks. Once resolved, the node flows through the exact same
  /// `_execCommandWithFinder`/`_execCommandWithFinderChain` path as an elementId/coordinate-resolved
  /// one, so tap/enterText/checkText/checkExistence all behave identically either way - including
  /// falling through to the caller's existing "not found" handling (`return '{}'` in
  /// `_performActions`) when nothing currently matches, which doubles as checkExistence's actual
  /// existence check.
  XmlNode? _findNodeByLocator(String? foundBy, String? value) {
    if (foundBy == null || value == null || value.isEmpty) {
      return null;
    }
    if (foundBy == 'byType') {
      // 'value' may be a bare type name, or 'Type#index' (see '_typeIndexOf') when a plain type
      // match was ambiguous at recording time (more than one node shared the type) and got
      // narrowed to a specific position among them. The indexed form needs a dedicated counting
      // pass in document order - the same order '_typeIndexOf' counts in - rather than the
      // single-node attribute check every other case below does.
      final parts = value.split('#');
      final type = parts[0];
      final index = parts.length > 1 ? int.tryParse(parts[1]) : null;
      var count = 0;
      for (final candidate in _document?.descendants ?? const <XmlNode>[]) {
        if (candidate.getAttribute('class') != type) {
          continue;
        }
        if (index == null || count == index) {
          return candidate;
        }
        count++;
      }
      return null;
    }
    for (final node in _document?.descendants ?? const <XmlNode>[]) {
      switch (foundBy) {
        case 'byTooltip':
          if (node.getAttribute('tooltip') == value) {
            return node;
          }
          break;
        case 'bySemanticsLabel':
          if (node.getAttribute('semanticLabel') == value) {
            return node;
          }
          break;
        case 'byValueKey':
          final key = node.getAttribute('key');
          if (key == value && key != 'null') {
            return node;
          }
          break;
        case 'byText':
          if (node.getAttribute('text') == value) {
            return node;
          }
          break;
      }
    }
    return null;
  }

  Rect? _boundsToRect(String? bounds) {
    if (bounds == null) {
      return null;
    }
    final leftRight = bounds.split('][');
    final topLeft = leftRight[0].split(',');
    final left = topLeft[0].substring(1);
    final top = topLeft[1];
    final bottomRight = leftRight[1].split(',');
    final right = bottomRight[0];
    final bottom = bottomRight[1].substring(0, bottomRight[1].length - 1);
    return Rect.fromLTRB(
      double.parse(left),
      double.parse(top),
      double.parse(right),
      double.parse(bottom),
    );
  }
}
