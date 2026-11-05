
import 'package:flutter/material.dart';

import 'providers/todo_controller.dart';
import 'providers/schedule_controller.dart';
import 'screens/main_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SyncRoApp());
}

class SyncRoApp extends StatefulWidget {
  const SyncRoApp({super.key});

  @override
  State<SyncRoApp> createState() => _SyncRoAppState();
}

class _SyncRoAppState extends State<SyncRoApp> {
  late final TodoController _todoController;
  late final ScheduleController _scheduleController;

  @override
  void initState() {
    super.initState();

    _todoController = TodoController();
    _scheduleController = ScheduleController();

    _todoController.initialize();
    _scheduleController.initialize();
  }

  @override
  void dispose() {
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
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF4936D8),
            ),
            useMaterial3: true,
          ),
          home: const MainScreen(),
        ),
      ),
    );
  }
}
