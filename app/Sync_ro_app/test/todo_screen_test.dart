import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_ro_app/config/runtime_mode.dart';
import 'package:sync_ro_app/providers/todo_controller.dart';
import 'package:sync_ro_app/screens/todo_screen.dart';

void main() {
  testWidgets('장소 종류가 있는 할 일은 미분류가 아니라 경유지 추천 후보로 보여요', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await RuntimeMode.instance.initialize(defaultDemo: true);

    final controller = TodoController();
    await controller.initialize();
    final added = await controller.addTodo(
      title: '약 사기',
      minutes: 5,
      requiresTravel: false,
    );
    await controller.updateTodo(added.copyWith(placeTypes: const ['약국']));
    final updated = controller.todos.firstWhere((todo) => todo.id == added.id);
    expect(updated.requiresTravel, isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: TodoScope(controller: controller, child: const TodoScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final tile = find.ancestor(
      of: find.text('약 사기'),
      matching: find.byType(ListTile),
    );
    expect(tile, findsOneWidget);
    expect(
      find.descendant(of: tile, matching: find.textContaining('경유지 추천 후보')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile, matching: find.textContaining('미분류')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
