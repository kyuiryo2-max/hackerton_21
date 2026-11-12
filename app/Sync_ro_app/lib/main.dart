import 'package:flutter/material.dart';

import 'config/app_theme.dart';
import 'config/runtime_mode.dart';
import 'providers/todo_controller.dart';
import 'providers/schedule_controller.dart';
import 'screens/main_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RuntimeMode.instance.initialize(
    defaultDemo: const bool.fromEnvironment('SYNC_RO_DEMO_MODE', defaultValue: true),
  );
  runApp(const SyncRoApp());
}

class SyncRoApp extends StatefulWidget {
  const SyncRoApp({super.key});

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
          title: 'Sync_ro',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          home: MainScreen(key: ValueKey(RuntimeMode.instance.storageNamespace)),
        ),
      ),
    );
  }
}
