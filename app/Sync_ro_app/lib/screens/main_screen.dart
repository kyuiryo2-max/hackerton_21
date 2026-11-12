import '../config/app_theme.dart';
import '../config/runtime_mode.dart';
import '../providers/active_route_controller.dart';
import 'package:flutter/material.dart';
import 'home_screen.dart';
import '../models/todo_item.dart';
import '../models/schedule.dart';
import 'planner_screen.dart';
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
    HomeScreen(
      onOpenRoutes: _openRoutes,
      onSelectWaypoint: _selectWaypoint,
      onOpenScheduleRoutes: _openScheduleRoutes,
      onOpenTab: _onDestinationSelected,
      onOpenAssistant: _openAssistant,
      onChangeMode: _changeMode,
    ),
    // 탭: 0 홈(경유 판단·추천) / 1 길찾기(경로 비교) / 2 할 일·일정(시간표)
    NavigationScreen(selectedWaypoint: _waypoint, requestedSchedule: _requestedSchedule),
    PlannerScreen(onOpenScheduleRoutes: _openScheduleRoutes),
    ];
  }

  Future<void> _changeMode() async {
    final wasDemo = RuntimeMode.instance.isDemo;
    final nextDemo = await showDialog<bool>(context: context, builder: (dialogContext) =>
      AlertDialog(
        title: const Text('앱 사용 모드'),
        content: Text(wasDemo
          ? '실제 모드로 전환할까요? 이 기기의 전용 ID로 데이터가 분리됩니다. 서버 API가 아직 일부 기능을 지원하지 않을 수 있습니다.'
          : '시연 모드로 전환할까요? 기존 시연 데이터가 표시됩니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, !wasDemo), child: const Text('전환')),
        ],
      ));
    if (nextDemo == null || !mounted) return;
    try {
      activeRouteController.clearSearch();
      await RuntimeMode.instance.changeMode(nextDemo);
      activeRouteController.requestPlanRefresh();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('모드 전환 실패: $error')));
    }
  }

  void _openRoutes() => _onDestinationSelected(1);

  void _openAssistant([String? question]) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => AssistantScreen(initialQuestion: question)),
      );

  void _openScheduleRoutes(Schedule schedule) {
    // Force a refresh even when the same schedule is selected twice.
    _requestedSchedule.value = null;
    _requestedSchedule.value = schedule;
    _onDestinationSelected(1);
  }

  void _selectWaypoint(TodoItem todo) {
    _waypoint.value = todo;
    _onDestinationSelected(1);
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
              final position = _aiButtonPosition ?? Offset(maxX - 8, maxY - 84);
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
                        elevation: 6,
                        shadowColor: AppTheme.primary.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(24),
                        color: AppTheme.primary,
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
                          onTap: _openAssistant,
                          child: const SizedBox(
                            width: buttonWidth,
                            height: buttonHeight,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.auto_awesome, size: 18, color: Colors.white),
                                SizedBox(width: 6),
                                Text('AI 질문', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
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
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppTheme.border)),
        ),
        child: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: _onDestinationSelected,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '홈',
          ),
          NavigationDestination(
            icon: Icon(Icons.alt_route_outlined),
            selectedIcon: Icon(Icons.alt_route),
            label: '길찾기',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: '할 일·일정',
          ),
        ],
      ),
      ),
    );
  }
}
