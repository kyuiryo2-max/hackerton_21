import 'package:flutter/material.dart';

import 'config/app_theme.dart';
import 'config/runtime_mode.dart';
import 'providers/todo_controller.dart';
import 'providers/schedule_controller.dart';
import 'screens/main_screen.dart';
import 'services/home_widget_bridge.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HomeWidgetBridge.init();
  // 홈 화면 위젯을 눌러 앱이 열렸다면 메모 화면으로 바로 이동해요.
  final launchTab = await HomeWidgetBridge.consumeLaunchTab();
  // 하단 입력줄을 눌러 열었다면 빠른 메모 화면도 바로 띄워요.
  final quickCapture = await HomeWidgetBridge.consumeQuickCapture();
  await RuntimeMode.instance.initialize(
    defaultDemo: const bool.fromEnvironment(
      'SYNC_RO_DEMO_MODE',
      defaultValue: true,
    ),
  );
  runApp(SyncRoApp(initialTab: launchTab ?? 0, openQuickCapture: quickCapture));
}

class SyncRoApp extends StatefulWidget {
  const SyncRoApp({
    super.key,
    this.initialTab = 0,
    this.openQuickCapture = false,
  });

  final int initialTab;
  final bool openQuickCapture;

  @override
  State<SyncRoApp> createState() => _SyncRoAppState();
}

class _SyncRoAppState extends State<SyncRoApp> {
  late TodoController _todoController;
  late ScheduleController _scheduleController;
  bool _switching = false;

  @override
  void initState() {
    super.initState();

    _todoController = TodoController();
    _scheduleController = ScheduleController();

    _todoController.initialize();
    _scheduleController.initialize();
    RuntimeMode.instance.addListener(_onModeChanged);
  }

  Future<void> _onModeChanged() async {
    if (_switching || !mounted) return;
    _switching = true;
    final oldTodos = _todoController;
    final oldSchedules = _scheduleController;
    final todos = TodoController();
    final schedules = ScheduleController();
    await Future.wait([todos.initialize(), schedules.initialize()]);
    if (!mounted) {
      todos.dispose();
      schedules.dispose();
    } else {
      setState(() {
        _todoController = todos;
        _scheduleController = schedules;
      });
      // Allow the old subtree to unmount before disposing its notifiers.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldTodos.dispose();
        oldSchedules.dispose();
      });
    }
    _switching = false;
  }

  @override
  void dispose() {
    RuntimeMode.instance.removeListener(_onModeChanged);
    _todoController.dispose();
    _scheduleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TodoScope(
      controller: _todoController,
      child: ScheduleScope(
        controller: _scheduleController,
        child: MaterialApp(
          title: 'Via',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          home: MainScreen(
            key: ValueKey(RuntimeMode.instance.storageNamespace),
            initialIndex: widget.initialTab,
            openQuickCapture: widget.openQuickCapture,
          ),
        ),
      ),
    );
  }
}
