import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_ro_app/config/runtime_mode.dart';
import 'package:sync_ro_app/providers/schedule_controller.dart';
import 'package:sync_ro_app/providers/todo_controller.dart';
import 'package:sync_ro_app/screens/main_screen.dart';
import 'package:sync_ro_app/screens/memo_screen.dart';

void main() {
  testWidgets('하단 탭은 3개이고 할 일·일정에서 위젯을 추가할 수 있어요', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    await RuntimeMode.instance.initialize(defaultDemo: true);

    final todos = TodoController();
    final schedules = ScheduleController();
    await Future.wait([todos.initialize(), schedules.initialize()]);

    await tester.pumpWidget(
      TodoScope(
        controller: todos,
        child: ScheduleScope(
          controller: schedules,
          child: const MaterialApp(home: MainScreen(initialIndex: 2)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final navigation = tester.widget<NavigationBar>(
      find.byType(NavigationBar),
    );
    final labels = navigation.destinations
        .cast<NavigationDestination>()
        .map((destination) => destination.label)
        .toList();
    expect(labels, ['홈', '이동', '할 일·일정']);
    for (final label in labels) {
      final center = tester.getCenter(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        ),
      );
      expect(center.dx, inInclusiveRange(0, 420));
    }
    expect(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('메모'),
      ),
      findsNothing,
    );

    final pinButton = find.byKey(const Key('planner-pin-widget'));
    expect(pinButton, findsOneWidget);
    expect(find.text('위젯 추가'), findsOneWidget);

    await tester.tap(pinButton);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    final snackTexts = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Text),
          ),
        )
        .map((text) => text.data)
        .whereType<String>()
        .toList();
    expect(
      snackTexts.join('\n'),
      anyOf(contains('확인 창에서'), contains('홈 화면을 길게')),
    );

    await tester.pumpWidget(const SizedBox());
    todos.dispose();
    schedules.dispose();
  });

  testWidgets('위젯의 메모 요청은 하단 탭이 아니라 별도 메모 화면으로 열려요', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await RuntimeMode.instance.initialize(defaultDemo: true);

    final todos = TodoController();
    final schedules = ScheduleController();
    await Future.wait([todos.initialize(), schedules.initialize()]);

    await tester.pumpWidget(
      TodoScope(
        controller: todos,
        child: ScheduleScope(
          controller: schedules,
          child: const MaterialApp(home: MainScreen(initialIndex: 3)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MemoScreen), findsOneWidget);
    // 메모는 하단 탭 위에 덮이는 별도 화면이라 하단 탭이 보이지 않아요.
    expect(find.byType(NavigationBar), findsNothing);

    await tester.pumpWidget(const SizedBox());
    todos.dispose();
    schedules.dispose();
  });
}
