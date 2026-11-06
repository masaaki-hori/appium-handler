import 'dart:convert';

import 'package:flutter/material.dart' hide InkWell, TextField;
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'package:appium_handler/appium_handler.dart';

// Stand-ins for the material_ui package's widgets (Flutter 3.47 split Material out of the SDK):
// same names as package:flutter/material.dart's, but different classes, so `is InkResponse` and
// `is TextField` don't match them.
class InkWell extends StatelessWidget {
  const InkWell({super.key, this.onTap, this.child});

  final VoidCallback? onTap;
  final Widget? child;

  @override
  Widget build(BuildContext context) => child ?? const SizedBox(width: 100, height: 40);
}

class TextField extends StatelessWidget {
  const TextField({super.key, this.decoration});

  final InputDecoration? decoration;

  @override
  Widget build(BuildContext context) => const SizedBox(width: 200, height: 40);
}

void main() {
  XmlElement nodeWithKey(String source, String type, String key) =>
      XmlDocument.parse(source).descendantElements.firstWhere((e) =>
          e.getAttribute('class') == type && (e.getAttribute('key') ?? '').contains(key));

  testWidgets('isMaterialWidget matches a same-named widget from another package', (tester) async {
    expect(isMaterialWidget(const InkWell(), 'InkWell'), isTrue);
    expect(isMaterialWidget(const TextField(), 'TextField'), isTrue);
    expect(isMaterialWidget(const SizedBox(), 'InkWell'), isFalse);
  });

  testWidgets('tapDirect calls onTap of an InkWell from another package', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: InkWell(
            key: const ValueKey('agree'),
            onTap: () => taps++,
            child: const Text('agree'),
          ),
        ),
      ),
    ));
    final handler = AppiumHandler()..buildDriverExtension();
    final source = await handler.appiumHandler('getPageSource');
    final id = nodeWithKey(source, 'InkWell', 'agree').getAttribute('id');
    final actions = [
      {
        'type': 'pointer',
        'id': 'finger1',
        'actions': [
          {'type': 'tapDirect', 'elementId': id},
        ],
      },
    ];
    final response = await tester.runAsync(
      () => handler
          .appiumHandler('performActions:${jsonEncode(actions)}')
          .timeout(const Duration(seconds: 10)),
    );

    expect(taps, 1);
    expect((jsonDecode(response!) as Map<String, dynamic>)['elementId'], id);
  });

  testWidgets('a TextField from another package gets its label and hint', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TextField(
          key: ValueKey('kana'),
          decoration: InputDecoration(labelText: 'セイ', hintText: 'テスト'),
        ),
      ),
    ));

    final source = await AppiumHandler().appiumHandler('getPageSource');
    final field = nodeWithKey(source, 'TextField', 'kana');
    expect(field.getAttribute('label'), 'セイ');
    expect(field.getAttribute('hint'), 'テスト');
  });
}
