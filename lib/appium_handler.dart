import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart' as ft;
import 'package:xml/xml.dart';

import 'appium_handler_extension.dart';
import 'widget_tree.dart';

// XML属性値として埋め込む前に特殊文字をエスケープする。実機で確認済み: GlobalKey<FormFieldState
// <String>>のような型パラメータ付きキーの文字列表現(`<`/`>`を含む)や、テキスト内容に含まれる`&`
// をエスケープせずそのまま埋め込むと、XmlDocument.parse(_source)がXmlParserExceptionで失敗し、
// getPageSource()全体が例外を投げていた(地図を含む画面で再現: 毎回同じ行・列で失敗していた)。
// `&`は`<`/`>`より先に置換する(先に`<`を`&lt;`に置換すると、そのエスケープ済み文字列内の`&`が
// 二重エスケープされてしまうため)。
String _escapeXmlAttribute(String? value) {
  if (value == null) {
    return '';
  }
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

// 画面として完全に隠れている(=どの finder からも見えない)部分木に属する Element をすべて集める。
// Navigator は上に不透明な route が積まれても下の route を Element ツリーに残す(Overlay の
// `_Theater` が skipCount より前の entry を offstage として保持する)ため、これを除外しないと
// ページソースに前の画面のウィジェットが全部残り、次の不整合を起こしていた:
// - `_typeIndexOf` は前の画面の同型ウィジェットも数えるが、実際に操作する `ByTypeIndexFinder`
//   (`find.byElementPredicate`、既定で `skipOffstage: true`)は数えないため、`Type#N` が別の
//   ウィジェットを指す
// - `byText` 等が前の画面の同じテキストにも一致し、一意にならない
// 判定には finder と同じ `Element.debugVisitOnstageChildren` を使う(assert ガードではないので
// Profile/Release でも動く)。ただし対象は「画面単位で隠す」親(Overlay の `_Theater`、`Offstage`、
// `IndexedStack` の非選択の子、`SliverOffstage`)に限る。Sliver/Viewport の
// debugVisitOnstageChildren はスクロールで画面外に出たリスト項目も除くが、それまで消すと
// 呼び出し側が「画面外の欄を見つけてスクロールする」ことができなくなるため対象外とする。
// `_Theater`/`_RawIndexedStack` は private クラスなので runtimeType 名で判定している
// (`--obfuscate` ビルドでは一致しなくなり、除外されないだけで従来どおりの出力になる)。
Set<Element> _collectScreenHiddenElements(Element root) {
  final hidden = <Element>{};

  bool hidesOffstageChildren(Element element) {
    final widget = element.widget;
    if (widget is Offstage || widget is SliverOffstage) {
      return true;
    }
    final name = widget.runtimeType.toString();
    return name == '_Theater' || name == '_RawIndexedStack';
  }

  void markHidden(Element element) {
    hidden.add(element);
    element.visitChildren(markHidden);
  }

  void walk(Element element) {
    if (!hidesOffstageChildren(element)) {
      element.visitChildren(walk);
      return;
    }
    final onstage = <Element>{};
    element.debugVisitOnstageChildren(onstage.add);
    element.visitChildren((child) {
      if (onstage.contains(child)) {
        walk(child);
      } else {
        markHidden(child);
      }
    });
  }

  walk(root);
  return hidden;
}

// 入力欄(TextField/TextFormField)の InputDecoration に設定された labelText/hintText を返す。
// Key も semanticLabel も無い欄を番号(Type#N)ではなく、欄自身の文言で特定できるようにするため。
// 描画された Text ではなく、ウィジェットの設定値を読む: ラベル/ヒントの Text は framework 内部
// (InputDecorator)で作られるので、Debug ビルドの summary tree には出てこない(Profile の全ツリー
// にだけ出る)。また hintText は入力すると画面から消えるが、設定値は残る。TextFormField は内部で
// TextField を作り、decoration は TextField 側にしか公開されていないので、自分自身または子孫の
// 最初の TextField を探す。
({String? label, String? hint}) _inputDecorationTexts(Object? object) {
  if (object is! Element) {
    return (label: null, hint: null);
  }
  TextField? textField;
  void find(Element element) {
    if (textField != null) {
      return;
    }
    final widget = element.widget;
    if (widget is TextField) {
      textField = widget;
      return;
    }
    element.visitChildren(find);
  }

  find(object);
  final decoration = textField?.decoration;
  return (label: decoration?.labelText, hint: decoration?.hintText);
}

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

  /// When true, every coordinate hit test (`_hitTestNodeFromOffset`) logs its hit-test path and
  /// which page-source node it resolved to (up to ~20 lines per tap). Off by default since it's
  /// very noisy; it was the instrumentation that pinned down a coordinate tap on an AppBar
  /// button being delivered to a bottom navigation bar tab instead - set it right after
  /// constructing the handler to investigate a
  /// similar misdelivery again, and filter device logs by the `[appium_handler][hitTest]` prefix.
  bool verboseHitTestLogging = false;

  void _logHitTest(String message) {
    if (verboseHitTestLogging) {
      debugPrint(message);
    }
  }

  /// Tests only: forces the Profile/Release-only page-source pruning on (or off) regardless of
  /// whether widget creation is tracked (it always is under `flutter test`).
  @visibleForTesting
  bool? debugForcePruneWrappers;

  // The live (finder-order) same-type index of every onstage Element, refreshed on each
  // `getPageSource` - see `_computeLiveTypeIndex`.
  Map<Element, int> _liveTypeIndex = {};

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

      // 画面として隠れている部分木(前の route、非選択のタブ等。_collectScreenHiddenElements 参照)。
      // 判定自体が失敗した場合は、ページソース取得全体を失敗させるより、従来どおり除外なしで
      // 出力するほうを選ぶ。
      // 除外の結果は、logcat/syslog を取らなくても失敗時の XML ダンプだけで確認できるよう、
      // ルートの <tree> 要素の属性(offstageFilter/hiddenElements/skippedNodes)にも出す。
      var screenHidden = <Element>{};
      var filterStatus = 'ok';
      try {
        final rootElement = WidgetsBinding.instance.rootElement;
        if (rootElement != null) {
          screenHidden = _collectScreenHiddenElements(rootElement);
        } else {
          filterStatus = 'no root element';
        }
      } catch (e) {
        filterStatus = 'failed: $e';
        debugPrint('[appium_handler] collecting offstage elements failed, not filtering: $e');
      }

      // ページソースのノードが、画面として隠れている部分木に属するか。属する場合は子孫も
      // すべて属するので、呼び出し側はそのノード以下を丸ごと飛ばしてよい。
      var skippedNodes = 0;
      var unresolvedNodes = 0;
      bool isScreenHidden(String? valueId) {
        if (valueId == null || screenHidden.isEmpty) {
          return false;
        }
        try {
          // ignore: invalid_use_of_protected_member
          final object = tree.toObject(valueId);
          if (object is! Element) {
            unresolvedNodes++;
            return false;
          }
          if (screenHidden.contains(object)) {
            skippedNodes++;
            return true;
          }
          return false;
        } catch (_) {
          unresolvedNodes++;
          return false;
        }
      }

      // 各 Element の「同じ型の中での番号」を、ByTypeIndexFinder(find.byElementPredicate(...).at(N)、
      // skipOffstage: true)が数えるのと同じ順番・同じ範囲で求めておく(_liveTypeIndexOf 参照)。
      // ページソース上での並び順で数えると、ページソースに出ない要素(Debug の summary tree では
      // フレームワーク内部で作られた Container/InkWell 等)の分だけ再生時の番号とずれ、Debug と
      // Profile(全ツリー)でも番号が変わってしまう。
      _liveTypeIndex = _computeLiveTypeIndex();

      // Profile/Release ではウィジェットの作成場所が記録されないため、summary tree のフィルタが
      // 効かず、フレームワーク内部のウィジェットまで全部出てくる(2026-10-05 の試算で、ある画面の
      // 1 つの route だけで 1596 ノード)。表示を見やすくするため、手がかりの無い「構造だけの包み」と
      // サイズ 0 の葉を出力しない(_isCollapsibleWrapper 参照)。Debug(作成場所が記録される)では
      // 従来どおり何も省かない。
      final pruneWrappers = debugForcePruneWrappers ?? !tree.isWidgetCreationTracked();
      var collapsedNodes = 0;

      Element? elementOf(String? valueId) {
        if (valueId == null) {
          return null;
        }
        try {
          // ignore: invalid_use_of_protected_member
          final object = tree.toObject(valueId);
          return object is Element ? object : null;
        } catch (_) {
          return null;
        }
      }

      // Computes and caches this node's bounds in `_treeItemOffsets`. Failures here are
      // per-widget (e.g. a widget with no RenderBox/layout data yet) - logged and skipped
      // rather than aborting the whole tree, so one problematic widget doesn't take down
      // page source retrieval for the entire app. Recursion into children always happens,
      // even if this node's own bounds lookup failed.
      void layoutTree(Map<String, dynamic>? element) {
        final valueId = element?['valueId'];
        if (isScreenHidden(valueId)) {
          return;
        }
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
        } catch (e) {
          // 実機確認済み: 地図のようなネイティブのPlatformViewを含む画面では、レイアウト情報を
          // 持たないウィジェット(この関数の再帰対象)が深くネストして大量に存在し、その全てで
          // ここに来る。以前はここで毎回フルスタックトレース(数百行)を出力しており、その出力
          // コスト自体がgetPageSource()全体を実質ハングさせ、呼び出し元(Appium/Node側)で
          // タイムアウトを引き起こしていた。この失敗は想定内・頻発するものでスタックトレースに
          // 診断上の価値はないため、メッセージのみ出力する。
          debugPrint('[appium_handler] layoutTree failed for widget $valueId: $e');
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
        if (isScreenHidden(valueId)) {
          return;
        }
        var type = 'Unknown';
        try {
          final String runtimeType = element?['widgetRuntimeType'];
          // 実機確認済み: `<`/`>`だけを置換しても、ジェネリクスの型引数がnullable型(例:
          // `ValueListenableBuilder<bool?>`)の場合、その`?`がタグ名に残ってしまい、XMLの
          // タグ名として不正(かつ`<?`は処理命令の開始と紛らわしい)なため
          // XmlDocument.parse(_source)がXmlParserException("> expected")で失敗していた
          // (地図を含む画面で再現: 毎回同じ位置で失敗)。`?`に限らず今後同種の問題を防ぐため、
          // XML Nameとして有効な文字(英数字/`.`/`-`/`_`/`:`)以外は全て`-`に置換する。
          type = runtimeType.replaceAll(RegExp(r'[^A-Za-z0-9_.:-]'), '-');

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
          var inputTextsAttributes = '';
          if (isEditable) {
            ({String? label, String? hint}) texts = (label: null, hint: null);
            try {
              // ignore: invalid_use_of_protected_member
              texts = _inputDecorationTexts(tree.toObject(valueId));
            } catch (_) {
              // 読めなくても欄自体は出力する(属性が空になるだけ)。
            }
            inputTextsAttributes =
                'label="${_escapeXmlAttribute(texts.label?.replaceAll('"', ''))}" '
                'hint="${_escapeXmlAttribute(texts.hint?.replaceAll('"', ''))}" ';
          }

          var topLeft = const Offset(0.0, 0.0);
          var bottomRight = const Offset(0.0, 0.0);
          final listOffset = _treeItemOffsets[valueId];
          if (listOffset != null) {
            topLeft = listOffset[0];
            bottomRight = listOffset[1];
          }

          final children = ((element?['hasChildren'] as bool?) ?? false)
              ? (element?['children'] as List<dynamic>)
              : const <dynamic>[];
          final hasIdentity = isEditable ||
              (text?.isNotEmpty ?? false) ||
              (toolTip?.isNotEmpty ?? false) ||
              (semanticLabel?.isNotEmpty ?? false) ||
              _isUsableKey(key);
          if (pruneWrappers && !hasIdentity) {
            final isZeroSizeLeaf = children.isEmpty &&
                (bottomRight.dx - topLeft.dx <= 0 || bottomRight.dy - topLeft.dy <= 0);
            final onlyChildBounds = children.length == 1
                ? _treeItemOffsets[(children.first as Map<String, dynamic>?)?['valueId']]
                : null;
            final isPassThrough = onlyChildBounds != null &&
                onlyChildBounds[0] == topLeft &&
                onlyChildBounds[1] == bottomRight &&
                _isCollapsibleWrapper(runtimeType);
            if (isZeroSizeLeaf || isPassThrough) {
              collapsedNodes++;
              for (final child in children) {
                visitorTree(child);
              }
              return;
            }
          }

          final typeIndex = _liveTypeIndex[elementOf(valueId)];
          ++_index;
          _source +=
              '<$type id="$valueId" key="${_escapeXmlAttribute(key)}" index="$_index" class="$type" '
              'typeIndex="${typeIndex ?? ''}" '
              'text="${_escapeXmlAttribute(text)}" tooltip="${_escapeXmlAttribute(toolTip)}" '
              'bounds="[${topLeft.dx.toInt()},${topLeft.dy.toInt()}]'
              '[${bottomRight.dx.toInt()},${bottomRight.dy.toInt()}]" '
              'enabled="${enabled ?? ''}" semanticLabel="${_escapeXmlAttribute(semanticLabel)}" '
              'input="${isEditable ? 'true' : 'false'}" '
              '$inputTextsAttributes'
              'centerX="${((topLeft.dx + bottomRight.dx) / 2).toInt()}" '
              'centerY="${((topLeft.dy + bottomRight.dy) / 2).toInt()}">\n';
        } catch (e) {
          // layoutTreeの同種のcatchブロックと同じ理由(スタックトレース出力のコスト自体が
          // getPageSource()をハングさせる)で、メッセージのみ出力する。
          debugPrint(
            '[appium_handler] visitorTree failed for widget $valueId ($type): $e',
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

      _source = '';
      final result = tree.getRootWidgetSummaryTreeWithPreviews({
        'groupName': 'tree_1',
      });
      layoutTree(result['result'] as Map<String, dynamic>?);
      // layoutTree と visitorTree の両方で同じノードを判定するので、visitorTree の分だけ数える。
      skippedNodes = 0;
      unresolvedNodes = 0;
      collapsedNodes = 0;
      visitorTree(result['result'] as Map<String, dynamic>?);
      _source = '<?xml version="1.0"?>\n'
          '<tree offstageFilter="${_escapeXmlAttribute(filterStatus.replaceAll('"', "'"))}" '
          'hiddenElements="${screenHidden.length}" skippedNodes="$skippedNodes" '
          'unresolvedNodes="$unresolvedNodes" collapsedNodes="$collapsedNodes">\n'
          '$_source</tree>\n';

      _document = XmlDocument.parse(_source);
      return _document.toString();
    } catch (e, stackTrace) {
      // 診断用: XmlParserExceptionはbuffer(パース対象だった_source文字列そのもの)と
      // position(失敗箇所の文字オフセット)を持っている。エスケープ漏れ等で不正なXMLに
      // なった場合、実際にどんな内容が問題なのかをそのオフセット周辺の実文字列で確認する
      // ため出力する。実機のsyslog中継には1行あたりの長さ制限があり、1回のdebugPrintに
      // 前後まとめて出すと肝心の直前部分が切り捨てられることを確認したため、前半・後半を
      // 別々の短いdebugPrintに分ける。
      if (e is XmlParserException && e.buffer != null && e.position != null) {
        final buffer = e.buffer!;
        final pos = e.position!;
        final beforeStart = (pos - 80).clamp(0, buffer.length);
        final afterEnd = (pos + 80).clamp(0, buffer.length);
        debugPrint(
          '[appium_handler] XmlParserException before pos $pos: '
          '${buffer.substring(beforeStart, pos.clamp(0, buffer.length))}',
        );
        debugPrint(
          '[appium_handler] XmlParserException after pos $pos: '
          '${buffer.substring(pos.clamp(0, buffer.length), afterEnd)}',
        );
        // 診断用: syslog中継での表示が化ける/壊れる文字がある場合に備え、position直前・直後の
        // 文字について、見た目の文字ではなくcode unit(整数値)をそのまま出す。
        final codeStart = (pos - 5).clamp(0, buffer.length);
        final codeEnd = (pos + 5).clamp(0, buffer.length);
        final codeUnits = [
          for (var i = codeStart; i < codeEnd; i++) buffer.codeUnitAt(i),
        ];
        debugPrint(
          '[appium_handler] XmlParserException codeUnits[$codeStart..$codeEnd) around pos $pos: '
          '$codeUnits',
        );
      }
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

    // Replaying a `byText` locator whose text isn't on [node] itself (a tap target's label found in
    // the live tree - see `_findNodeByLocator`/`_tapTargetTextFor`): [node] is only the nearest
    // page-source ancestor, possibly much bigger than the target (e.g. a whole bottom navigation
    // bar), so acting on it by id would hit the wrong spot. Drive the text itself instead.
    if (foundBy == 'byText' && value != null && node.getAttribute('text') != value) {
      final result = await _driveFinder(
        command,
        'ByText',
        'text',
        value,
        enterText: enterText,
        duration: duration,
        dx: dx,
        dy: dy,
      );
      if (result != null && result['isError'] != true) {
        result['foundBy'] = 'byText';
        result['value'] = value;
      }
      return result;
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
      // `enter_text` deliberately does NOT fall through to the tooltip/semanticsLabel/key/text/type
      // chain below when the unambiguous id-based attempt fails. Unlike `tap` (where the chain's
      // final `ByType`+`ByTypeIndex` fallback still resolves the *same* recorded index), the chain's
      // `ByType` step for `enter_text` only ever taps a *plain*, non-indexed type name to establish
      // focus (see `_focusForTextEntry`'s callers below) - with more than one `TextFormField` on
      // screen (the normal case), that can silently focus and type into the wrong one instead of
      // failing loudly. Confirmed on-device: after the id-based focus tap timed out (widget disposed
      // between the page-source snapshot and the tap - see `resolveTextFormFieldIndexNearLabel` on
      // the Node side), this fallback still reported `isError:false`, but the typed text landed
      // nowhere near the intended field. Returning the id-based failure directly lets the caller's
      // own retry (re-resolve against a fresh snapshot, then act immediately) run instead.
      if (command == 'enter_text') {
        return result;
      }
    }

    // Only reached if resolving/acting by id somehow failed - e.g. the
    // `AppiumWidgetInspectorService` that minted this id has since been replaced by a newer
    // `getPageSource` call - for anything other than `enter_text` (see above).
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
      final focusResult = await _focusForTextEntry({'finderType': 'ById', 'id': id});
      if (focusResult == null || focusResult['isError'] == true) {
        // フォーカスが確立していないままTestTextInput.enterTextを呼んでも、テキストの行き先が
        // ないまま静かに破棄されるだけなので、ここで打ち切ってエラーとして呼び出し側に返す。
        return {
          'isError': true,
          'response': 'focus tap failed before enter_text: $focusResult',
        };
      }
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
    // Before 'byText' on purpose: a text field's 'text' attribute is whatever was typed into it
    // (its controller's content), which makes a poor locator, and before 'byType' because
    // 'Type#N' shifts whenever a field is added/removed/reordered on the same screen.
    if (foundBy == 'byFieldLabel') {
      return (foundBy: 'byFieldLabel', value: value!);
    }
    final fieldLabel = _fieldLabelLocatorFor(node);
    if (fieldLabel != null) {
      return (foundBy: 'byFieldLabel', value: fieldLabel);
    }
    if (foundBy == 'byText') {
      return (foundBy: 'byText', value: value!);
    }
    final text = await _findNodeText(node);
    if (text != null && text.isNotEmpty) {
      return (foundBy: 'byText', value: text);
    }
    if (foundBy != 'byType') {
      final targetText = _tapTargetTextFor(node);
      if (targetText != null) {
        return (foundBy: 'byText', value: targetText);
      }
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

  /// Each onstage Element's 0-based position among onstage Elements of the same runtime type, in
  /// exactly the order `ByTypeIndexFinder` (`find.byElementPredicate(...).at(N)`) enumerates them
  /// (`collectAllElementsFrom(rootElement, skipOffstage: true)`, the finders' own candidate list).
  /// Counting in the *live* tree rather than in the page source makes a recorded `Type#N` mean the
  /// same widget at replay and in generated Dart (`find.byType(Type).at(N)`), whatever the page
  /// source happens to include - Debug's summary tree leaves out framework-created widgets, while
  /// Profile/Release's full tree doesn't.
  Map<Element, int> _computeLiveTypeIndex() {
    final indexes = <Element, int>{};
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) {
      return indexes;
    }
    final counts = <String, int>{};
    try {
      for (final element in ft.collectAllElementsFrom(root, skipOffstage: true)) {
        final type = element.widget.runtimeType.toString();
        final index = counts[type] ?? 0;
        indexes[element] = index;
        counts[type] = index + 1;
      }
    } catch (e) {
      debugPrint('[appium_handler] computing live type indexes failed: $e');
    }
    return indexes;
  }

  /// Whether a page-source `key` attribute value is a usable locator - not empty, not the
  /// literal "null" an absent key serializes to, and not a Profile/Release build's
  /// "[<optimized out>]" placeholder.
  static bool _isUsableKey(String? key) =>
      key != null && key.isNotEmpty && key != 'null' && !key.contains('optimized out');

  /// Widget types whose node can be left out of a Profile/Release page source when it has no
  /// identifying attribute and exactly the same bounds as its only child: private (`_`-prefixed,
  /// framework-internal) types and well-known structural framework widgets. Deliberately does
  /// not include types callers search for by tag (E2E helpers commonly look for `Text`, `Icon`,
  /// `InkWell`, `TextFormField`, `Container`, `Padding` and the app's own widgets).
  static bool _isCollapsibleWrapper(String runtimeType) {
    final base = runtimeType.split('<').first;
    return base.startsWith('_') || _structuralWrapperTypes.contains(base);
  }

  static const _structuralWrapperTypes = {
    'Semantics', 'Listener', 'ConstrainedBox', 'RawGestureDetector', 'DefaultTextStyle',
    'MouseRegion', 'Actions', 'Focus', 'FocusScope', 'FocusTraversalGroup', 'Shortcuts',
    'KeyedSubtree', 'RepaintBoundary', 'IgnorePointer', 'AbsorbPointer', 'Builder',
    'StatefulBuilder', 'LayoutBuilder', 'MediaQuery', 'Theme', 'AnimatedTheme', 'IconTheme',
    'DefaultSelectionStyle', 'Directionality', 'NotificationListener', 'Material',
    'AnimatedDefaultTextStyle', 'AnimatedPhysicalModel', 'PhysicalModel', 'PhysicalShape',
    'CustomPaint', 'ClipRect', 'ClipRRect', 'ClipPath', 'Align', 'Center', 'SizedBox',
    'LimitedBox', 'Offstage', 'TickerMode', 'Visibility', 'Opacity', 'FadeTransition',
    'SlideTransition', 'AnimatedBuilder', 'ListenableBuilder', 'ValueListenableBuilder',
    'UnmanagedRestorationScope', 'RestorationScope', 'HeroControllerScope', 'TextFieldTapRegion',
    'TapRegion', 'ScrollConfiguration', 'ScrollNotificationObserver', 'PrimaryScrollController',
    'GlowingOverscrollIndicator', 'StretchingOverscrollIndicator', 'CompositedTransformTarget',
    'CompositedTransformFollower', 'DecoratedBox', 'ColoredBox', 'Transform',
    'FractionalTranslation', 'AnimatedSize', 'AnimatedOpacity',
  };

  /// The live Element a page-source node stands for (via its `id`), if still resolvable.
  Element? _elementOfNode(XmlNode node) {
    final id = node.getAttribute('id');
    if (id == null || id.isEmpty) {
      return null;
    }
    try {
      // ignore: invalid_use_of_protected_member
      final object = _inspectorService?.toObject(id);
      return object is Element ? object : null;
    } catch (_) {
      return null;
    }
  }

  /// The page-source node for [element], or for its nearest ancestor that has one (an element can
  /// be missing from the page source - e.g. a framework-created `Text` in Debug's summary tree).
  XmlNode? _nodeForElementOrAncestor(Element element) {
    final nodesByElement = <Element, XmlNode>{};
    for (final node in _document?.descendants ?? const <XmlNode>[]) {
      final nodeElement = _elementOfNode(node);
      if (nodeElement != null) {
        nodesByElement[nodeElement] = node;
      }
    }
    final own = nodesByElement[element];
    if (own != null) {
      return own;
    }
    XmlNode? found;
    element.visitAncestorElements((ancestor) {
      found = nodesByElement[ancestor];
      return found == null;
    });
    return found;
  }

  /// A `byText` locator for a node with no identifying attribute of its own (e.g. a
  /// BottomNavigationBar item's icon, a button's decoration container), taken from the label of
  /// the tap target it belongs to. Walks up the *live* tree (framework widgets included - the label
  /// `Text` of a stock BottomNavigationBar item, AppBar or button is created by the framework, so
  /// it isn't in a Debug build's page source at all) to the nearest gesture-handling ancestor
  /// (`InkResponse`/`InkWell`, `GestureDetector`, `RawGestureDetector`), and uses that target's
  /// text only if it contains exactly one distinct text and that text is unique on screen
  /// (`find.text`, the same finder flutter_driver's `ByText` and generated `find.text(...)` use).
  /// Returns null otherwise (no gesture ancestor nearby, no/several texts, or an ambiguous text),
  /// so the caller falls back to `Type#N`.
  String? _tapTargetTextFor(XmlNode node) {
    final element = _elementOfNode(node);
    if (element == null) {
      return null;
    }
    Element? target;
    var depth = 0;
    bool isTapTarget(Element e) {
      final widget = e.widget;
      return widget is InkResponse || widget is GestureDetector || widget is RawGestureDetector;
    }

    if (isTapTarget(element)) {
      target = element;
    } else {
      element.visitAncestorElements((ancestor) {
        if (isTapTarget(ancestor)) {
          target = ancestor;
          return false;
        }
        return ++depth < 15;
      });
    }
    if (target == null) {
      return null;
    }
    final texts = <String>{};
    void collect(Element e) {
      if (texts.length > 1) {
        return;
      }
      final widget = e.widget;
      // An Icon draws its glyph as a RichText of the icon font's code point - not a label.
      if (widget is Icon || widget is ImageIcon) {
        return;
      }
      String? value;
      if (widget is Text) {
        value = widget.data ?? widget.textSpan?.toPlainText();
      } else if (widget is RichText) {
        value = widget.text.toPlainText();
      }
      if (value != null && value.trim().isNotEmpty) {
        texts.add(value);
      }
      e.visitChildren(collect);
    }

    collect(target!);
    if (texts.length != 1) {
      return null;
    }
    final text = texts.single;
    if (text.contains('|') || ft.find.text(text).evaluate().length != 1) {
      return null;
    }
    return text;
  }

  /// Text-field nodes of class [type] in the current page source whose `label` or `hint`
  /// attribute (the field's `InputDecoration.labelText`/`hintText`, see `_inputDecorationTexts`)
  /// equals [label].
  List<XmlNode> _fieldsWithLabel(String type, String label) => [
        for (final candidate in _document?.descendants ?? const <XmlNode>[])
          if (candidate.getAttribute('class') == type &&
              (candidate.getAttribute('label') == label || candidate.getAttribute('hint') == label))
            candidate,
      ];

  /// A `byFieldLabel` locator value (`'<Type>|<label>'`) for a key-less text field, identifying it
  /// by its own label/hint wording - generated code turns it into
  /// `find.widgetWithText(<Type>, '<label>')` (appium-inspector's `dart-common.js`), and replay
  /// resolves it via `_findNodeByLocator`. Only returned when exactly one field on the current
  /// screen carries that wording, so the recorded locator is never ambiguous; otherwise the caller
  /// falls back to `Type#N`.
  String? _fieldLabelLocatorFor(XmlNode node) {
    final type = node.getAttribute('class');
    if (type != 'TextField' && type != 'TextFormField') {
      return null;
    }
    for (final attribute in const ['label', 'hint']) {
      final label = node.getAttribute(attribute);
      if (label == null || label.isEmpty || label.contains('|')) {
        continue;
      }
      if (_fieldsWithLabel(type!, label).length == 1) {
        return '$type|$label';
      }
    }
    return null;
  }

  /// The 0-based position of [node] among all `_document` nodes sharing its `class` attribute, in
  /// document order - the same order `find.byElementPredicate` (which `ByType`/`ByTypeIndex` are
  /// both built on) visits elements in, so it lines up with `Finder.at(index)`.
  int? _typeIndexOf(XmlNode node, String type) {
    // The live, finder-order index (see `_computeLiveTypeIndex`), when the page source carries it.
    if (node.getAttribute('class') == type) {
      final live = int.tryParse(node.getAttribute('typeIndex') ?? '');
      if (live != null) {
        return live;
      }
    }
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
      final focusResult = await _focusForTextEntry({'finderType': finderType, finderValueKey: value});
      if (focusResult == null || focusResult['isError'] == true) {
        // _driveByIdの同種の変更と同じ理由: フォーカスが確立していないままの
        // enter_textを打ち切ってエラーを返す。
        return {
          'isError': true,
          'response': 'focus tap failed before enter_text: $focusResult',
        };
      }
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
  /// フォーカス用タップの結果を返す。実機確認済み: 対象がFlutterのリスト仮想化によって解決
  /// 直後に破棄されうる位置(スクロール直後の端付近)にあると、このタップ自体が
  /// 「timed out waiting for the finder to resolve」で失敗することがある。従来はこの戻り値を
  /// 誰も見ておらず、タップが失敗してもenter_text自体は「エラーなし」で完了したかのように
  /// 報告され、実際にはフォーカスが確立していないため入力したテキストが行き場を失って
  /// 破棄される(呼び出し側からは検知できない)という問題があった。呼び出し側で結果を見て
  /// enter_text全体を失敗として扱えるよう、この戻り値を返すようにする。
  Future<Map<String, dynamic>?> _focusForTextEntry(
    Map<String, String> finderParams,
  ) async {
    await _callDriverExtension({'command': 'set_text_entry_emulation', 'enabled': 'true'});
    return _callDriverExtension({...finderParams, 'command': 'tap'});
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

  /// Performs a real Flutter hit test at [pos] - the exact mechanism Flutter's own gesture
  /// pipeline uses to decide which widget receives a tap (`GestureBinding.handlePointerEvent`
  /// calls this same `hitTestInView` before dispatching any event) - and maps the result back to
  /// the corresponding node in `_document`.
  ///
  /// Each page-source node's `id` attribute is a `WidgetInspectorService` id (see `visitorTree`
  /// above), resolvable back to its live `Element` via `toObject` - the same lookup
  /// `_driveByDirectCallback` already uses. From there `Element.renderObject` gives the
  /// `RenderObject` a real hit test would actually report, so `result.path` (ordered
  /// front-to-back - `HitTestResult.path`'s own doc says "the first entry ... is the most
  /// specific") can be walked to find the first entry that corresponds to a node in `_document`:
  /// the genuinely topmost widget at this exact point.
  ///
  /// This replaces the previous heuristic (page-source document order, reversed, as a proxy for
  /// paint order), which this app's habit of keeping multiple screens mounted simultaneously at
  /// overlapping bounds could fool: two unrelated widgets from different (visible vs. offstage)
  /// screens can share identical bounds, and document order alone can't tell which one is
  /// actually on top - confirmed on-device via a StackTrace-instrumented debug build, where a
  /// coordinate tap aimed at an AppBar button was instead delivered to a bottom navigation bar
  /// tab, several document-positions away but coincidentally overlapping at that point. A real hit
  /// test can't make that mistake, since it walks the actual render tree instead of guessing from
  /// a flattened list.
  XmlNode? _hitTestNodeFromOffset(Offset pos) {
    final document = _document;
    final inspectorService = _inspectorService;
    if (document == null || inspectorService == null) {
      debugPrint('[appium_handler][hitTest] no _document/_inspectorService at $pos');
      return null;
    }

    final result = HitTestResult();
    final viewId = PlatformDispatcher.instance.views.first.viewId;
    WidgetsBinding.instance.hitTestInView(result, pos, viewId);

    // Built fresh per call (rather than cached alongside `_document`) since it's keyed by live
    // `RenderObject` identity - always safe as long as this runs against the same `_document`/
    // `_inspectorService` pair a preceding `getPageSource()` just produced, which
    // `retryFlutterAction` on the driver side already guarantees by refreshing the page source
    // before every attempt.
    final Map<RenderObject, XmlNode> renderObjectToNode = {};
    var totalNodes = 0;
    var toObjectFailures = 0;
    for (final node in document.descendants) {
      final id = node.getAttribute('id');
      if (id == null || id.isEmpty) {
        continue;
      }
      totalNodes++;
      Object? object;
      try {
        // ignore: invalid_use_of_protected_member
        object = inspectorService.toObject(id);
      } catch (_) {
        toObjectFailures++;
        continue;
      }
      final renderObject = object is Element ? object.renderObject : null;
      if (renderObject != null) {
        // When several page-source nodes resolve to the same RenderObject (e.g. a `Semantics`
        // wrapper and the plain widget it wraps), the later - deeper, per document order - one
        // wins here; `_collapseToIdentifyingAncestor` below climbs back up from it if a shallower
        // ancestor turns out to be the one actually worth naming.
        renderObjectToNode[renderObject] = node;
      }
    }
    _logHitTest(
      '[appium_handler][hitTest] pos=$pos viewId=$viewId pathLength=${result.path.length} '
      'documentNodes=$totalNodes toObjectFailures=$toObjectFailures mapped=${renderObjectToNode.length}',
    );

    var i = 0;
    for (final entry in result.path) {
      final target = entry.target;
      final node = target is RenderObject ? renderObjectToNode[target] : null;
      if (i < 20) {
        _logHitTest(
          '[appium_handler][hitTest]   path[$i] target=${target.runtimeType} '
          'matched=${node != null ? '${node.getAttribute('class')}#${node.getAttribute('id')}' : 'no'}',
        );
      }
      i++;
      if (node != null) {
        _logHitTest(
          '[appium_handler][hitTest] => RESOLVED at path[$i-1]: '
          '${node.getAttribute('class')} id=${node.getAttribute('id')} bounds=${node.getAttribute('bounds')}',
        );
        return node;
      }
    }
    _logHitTest('[appium_handler][hitTest] => NO MATCH in ${result.path.length} path entries');
    return null;
  }

  /// Climbs from [start] through true tree ancestors (`XmlNode.ancestorElements`, not merely
  /// document-adjacent nodes) sharing the exact same `bounds`, preferring one with an
  /// identifying attribute (see `_hasIdentifyingAttribute`) over [start] itself. Such ancestors
  /// (e.g. a `Semantics` wrapper around a plain RenderObject-level widget) are otherwise
  /// invisible here: their bounds exactly match their child's, so always taking the raw
  /// hit-tested node silently prefers the unnamed RenderObject over the widget that's actually
  /// nameable, which then can only be acted on/recorded by raw coordinates. Mirrors
  /// `collapsePassThroughAncestors` in appium-inspector's `element-hit-testing.js`, which applies
  /// the same idea client-side for the right-click disambiguation menu.
  XmlNode _collapseToIdentifyingAncestor(XmlNode start) {
    var best = start;
    final bounds = start.getAttribute('bounds');
    for (final ancestor in start.ancestorElements) {
      if (ancestor.getAttribute('bounds') != bounds) {
        // Bounds diverge - genuinely left start's own footprint, not just a pass-through wrapper.
        break;
      }
      if (!_hasIdentifyingAttribute(best) && _hasIdentifyingAttribute(ancestor)) {
        best = ancestor;
      }
    }
    return best;
  }

  /// Resolves the widget at [pos]: a real hit test (`_hitTestNodeFromOffset`), then collapsed up
  /// to a same-bounds identifying ancestor if one exists (`_collapseToIdentifyingAncestor`).
  XmlNode? _getNodeFromOffset(Offset pos) {
    final hit = _hitTestNodeFromOffset(pos);
    if (hit == null) {
      return null;
    }
    return _collapseToIdentifyingAncestor(hit);
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
    if (foundBy == 'byFieldLabel') {
      // 'value' is '<Type>|<label>' (see '_fieldLabelLocatorFor').
      final separator = value.indexOf('|');
      if (separator <= 0) {
        return null;
      }
      final matches = _fieldsWithLabel(
        value.substring(0, separator),
        value.substring(separator + 1),
      );
      return matches.isEmpty ? null : matches.first;
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
      // 'index' is the live, finder-order index (`typeIndex` attribute, see
      // `_computeLiveTypeIndex`) whenever the page source carries one - only page sources from an
      // older handler fall back to counting same-typed page-source nodes below.
      final hasTypeIndex = _document?.descendants.any(
            (candidate) => (candidate.getAttribute('typeIndex') ?? '').isNotEmpty,
          ) ??
          false;
      if (index != null && hasTypeIndex) {
        for (final candidate in _document?.descendants ?? const <XmlNode>[]) {
          if (candidate.getAttribute('class') == type &&
              candidate.getAttribute('typeIndex') == '$index') {
            return candidate;
          }
        }
        return null;
      }
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
    if (foundBy == 'byText') {
      // A tap target's label recorded by `_tapTargetTextFor` is often a framework-created Text that
      // the page source doesn't contain (Debug's summary tree). Resolve it in the live tree; the
      // returned node is that Text's nearest page-source ancestor, only used to locate the action -
      // `_execCommandWithFinder` then drives it with flutter_driver's `ByText` itself (see there).
      final matches = ft.find.text(value).evaluate();
      if (matches.length == 1) {
        return _nodeForElementOrAncestor(matches.single);
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
