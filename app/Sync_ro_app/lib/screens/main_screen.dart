import 'package:flutter/material.dart';
import 'home_screen.dart';
import '../models/todo_item.dart';
import '../models/schedule.dart';
import 'schedule_screen.dart';
import 'todo_screen.dart';
import 'navigation_screen.dart';
import 'assistant_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;
  Offset? _aiButtonPosition;

  final PageController _pageController = PageController();

  late final List<Widget> _screens;
  final ValueNotifier<TodoItem?> _waypoint = ValueNotifier<TodoItem?>(null);
  final ValueNotifier<Schedule?> _requestedSchedule = ValueNotifier<Schedule?>(null);

  @override
  void initState() {
    super.initState();
    _screens = [
    HomeScreen(onOpenRoutes: _openRoutes, onSelectWaypoint: _selectWaypoint, onOpenScheduleRoutes: _openScheduleRoutes),
    ScheduleScreen(onOpenScheduleRoutes: _openScheduleRoutes),
    const TodoScreen(),
    NavigationScreen(selectedWaypoint: _waypoint, requestedSchedule: _requestedSchedule),
    ];
  }

  void _openRoutes() => _onDestinationSelected(3);

  void _openScheduleRoutes(Schedule schedule) {
    // Force a refresh even when the same schedule is selected twice.
    _requestedSchedule.value = null;
    _requestedSchedule.value = schedule;
    _onDestinationSelected(3);
  }

  void _selectWaypoint(TodoItem todo) {
    _waypoint.value = todo;
    _onDestinationSelected(3);
  }

  // 하단 네비게이션 버튼 클릭 시
  void _onDestinationSelected(int index) {
    setState(() {
      _selectedIndex = index;
    });

    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  // 화면을 좌우로 스와이프했을 때
  void _onPageChanged(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _waypoint.dispose();
    _requestedSchedule.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          PageView(
            controller: _pageController,
            onPageChanged: _onPageChanged,
            children: _screens,
          ),
          // AI button is draggable within the visible content area.
          LayoutBuilder(
            builder: (context, constraints) {
              const buttonWidth = 112.0;
              const buttonHeight = 44.0;
              const margin = 8.0;
              final maxX = (constraints.maxWidth - buttonWidth - margin)
                  .clamp(0.0, double.infinity).toDouble();
              final maxY = (constraints.maxHeight - buttonHeight - margin)
                  .clamp(0.0, double.infinity).toDouble();
              final position = _aiButtonPosition ?? Offset(maxX, margin);
              final left = position.dx.clamp(0.0, maxX).toDouble();
              final top = position.dy.clamp(0.0, maxY).toDouble();
              return Stack(
                children: [
                  Positioned(
                    left: left,
                    top: top,
                    child: SafeArea(
                      top: false,
                      bottom: false,
                      child: Material(
                        elevation: 3,
                        borderRadius: BorderRadius.circular(24),
                        color: Theme.of(context).colorScheme.primaryContainer,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanUpdate: (details) {
                            setState(() {
                              _aiButtonPosition = Offset(
                                (left + details.delta.dx).clamp(0.0, maxX).toDouble(),
                                (top + details.delta.dy).clamp(0.0, maxY).toDouble(),
                              );
                            });
                          },
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const AssistantScreen()),
                          ),
                          child: const SizedBox(
                            width: buttonWidth,
                            height: buttonHeight,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.auto_awesome, size: 18),
                                SizedBox(width: 6),
                                Text('AI 질문'),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: _onDestinationSelected,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '홈',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_today_outlined),
            selectedIcon: Icon(Icons.calendar_today),
            label: '일정',
          ),
          NavigationDestination(
            icon: Icon(Icons.checklist_outlined),
            selectedIcon: Icon(Icons.checklist),
            label: '할 일',
          ),
          NavigationDestination(
            icon: Icon(Icons.route_outlined),
            selectedIcon: Icon(Icons.route),
            label: '이동',
          ),
        ],
      ),
    );
  }
}
