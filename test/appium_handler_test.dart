import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'package:appium_handler/appium_handler.dart';

void main() {
  testWidgets('unknown command returns an empty JSON object', (tester) async {
    final handler = AppiumHandler();
    expect(await handler.appiumHandler('notACommand'), jsonEncode({}));
  });

  testWidgets('getScreenSize returns the current view size', (tester) async {
    final handler = AppiumHandler();
    final response = await handler.appiumHandler('getScreenSize');
    final decoded = jsonDecode(response) as Map<String, dynamic>;
    expect(decoded['width'], isA<int>());
    expect(decoded['height'], isA<int>());
  });

  group('getPageSource exposes input decoration texts on text fields', () {
    XmlElement fieldWithKey(String source, String key) => XmlDocument.parse(source)
        .descendantElements
        .firstWhere((e) => e.getAttribute('class') == 'TextFormField' &&
            (e.getAttribute('key') ?? '').contains(key));

    testWidgets('labelText and hintText are output as label/hint, and survive text entry',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            TextFormField(
              key: const ValueKey('label-only'),
              decoration: const InputDecoration(labelText: '姓'),
            ),
            TextFormField(
              key: const ValueKey('hint-only'),
              decoration: const InputDecoration(hintText: '名'),
            ),
            TextFormField(
              key: const ValueKey('both'),
              decoration: const InputDecoration(labelText: '郵便番号', hintText: '1000001'),
            ),
            TextFormField(key: const ValueKey('none')),
          ]),
        ),
      ));

      Future<void> expectAttributes() async {
        final source = await AppiumHandler().appiumHandler('getPageSource');
        expect(fieldWithKey(source, 'label-only').getAttribute('label'), '姓');
        expect(fieldWithKey(source, 'label-only').getAttribute('hint'), '');
        expect(fieldWithKey(source, 'hint-only').getAttribute('label'), '');
        expect(fieldWithKey(source, 'hint-only').getAttribute('hint'), '名');
        expect(fieldWithKey(source, 'both').getAttribute('label'), '郵便番号');
        expect(fieldWithKey(source, 'both').getAttribute('hint'), '1000001');
        expect(fieldWithKey(source, 'none').getAttribute('label'), '');
        expect(fieldWithKey(source, 'none').getAttribute('hint'), '');
      }

      await expectAttributes();
      // hintText disappears from the screen once text is entered, but the attribute (read from
      // the widget's configuration, not from rendered text) must stay.
      await tester.enterText(find.byKey(const ValueKey('hint-only')), '入力済み');
      await tester.enterText(find.byKey(const ValueKey('label-only')), '品質');
      await tester.pump();
      await expectAttributes();
    });
  });

  group('byFieldLabel locator', () {
    Widget fields({bool duplicateLabel = false}) => MaterialApp(
          home: Scaffold(
            body: Column(children: [
              const TextField(decoration: InputDecoration(labelText: '電話番号')),
              TextFormField(decoration: const InputDecoration(labelText: '姓')),
              TextFormField(decoration: const InputDecoration(hintText: '名')),
              TextFormField(
                decoration: InputDecoration(labelText: duplicateLabel ? '姓' : 'セイ'),
              ),
            ]),
          ),
        );

    Map<String, dynamic> actionResult(String response) =>
        jsonDecode(response) as Map<String, dynamic>;

    Future<Map<String, dynamic>> checkExistence(
      WidgetTester tester,
      AppiumHandler handler, {
      String? foundBy,
      String? value,
      Offset? at,
    }) async {
      await handler.appiumHandler('getPageSource');
      final actions = [
        {
          'type': 'pointer',
          'id': 'finger1',
          'actions': [
            if (at != null) {'type': 'pointerMove', 'x': at.dx.toInt(), 'y': at.dy.toInt()},
            {
              'type': 'checkExistence',
              if (foundBy != null) 'foundBy': foundBy,
              if (value != null) 'value': value,
            },
          ],
        },
      ];
      final response = await tester.runAsync(
        () => handler
            .appiumHandler('performActions:${jsonEncode(actions)}')
            .timeout(const Duration(seconds: 10)),
      );
      return actionResult(response!);
    }

    testWidgets('a uniquely labeled field is recorded by its label, not Type#N', (tester) async {
      await tester.pumpWidget(fields());
      final handler = AppiumHandler()..buildDriverExtension();

      final byLabel = await checkExistence(
        tester,
        handler,
        at: tester.getCenter(find.byType(TextFormField).at(0)),
      );
      expect(byLabel['foundBy'], 'byFieldLabel');
      expect(byLabel['value'], 'TextFormField|姓');

      final byHint = await checkExistence(
        tester,
        handler,
        at: tester.getCenter(find.byType(TextFormField).at(1)),
      );
      expect(byHint['foundBy'], 'byFieldLabel');
      expect(byHint['value'], 'TextFormField|名');

      final textField = await checkExistence(
        tester,
        handler,
        at: tester.getCenter(find.byType(TextField).first),
      );
      expect(textField['value'], 'TextField|電話番号');
    });

    testWidgets('a recorded byFieldLabel locator resolves back to that field', (tester) async {
      await tester.pumpWidget(fields());
      final handler = AppiumHandler()..buildDriverExtension();

      final replay = await checkExistence(
        tester,
        handler,
        foundBy: 'byFieldLabel',
        value: 'TextFormField|名',
      );
      expect(replay['foundBy'], 'byFieldLabel');
      expect(replay['value'], 'TextFormField|名');

      final missing = await checkExistence(
        tester,
        handler,
        foundBy: 'byFieldLabel',
        value: 'TextFormField|存在しない',
      );
      expect(missing, isEmpty);
    });

    testWidgets('an ambiguous label falls back to Type#N', (tester) async {
      await tester.pumpWidget(fields(duplicateLabel: true));
      final handler = AppiumHandler()..buildDriverExtension();

      final result = await checkExistence(
        tester,
        handler,
        at: tester.getCenter(find.byType(TextFormField).at(0)),
      );
      expect(result['foundBy'], 'byType');
      expect(result['value'], 'TextFormField#0');
    });
  });

  group('live type index and tap-target text', () {
    Future<Map<String, dynamic>> performAction(
      WidgetTester tester,
      AppiumHandler handler,
      Map<String, dynamic> action, {
      Offset? at,
    }) async {
      await handler.appiumHandler('getPageSource');
      final actions = [
        {
          'type': 'pointer',
          'id': 'finger1',
          'actions': [
            if (at != null) {'type': 'pointerMove', 'x': at.dx.toInt(), 'y': at.dy.toInt()},
            action,
          ],
        },
      ];
      final response = await tester.runAsync(
        () => handler
            .appiumHandler('performActions:${jsonEncode(actions)}')
            .timeout(const Duration(seconds: 10)),
      );
      return jsonDecode(response!) as Map<String, dynamic>;
    }

    testWidgets('typeIndex counts framework-created widgets the way ByTypeIndexFinder does',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            // ListTile creates its own InkWell inside the framework - left out of the (Debug)
            // summary-tree page source, but counted by find.byType(InkWell).
            ListTile(title: const Text('framework inkwell'), onTap: () {}),
            InkWell(key: const ValueKey('mine'), onTap: () {}, child: const Text('app inkwell')),
          ]),
        ),
      ));

      final source = await AppiumHandler().appiumHandler('getPageSource');
      final mine = XmlDocument.parse(source).descendantElements.firstWhere((e) =>
          e.getAttribute('class') == 'InkWell' && (e.getAttribute('key') ?? '').contains('mine'));
      final index = int.parse(mine.getAttribute('typeIndex')!);
      expect(
        (tester.widget(find.byType(InkWell).at(index)).key! as ValueKey<String>).value,
        'mine',
      );
      expect(index, greaterThan(0));
    });

    // useMaterial3: false like the app under test itself - Material 3's InkSparkle splash loads a shader
    // asset that fails to decode when the test build cache was produced by a different SDK.
    Widget bottomNavApp(void Function(int) onTap) => MaterialApp(
          theme: ThemeData(useMaterial3: false),
          home: Scaffold(
            body: const SizedBox.expand(),
            bottomNavigationBar: BottomNavigationBar(
              onTap: onTap,
              items: const [
                BottomNavigationBarItem(icon: Icon(Icons.home), label: 'ホーム'),
                BottomNavigationBarItem(icon: Icon(Icons.person), label: 'アカウント'),
              ],
            ),
          ),
        );

    testWidgets('an icon with no identity of its own is recorded by its tap target label',
        (tester) async {
      await tester.pumpWidget(bottomNavApp((_) {}));
      final handler = AppiumHandler()..buildDriverExtension();

      final recorded = await performAction(
        tester,
        handler,
        {'type': 'checkExistence'},
        at: tester.getCenter(find.byIcon(Icons.person)),
      );
      expect(recorded['foundBy'], 'byText');
      expect(recorded['value'], 'アカウント');
    });

    testWidgets('a recorded tap-target label not in the page source still replays', (tester) async {
      var tapped = -1;
      await tester.pumpWidget(bottomNavApp((index) => tapped = index));
      final handler = AppiumHandler()..buildDriverExtension();

      final exists = await performAction(
        tester,
        handler,
        {'type': 'checkExistence', 'foundBy': 'byText', 'value': 'アカウント'},
      );
      expect(exists['foundBy'], 'byText');

      final tap = await performAction(
        tester,
        handler,
        {'type': 'tap', 'foundBy': 'byText', 'value': 'アカウント'},
      );
      await tester.pump();
      expect(tap['foundBy'], 'byText');
      expect(tapped, 1);
    });

    testWidgets('typeIndex in a lazily built list matches the finder; off-screen items have none',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          // Default cache extent: items just outside the viewport are built (so they're in the
          // element tree and the page source) but not visible to the finder (skipOffstage).
          body: ListView(
            children: [
              for (var i = 0; i < 30; i++)
                SizedBox(
                  height: 80,
                  child: TextFormField(key: ValueKey('field-$i')),
                ),
            ],
          ),
        ),
      ));
      // Scroll a bit so the first visible field isn't field-0 either (items scrolled past the top
      // are also off-screen to the finder).
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();

      final source = await AppiumHandler().appiumHandler('getPageSource');
      final fields = XmlDocument.parse(source)
          .descendantElements
          .where((e) => e.getAttribute('class') == 'TextFormField')
          .toList();
      final visibleCount = find.byType(TextFormField).evaluate().length;
      final indexed = fields.where((e) => (e.getAttribute('typeIndex') ?? '').isNotEmpty).toList();

      expect(indexed, hasLength(visibleCount));
      // The page source still has fields the finder doesn't see (scrolled past / not yet visible),
      // otherwise this test wouldn't cover the off-screen case below at all.
      expect(fields.length, greaterThan(visibleCount));
      for (final field in indexed) {
        final n = int.parse(field.getAttribute('typeIndex')!);
        final key = (tester.widget(find.byType(TextFormField).at(n)).key! as ValueKey<String>).value;
        expect(field.getAttribute('key'), contains(key));
      }
      // Any field still in the page source but not visible to the finder carries no typeIndex.
      for (final field in fields.where((e) => !indexed.contains(e))) {
        expect(field.getAttribute('typeIndex'), '');
      }
    });

    testWidgets('pruning keeps identifying nodes and the types callers search for', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          // Structural wrappers with the same bounds as their only child, and a zero-size leaf -
          // what a Profile/Release full tree is full of (under `flutter test` the summary tree only
          // shows widgets created in this file, so they're spelled out here).
          body: Column(children: [
            Semantics(child: const Text('hello')),
            const RepaintBoundary(child: Icon(Icons.person)),
            InkWell(onTap: () {}, child: const SizedBox(width: 40, height: 40)),
            const SizedBox.shrink(),
            TextFormField(decoration: const InputDecoration(labelText: '姓')),
          ]),
        ),
      ));

      final full = await (AppiumHandler()..debugForcePruneWrappers = false)
          .appiumHandler('getPageSource');
      final pruned = await (AppiumHandler()..debugForcePruneWrappers = true)
          .appiumHandler('getPageSource');
      final fullDoc = XmlDocument.parse(full);
      final prunedDoc = XmlDocument.parse(pruned);

      int count(XmlDocument doc, String type) =>
          doc.descendantElements.where((e) => e.getAttribute('class') == type).length;
      for (final type in ['Text', 'Icon', 'InkWell', 'TextFormField']) {
        expect(count(prunedDoc, type), count(fullDoc, type), reason: type);
      }
      expect(pruned, contains('hello'));
      expect(count(fullDoc, 'Semantics'), greaterThan(0));
      expect(count(prunedDoc, 'Semantics'), 0);
      expect(count(prunedDoc, 'RepaintBoundary'), 0);
      expect(int.parse(prunedDoc.rootElement.getAttribute('collapsedNodes')!), greaterThanOrEqualTo(3));
      expect(fullDoc.rootElement.getAttribute('collapsedNodes'), '0');
    });
  });

  group('getPageSource excludes screens hidden from finders', () {
    List<XmlElement> nodesOfClass(String source, String type) => XmlDocument.parse(source)
        .descendantElements
        .where((e) => e.getAttribute('class') == type)
        .toList();

    testWidgets('a route covered by a pushed route is not included', (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: Column(children: [
            const Text('first screen'),
            TextFormField(key: const ValueKey('first-field')),
          ]),
        ),
      ));
      navigatorKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: Column(children: [
            const Text('second screen'),
            TextFormField(key: const ValueKey('second-a')),
            TextFormField(key: const ValueKey('second-b')),
          ]),
        ),
      ));
      await tester.pumpAndSettle();

      final source = await AppiumHandler().appiumHandler('getPageSource');

      expect(source, contains('second screen'));
      expect(source, isNot(contains('first screen')));
      expect(source, isNot(contains('first-field')));

      // The page source's same-type order must line up with what `ByTypeIndexFinder`
      // (`find.byElementPredicate(...).at(N)`, skipOffstage by default) resolves.
      final fields = nodesOfClass(source, 'TextFormField');
      expect(fields, hasLength(find.byType(TextFormField).evaluate().length));
      for (var i = 0; i < fields.length; i++) {
        final key = (tester.widget(find.byType(TextFormField).at(i)).key! as ValueKey<String>).value;
        expect(fields[i].getAttribute('key'), contains(key));
      }
    });

    // Mirrors the app under test's setup, where on-device dumps still contained every previous route at
    // x = -width/3 (the Cupertino transition's parallax end position): Cupertino transitions on
    // Android too, a `MaterialApp.builder` Stack, a home pushed via `PageRouteBuilder`, two
    // `MaterialPageRoute` pushes on top, and a non-opaque `OverlayEntry` (like a coach mark).
    testWidgets('the app under test-like navigation: previous routes are not included', (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigatorKey,
        // the app under test sets `CupertinoPageTransitionsBuilder` for every platform; the iOS platform's
        // default transitions are the same, without naming a class whose exporting library
        // differs between Flutter 3.38 (material) and 3.44 (cupertino).
        theme: ThemeData(useMaterial3: false, platform: TargetPlatform.iOS),
        builder: (context, child) => Stack(children: [child!]),
        home: const Scaffold(body: Text('boot screen')),
      ));
      navigatorKey.currentState!.pushAndRemoveUntil(
        PageRouteBuilder<void>(
          pageBuilder: (_, __, ___) => const Scaffold(body: Text('home screen')),
        ),
        (_) => false,
      );
      await tester.pumpAndSettle();
      navigatorKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('payment method screen')),
      ));
      await tester.pumpAndSettle();
      navigatorKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('credit card input screen')),
      ));
      await tester.pumpAndSettle();
      navigatorKey.currentState!.overlay!.insert(
        OverlayEntry(builder: (_) => const Positioned(top: 0, child: Text('coach mark'))),
      );
      await tester.pump();

      final source = await AppiumHandler().appiumHandler('getPageSource');

      expect(source, contains('credit card input screen'));
      expect(source, contains('coach mark'));
      expect(source, isNot(contains('payment method screen')));
      expect(source, isNot(contains('home screen')));

      // The diagnostics on <tree> let an on-device XML dump show whether filtering ran.
      final root = XmlDocument.parse(source).rootElement;
      expect(root.getAttribute('offstageFilter'), 'ok');
      expect(int.parse(root.getAttribute('hiddenElements')!), greaterThan(0));
      expect(int.parse(root.getAttribute('skippedNodes')!), greaterThan(0));
    });

    testWidgets('unselected IndexedStack children are not included', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: IndexedStack(
            index: 1,
            children: [Text('tab A'), Text('tab B')],
          ),
        ),
      ));

      final source = await AppiumHandler().appiumHandler('getPageSource');

      expect(source, contains('tab B'));
      expect(source, isNot(contains('tab A')));
    });

    testWidgets('Offstage(offstage: true) children are not included', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Column(children: [
            Offstage(child: Text('hidden text')),
            Offstage(offstage: false, child: Text('shown text')),
          ]),
        ),
      ));

      final source = await AppiumHandler().appiumHandler('getPageSource');

      expect(source, contains('shown text'));
      expect(source, isNot(contains('hidden text')));
    });
  });
}
