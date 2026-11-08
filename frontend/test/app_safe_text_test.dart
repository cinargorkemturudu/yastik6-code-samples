import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yastik_alti/ui/utils/app_safe_text.dart';

void main() {
  group('AppSafeText', () {
    testWidgets('renders the given text', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(children: const [AppSafeText('Gram Altın')]),
          ),
        ),
      );

      expect(find.text('Gram Altın'), findsOneWidget);
    });

    testWidgets('applies ellipsis overflow and the given maxLines', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: const [
                AppSafeText('Very Long Asset Name', maxLines: 2),
              ],
            ),
          ),
        ),
      );

      final textWidget = tester.widget<Text>(find.text('Very Long Asset Name'));
      expect(textWidget.maxLines, 2);
      expect(textWidget.overflow, TextOverflow.ellipsis);
    });

    testWidgets('wraps in Flexible by default (for use inside Row/Column)', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(children: const [AppSafeText('Gram Altın')]),
          ),
        ),
      );

      expect(
        find.ancestor(
          of: find.text('Gram Altın'),
          matching: find.byType(Flexible),
        ),
        findsOneWidget,
      );
    });

    testWidgets('does not wrap in Flexible when flex is false', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(children: const [AppSafeText('Gram Altın', flex: false)]),
          ),
        ),
      );

      expect(
        find.ancestor(
          of: find.text('Gram Altın'),
          matching: find.byType(Flexible),
        ),
        findsNothing,
      );
    });
  });
}
