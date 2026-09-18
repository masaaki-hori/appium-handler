// `InspectorSerializationDelegate` and `WidgetInspectorService.objectToDiagnosticsNode` are
// `@visibleForTesting` members of the framework, used here outside of a test on purpose: this
// class exists specifically to reach the same widget-tree/layout data DevTools uses, without
// depending on the full DevTools protocol.
//
// `debugFillProperties` is `@protected` on `Diagnosticable`, meant to be called only by
// framework internals (normally via `DiagnosticableNode.getProperties`) - called directly here
// because that framework path is hardcoded to return no properties at all in profile/release
// builds (see `_getPropertiesManual` below).
// ignore_for_file: invalid_use_of_visible_for_testing_member, invalid_use_of_protected_member

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

// `DiagnosticPropertiesBuilder.add` records each property inside an `assert(() { ... }())` block,
// so in profile/release builds (asserts stripped) the stock builder silently drops everything
// passed to it. This override appends directly, bypassing that assert.
class _UnguardedPropertiesBuilder extends DiagnosticPropertiesBuilder {
  @override
  void add(DiagnosticsNode property) {
    properties.add(property);
  }
}

// Exposes a subset of Flutter DevTools' `WidgetInspectorService` (layout bounds, properties,
// the full widget summary tree) so `appium_handler.dart` can build a page-source-like XML tree
// with pixel bounds for each widget, without needing the full DevTools protocol.
class AppiumWidgetInspectorService with WidgetInspectorService {
  // Hand-rolled replacement for `DiagnosticsNode.toJsonMap`/`toJsonList`: those framework methods
  // build their entire result inside an `assert(() { ... }())` block (see
  // flutter/lib/src/foundation/diagnostics.dart), so in profile/release builds - where asserts are
  // stripped - they silently return an empty map instead of throwing. iOS 14+ refuses to launch a
  // debug-mode Flutter app from the home screen/XCUITest (only from Xcode/Flutter tooling), so an
  // Appium-driven real-device session can only ever run a profile or release build, where the
  // framework methods are unusable for this purpose. The pieces this rebuilds below
  // (`additionalNodeProperties`, `filterChildren`, `filterProperties`, `getChildren`,
  // `getProperties`) are ordinary methods with no assert dependency - only the final
  // `toJsonMap`/`toJsonList` assembly step is assert-gated, so re-implementing just that step is
  // enough to make the summary tree (the same "ignore framework-internal widgets" filtering
  // DevTools relies on, driven by `filterChildren`) work in profile/release builds too.
  Map<String, Object?>? _nodeToJson(
    DiagnosticsNode? node,
    InspectorSerializationDelegate delegate,
  ) {
    if (node == null) {
      return null;
    }
    final Object? value = node.value;
    final Map<String, Object?> json = <String, Object?>{
      'description': node.toDescription(),
      'type': node.runtimeType.toString(),
      if (node.name != null) 'name': node.name,
      'hasChildren': node.getChildren().isNotEmpty,
      ...delegate.additionalNodeProperties(node),
    };
    // Reproduces `_ElementDiagnosticableTreeNode.toJsonMap`'s own addition of this field (the one
    // part of that override not routed through the assert-gated `super.toJsonMap`).
    if (value is Element && !value.debugIsDefunct) {
      json['widgetRuntimeType'] = value.widget.runtimeType.toString();
    }
    if (delegate.includeProperties) {
      final properties = delegate.filterProperties(_getPropertiesManual(node), node);
      json['properties'] = _nodesToJson(properties, delegate, parent: node);
    }
    if (delegate.subtreeDepth > 0) {
      final children = delegate.filterChildren(node.getChildren(), node);
      json['children'] = _nodesToJson(children, delegate, parent: node);
    }
    return json;
  }

  List<Map<String, Object?>> _nodesToJson(
    List<DiagnosticsNode> nodes,
    InspectorSerializationDelegate delegate, {
    required DiagnosticsNode? parent,
  }) {
    return nodes
        .map(
          (node) =>
              _nodeToJson(
                node,
                delegate.delegateForNode(node) as InspectorSerializationDelegate,
              ) ??
              <String, Object?>{},
        )
        .toList();
  }

  DiagnosticsNode? _idToDiagnosticsNode(String? diagnosticableId) {
    final Object? object = toObject(diagnosticableId);
    return WidgetInspectorService.objectToDiagnosticsNode(object);
  }

  // Replacement for `DiagnosticsNode.getProperties()`: `DiagnosticableNode.getProperties` (the
  // implementation reached for Element/Widget-backed nodes) is hardcoded to return an empty list
  // whenever `kReleaseMode || kProfileMode` is true (see
  // flutter/lib/src/foundation/diagnostics.dart) - unlike the `assert`-gated `toJsonMap` issue
  // above, this one is a deliberate, unconditional profile/release short-circuit with no flag to
  // opt back into it. `debugFillProperties` itself carries no such guard, and `Element`'s override
  // forwards to the wrapped `Widget`'s own `debugFillProperties` (`_widget?.debugFillProperties`),
  // so calling it directly reaches the same property list (e.g. a `Text` node's `data`) that
  // `getProperties()` would have returned in a debug build.
  //
  // One more layer of the same issue sits underneath `debugFillProperties` itself:
  // `DiagnosticPropertiesBuilder.add` - the method every `debugFillProperties` override calls to
  // record each property - wraps its entire body in `assert(() { properties.add(property); return
  // true; }())`, so in profile/release builds calling the stock builder collects nothing at all
  // regardless of what `debugFillProperties` does. `_UnguardedPropertiesBuilder` below overrides
  // `add` to append directly, without the assert wrapper.
  List<DiagnosticsNode> _getPropertiesManual(DiagnosticsNode node) {
    final Object? value = node.value;
    if (value is Diagnosticable) {
      final _UnguardedPropertiesBuilder builder = _UnguardedPropertiesBuilder();
      value.debugFillProperties(builder);
      return builder.properties;
    }
    return const <DiagnosticsNode>[];
  }

  Map<String, Object?>? _getRootWidgetSummaryTree(
    String groupName, {
    Map<String, Object>? Function(
      DiagnosticsNode,
      InspectorSerializationDelegate,
    )?
    addAdditionalPropertiesCallback,
  }) {
    return _nodeToJson(
      WidgetsBinding.instance.rootElement?.toDiagnosticsNode(),
      InspectorSerializationDelegate(
        groupName: groupName,
        subtreeDepth: 1000000,
        summaryTree: true,
        service: this,
        addAdditionalPropertiesCallback: addAdditionalPropertiesCallback,
      ),
    );
  }

  Map<String, Object?> getRootWidgetSummaryTreeWithPreviews(
    Map<String, String> parameters,
  ) {
    final String groupName = parameters['groupName']!;
    final Map<String, Object?>? result = _getRootWidgetSummaryTree(
      groupName,
      addAdditionalPropertiesCallback:
          (DiagnosticsNode node, InspectorSerializationDelegate? delegate) {
            final Map<String, Object> additionalJson = <String, Object>{};
            final Object? value = node.value;
            if (value is Element) {
              final RenderObject? renderObject = value.renderObject;
              if (renderObject is RenderParagraph) {
                additionalJson['textPreview'] = renderObject.text.toPlainText();
              }
              additionalJson['key'] = value.widget.key.toString();
            }
            return additionalJson;
          },
    );
    return {'result': result};
  }

  // Named to avoid colliding with WidgetInspectorService's own public `getProperties`
  // (String Function(String, String), JSON-encoded), which has a different, incompatible
  // signature from what appium_handler.dart needs (the raw List<Object> properties).
  List<Object> myGetProperties(String? diagnosticableId, String groupName) {
    final DiagnosticsNode? node = _idToDiagnosticsNode(diagnosticableId);
    if (node == null) {
      return const <Object>[];
    }
    return _nodesToJson(
      _getPropertiesManual(node),
      InspectorSerializationDelegate(groupName: groupName, service: this),
      parent: node,
    );
  }

  Map<String, Object?> getLayoutExplorerNode(Map<String, String> parameters) {
    final String? diagnosticableId = parameters['id'];
    final int subtreeDepth = int.parse(parameters['subtreeDepth']!);
    final String? groupName = parameters['groupName'];
    Map<String, dynamic>? result = <String, dynamic>{};
    final DiagnosticsNode? root = _idToDiagnosticsNode(diagnosticableId);
    if (root == null) {
      return {'result': result};
    }
    result = _nodeToJson(
      root,
      InspectorSerializationDelegate(
        groupName: groupName,
        summaryTree: true,
        subtreeDepth: subtreeDepth,
        service: this,
        addAdditionalPropertiesCallback:
            (DiagnosticsNode node, InspectorSerializationDelegate delegate) {
              final Object? value = node.value;
              final RenderObject? renderObject = value is Element
                  ? value.renderObject
                  : null;
              if (renderObject == null) {
                return const <String, Object>{};
              }

              final DiagnosticsSerializationDelegate
              renderObjectSerializationDelegate = delegate.copyWith(
                subtreeDepth: 0,
                includeProperties: true,
                expandPropertyValues: false,
              );
              final Map<String, Object> additionalJson = <String, Object>{
                // Only include renderObject properties separately if this value is not already the
                // renderObject, and only if we are expanding property values, to mitigate the risk of
                // infinite loops if RenderObjects have properties that are Element objects.
                if (value is! RenderObject && delegate.expandPropertyValues)
                  'renderObject': renderObject.toDiagnosticsNode().toJsonMap(
                    renderObjectSerializationDelegate,
                  ),
              };

              final RenderObject? renderParent = renderObject.parent;
              if (renderParent != null &&
                  delegate.subtreeDepth > 0 &&
                  delegate.expandPropertyValues) {
                final Object? parentCreator = renderParent.debugCreator;
                if (parentCreator is DebugCreator) {
                  additionalJson['parentRenderElement'] = parentCreator.element
                      .toDiagnosticsNode()
                      .toJsonMap(
                        delegate.copyWith(
                          subtreeDepth: 0,
                          includeProperties: true,
                        ),
                      );
                }
              }

              try {
                if (!renderObject.debugNeedsLayout) {
                  final Constraints constraints = renderObject.constraints;
                  final Map<String, Object> constraintsProperty =
                      <String, Object>{
                        'type': constraints.runtimeType.toString(),
                        'description': constraints.toString(),
                      };
                  if (constraints is BoxConstraints) {
                    constraintsProperty.addAll(<String, Object>{
                      'minWidth': constraints.minWidth.toString(),
                      'minHeight': constraints.minHeight.toString(),
                      'maxWidth': constraints.maxWidth.toString(),
                      'maxHeight': constraints.maxHeight.toString(),
                    });
                  }
                  additionalJson['constraints'] = constraintsProperty;
                }
              } catch (e) {
                // Constraints are sometimes unavailable even though debugNeedsLayout is false.
              }

              final double left = renderObject.paintBounds.left;
              final double top = renderObject.paintBounds.top;
              try {
                if (renderObject is RenderBox) {
                  additionalJson['isBox'] = true;
                  additionalJson['size'] = <String, Object>{
                    'width': renderObject.size.width.toString(),
                    'height': renderObject.size.height.toString(),
                  };

                  final ParentData? parentData = renderObject.parentData;
                  if (parentData is FlexParentData) {
                    additionalJson['flexFactor'] = parentData.flex!;
                    additionalJson['flexFit'] =
                        (parentData.fit ?? FlexFit.tight).name;
                  } else if (parentData is BoxParentData) {
                    final Offset offset = parentData.offset;
                    final Offset offsetG = renderObject.localToGlobal(
                      Offset(left, top),
                    );
                    additionalJson['parentData'] = <String, Object>{
                      'offsetX': offset.dx.toString(),
                      'offsetY': offset.dy.toString(),
                      'globalX': offsetG.dx.toString(),
                      'globalY': offsetG.dy.toString(),
                    };
                  }
                } else if (renderObject is RenderView) {
                  additionalJson['size'] = <String, Object>{
                    'width': renderObject.size.width.toString(),
                    'height': renderObject.size.height.toString(),
                  };
                }
              } catch (e) {
                // Not laid out yet.
              }

              if (additionalJson['parentData'] == null &&
                  renderObject is RenderBox) {
                final Offset topLeft = renderObject.localToGlobal(
                  Offset(left, top),
                );
                additionalJson['parentData'] = <String, Object>{
                  'offsetX': left,
                  'offsetY': top,
                  'globalX': topLeft.dx.toString(),
                  'globalY': topLeft.dy.toString(),
                };
              }

              return additionalJson;
            },
      ),
    );
    return {'result': result};
  }
}
