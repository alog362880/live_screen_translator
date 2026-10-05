import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:screen_translate_app/main.dart';

void main() {
  testWidgets('App renders the home page with a translate FAB', (WidgetTester tester) async {
    await tester.pumpWidget(const ScreenTranslateApp());
    await tester.pump();

    expect(find.text('Screen Translate'), findsOneWidget);
    expect(find.byIcon(Icons.translate), findsOneWidget);
  });
}
