// `InspectorSerializationDelegate` and `WidgetInspectorService.objectToDiagnosticsNode` are
// `@visibleForTesting` members of the framework, used here outside of a test on purpose: this
// class exists specifically to reach the same widget-tree/layout data DevTools uses, without
// depending on the full DevTools protocol.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

// Exposes a subset of Flutter DevTools' `WidgetInspectorService` (layout bounds, properties,
// the full widget summary tree) so `appium_handler.dart` can build a page-source-like XML tree
// with pixel bounds for each widget, without needing the full DevTools protocol.
class AppiumWidgetInspectorService with WidgetInspectorService {
  Map<String, Object?>? _nodeToJson(
    DiagnosticsNode? node,
    InspectorSerializationDelegate delegate,
  ) {
    return node?.toJsonMap(delegate);
  }

  List<Map<String, Object?>> _nodesToJson(
    List<DiagnosticsNode> nodes,
    InspectorSerializationDelegate delegate, {
    required DiagnosticsNode? parent,
  }) {
    return DiagnosticsNode.toJsonList(nodes, parent, delegate);
  }

  DiagnosticsNode? _idToDiagnosticsNode(String? diagnosticableId) {
    final Object? object = toObject(diagnosticableId);
    return WidgetInspectorService.objectToDiagnosticsNode(object);
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
      node.getProperties(),
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
                  // ignore: invalid_use_of_protected_member
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
