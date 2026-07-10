import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

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
}
