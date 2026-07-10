import 'dart:convert';
import 'dart:ui';

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

  void buildDriverExtension() {
    _driverExtension = AppiumHandlerDriverExtension(appiumHandler, true, false);
  }

  Future<String> appiumHandler(String? cmd) async {
    final cmdAndArg = cmd?.split(':');
    final msg = cmdAndArg?[0];
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
    final tree = AppiumWidgetInspectorService();

    void layoutTree(Map<String, dynamic>? element) {
      final valueId = element?['valueId'];

      double left = 0.0;
      double top = 0.0;
      double width = 0.0;
      double height = 0.0;

      final layout = tree.getLayoutExplorerNode({
        'id': valueId,
        'subtreeDepth': '100000',
        'groupName': 'tree_1',
      });
      final Map<String, dynamic> result =
          layout['result'] as Map<String, dynamic>;
      final Map<String, dynamic> size = result['size'];
      width = double.parse(size['width']);
      height = double.parse(size['height']);
      if (result['parentData'] != null) {
        final Map<String, dynamic> parentData = result['parentData'];
        left = double.parse(parentData['globalX']);
        top = double.parse(parentData['globalY']);
      }

      final topLeft = Offset(left, top);
      final bottomRight = Offset(left + width, top + height);
      _treeItemOffsets[valueId] = [topLeft, bottomRight];

      if (element?['hasChildren'] as bool) {
        for (final child in element?['children']) {
          layoutTree(child);
        }
      }
    }

    void visitorTree(Map<String, dynamic>? element) {
      final String runtimeType = element?['widgetRuntimeType'];
      final type = runtimeType.replaceAll('<', '-').replaceAll('>', '-');
      final valueId = element?['valueId'];

      final properties = tree.myGetProperties(valueId, 'tree_1');
      String? key;
      String? text;
      String? enabled;
      String? toolTip;
      String? semanticLabel;
      for (final property in properties as List<dynamic>) {
        final description = (property['description'] as String?)?.replaceAll(
          '"',
          '',
        );
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
      if (element?['hasChildren'] as bool) {
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
      if (key != null && key.isNotEmpty) {
        foundBy = 'byValueKey';
        value = key;
      }
      final text = node.getAttribute('text');
      if (text != null && text.isNotEmpty) {
        foundBy = 'byText';
        value = text;
      }
    }
    return '{"isError": false, "foundBy": "$foundBy", "text": "$value"}';
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
    if (key != null && key.isNotEmpty) {
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
          final node = _getNodeFromOffset(Offset(x!.toDouble(), y!.toDouble()));
          final result = await _execCommandWithFinder(
            x,
            y,
            node!,
            'enter_text',
            enterText: action['text'],
            foundBy: foundBy,
            value: foundValue,
          );
          if (result != null && result['isError'] != true) {
            return _actionResult(node, result);
          }
          break;
        case 'checkText':
          final node = _getNodeFromOffset(Offset(x!.toDouble(), y!.toDouble()));
          final result = await _execCommandWithFinder(
            x,
            y,
            node!,
            'check_text',
            enterText: action['text'],
            foundBy: foundBy,
            value: foundValue,
          );
          if (result != null && result['isError'] != true) {
            return _actionResult(node, result);
          }
          break;
        case 'checkExistence':
          final node = _getNodeFromOffset(Offset(x!.toDouble(), y!.toDouble()));
          final result = await _execCommandWithFinder(
            x,
            y,
            node!,
            'check_existence',
            enterText: '',
            foundBy: foundBy,
            value: foundValue,
          );
          if (result != null && result['isError'] != true) {
            return _actionResult(node, result);
          }
          break;
      }
    }
    return '{}';
  }

  String _actionResult(XmlNode node, Map<String, dynamic> result) {
    return '{"text":"${node.getAttribute('text')}","elementId":"${node.getAttribute('id')}",'
        '"type":"${node.getAttribute('class')}","foundBy":"${result['foundBy']}","value":"${result['value']}"}';
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
    if (key != null && key.isNotEmpty) {
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
    final type = foundBy == 'byType' ? value! : node.getAttribute('class')!;
    return _driveFinder(
      command,
      'ByType',
      'type',
      type,
      enterText: enterText,
      duration: duration,
      dx: dx,
      dy: dy,
    );
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
      params['text'] = enterText!;
    }
    final result = await _driverExtension?.call(params);
    if (result != null && result['isError'] != true) {
      result['foundBy'] = foundBy;
      result['value'] = value;
    }
    return result;
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

    if (command == 'enter_text') {
      await _driverExtension?.call({
        'command': 'set_text_entry_emulation',
        'finderType': 'ByValueKey',
        'keyValueString': 'textfield',
        'keyValueType': 'String',
        'enabled': 'true',
      });
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
      params['text'] = enterText!;
    }
    final result = await _driverExtension?.call(params);
    if (result != null && result['isError'] != true) {
      result['foundBy'] = 'byValueKey';
      result['value'] = key;
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

  XmlNode? _getNodeFromOffset(Offset pos) {
    XmlNode? contained;
    for (final node in (_document?.descendants.toList() ?? []).reversed) {
      final bounds = node.getAttribute('bounds');
      if (bounds == null) {
        continue;
      }
      if (contained == null && _boundsToRect(bounds)!.contains(pos)) {
        contained = node;
      }
    }
    return contained;
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
