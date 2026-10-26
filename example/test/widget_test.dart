import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:cookoo_video_export_example/main.dart';

void main() {
  testWidgets('example offers a real export', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Example()));
    expect(find.text('Export sample'), findsOneWidget);
  });
}
