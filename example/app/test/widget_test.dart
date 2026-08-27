import 'package:e2e_example_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders home page with send button', (tester) async {
    await tester.pumpWidget(const E2EExampleApp());
    expect(find.byKey(const Key('send_ping_button')), findsOneWidget);
    expect(find.byKey(const Key('ping_list')), findsOneWidget);
    // Replace the app with an empty widget so PingPage disposes and its
    // polling timer cancels before the test ends.
    await tester.pumpWidget(const SizedBox());
  });
}
