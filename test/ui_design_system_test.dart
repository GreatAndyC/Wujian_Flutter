import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:icheck/app/theme/app_theme.dart';
import 'package:icheck/shared/widgets/app_ui.dart';
import 'package:icheck/shared/widgets/local_image_frame.dart';

void main() {
  testWidgets('status pill exposes a useful semantic label', (tester) async {
    final semanticsHandle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme(),
        home: const Scaffold(
          body: Center(
            child: AppStatusPill(
              label: '识别已连接',
              icon: Icons.cloud_done_outlined,
              tone: AppStatusTone.success,
            ),
          ),
        ),
      ),
    );

    expect(find.text('识别已连接'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.label == '识别已连接',
      ),
      findsOneWidget,
    );
    semanticsHandle.dispose();
  });

  testWidgets('content column stays readable on wide layouts', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme(),
        home: const Scaffold(
          body: AppContent(
            child: SizedBox(
              key: ValueKey('content-child'),
              width: 1200,
              height: 40,
            ),
          ),
        ),
      ),
    );

    final box = tester.renderObject<RenderBox>(
      find.byKey(const ValueKey('content-child')),
    );
    expect(box.size.width, lessThanOrEqualTo(840));
  });

  test('light and dark themes expose matching Material 3 brightness', () {
    expect(AppTheme.lightTheme().brightness, Brightness.light);
    expect(AppTheme.darkTheme().brightness, Brightness.dark);
  });

  testWidgets('local image frame handles unconstrained requested dimensions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme(),
        home: const SizedBox(
          width: 120,
          height: 120,
          child: LocalImageFrame(
            path: '/this-file-does-not-exist.jpg',
            width: double.infinity,
            height: double.infinity,
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
