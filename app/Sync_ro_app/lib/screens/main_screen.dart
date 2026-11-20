import '../config/app_theme.dart';
import '../config/runtime_mode.dart';
import '../data/demo_schedule.dart';
import '../providers/active_route_controller.dart';
import '../services/home_widget_bridge.dart';
import 'package:flutter/material.dart';
import 'home_screen.dart';
import '../models/memo.dart';
import '../models/todo_item.dart';
import '../models/schedule.dart';
import '../services/memo_classifier.dart';
import 'memo_screen.dart';
import 'memo_quick_capture_screen.dart';
import 'planner_screen.dart';
import '../models/place.dart';
import 'navigation_screen.dart';
import 'assistant_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({
    super.key,
    this.initialIndex = 0,
    this.openQuickCapture = false,
  });

  /// 위젯에서 앱을 열었을 때 처음 보여 줄 화면 (3 = 메모 화면).
  final int initialIndex;
  final bool openQuickCapture;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  late int _selectedIndex;
  bool _quickCaptureOpen = false;
  bool _memoOpen = false;

  late final PageController _pageController;

  late final List<Widget> _screens;
  final GlobalKey<MemoScreenState> _memoKey = GlobalKey<MemoScreenState>();
  final ValueNotifier<TodoItem?> _waypoint = ValueNotifier<TodoItem?>(null);
  final ValueNotifier<Schedule?> _requestedSchedule = ValueNotifier<Schedule?>(
    null,
  );
  final ValueNotifier<Place?> _requestedDestination = ValueNotifier<Place?>(
    null,
  );
  final ValueNotifier<int?> _requestedPlannerTab = ValueNotifier<int?>(null);

  @override
  void initState() {
    super.initState();
    final startsInMemo = widget.initialIndex >= 3;
    _selectedIndex = widget.initialIndex.clamp(0, 2).toInt();
    _pageController = PageController(initialPage: _selectedIndex);
    HomeWidgetBridge.init();
    HomeWidgetBridge.requestedTab.addListener(_onWidgetTabRequested);
    HomeWidgetBridge.quickCaptureRequested.addListener(
      _onQuickCaptureRequested,
    );
    if (HomeWidgetBridge.requestedTab.value != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _onWidgetTabRequested(),
      );
    }
    if (widget.openQuickCapture) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openQuickCapture());
    } else if (startsInMemo) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openMemo());
    } else if (HomeWidgetBridge.quickCaptureRequested.value > 0) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _onQuickCaptureRequested(),
      );
    }
    _screens = [
      HomeScreen(
        onOpenRoutes: _openRoutes,
        onSelectWaypoint: _selectWaypoint,
        onOpenScheduleRoutes: _openScheduleRoutes,
        onOpenTab: _onDestinationSelected,
        onOpenAssistant: _openAssistant,
        onChangeMode: _changeMode,
        onSearchDestination: _searchDestination,
      ),
      // 탭: 0 홈(경유 판단·추천) / 1 길찾기(경로 비교) / 2 할 일·일정(시간표)
      NavigationScreen(
        selectedWaypoint: _waypoint,
        requestedSchedule: _requestedSchedule,
        requestedDestination: _requestedDestination,
        onOpenAssistant: _openAssistant,
        onOpenPlanner: () => _onDestinationSelected(2),
      ),
      PlannerScreen(
        onOpenScheduleRoutes: _openScheduleRoutes,
        requestedTab: _requestedPlannerTab,
      ),
    ];
  }

  /// 홈 화면 위젯을 눌러 앱이 이미 떠 있을 때 (onNewIntent → MethodChannel)
  void _onWidgetTabRequested() {
    final tab = HomeWidgetBridge.requestedTab.value;
    if (tab == null || !mounted) return;
    if (tab >= 3) {
      _openMemo();
    } else {
      _onDestinationSelected(tab);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      HomeWidgetBridge.requestedTab.value = null;
    });
  }

  /// 앱이 이미 떠 있을 때 위젯 하단 입력줄을 누르면 빠른 메모를 열어요.
  void _onQuickCaptureRequested() {
    if (!mounted || HomeWidgetBridge.quickCaptureRequested.value == 0) {
      return;
    }
    HomeWidgetBridge.quickCaptureRequested.value = 0;
    _openQuickCapture();
  }

  Future<void> _openQuickCapture() async {
    if (_quickCaptureOpen || !mounted) return;
    _quickCaptureOpen = true;
    final result = await Navigator.of(context).push<MemoClassification>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const MemoQuickCaptureScreen(),
      ),
    );
    _quickCaptureOpen = false;
    if (!mounted || result == null) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${result.reason} 메모에 저장했어요. 메모 화면에서 ${result.type.label} 탭으로 보낼 수 있어요.',
        ),
      ),
    );
    await _openMemo();
  }

  /// 메모는 하단 탭이 아니라 홈 화면 위젯에서만 여는 별도 화면이에요.
  Future<void> _openMemo() async {
    if (!mounted) return;
    if (_memoOpen) {
      _memoKey.currentState?.reload();
      return;
    }
    _memoOpen = true;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            MemoScreen(key: _memoKey, onPromoted: _onMemoPromoted),
      ),
    );
    _memoOpen = false;
  }

  void _onMemoPromoted(MemoType type) {
    if (_memoOpen) {
      _memoOpen = false;
      Navigator.of(context).maybePop();
    }
    _openPlannerTab(type == MemoType.schedule ? 0 : 1);
  }

  /// 플래너의 '일정'(0) 또는 '할 일'(1) 서브 탭을 열어요.
  void _openPlannerTab(int tab) {
    _requestedPlannerTab.value = null;
    _requestedPlannerTab.value = tab;
    _onDestinationSelected(2);
  }

  Future<void> _changeMode() async {
    final wasDemo = RuntimeMode.instance.isDemo;
    final nextDemo = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('앱 사용 모드'),
        content: Text(
          wasDemo
              ? '실제 모드로 전환할까요? 이 기기의 전용 ID로 데이터가 분리됩니다. 서버 API가 아직 일부 기능을 지원하지 않을 수 있습니다.'
              : '시연 모드로 전환할까요? 기존 시연 데이터가 표시됩니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, !wasDemo),
            child: const Text('전환'),
          ),
        ],
      ),
    );
    if (nextDemo == null || !mounted) return;
    try {
      activeRouteController.clearSearch();
      await RuntimeMode.instance.changeMode(nextDemo);
      activeRouteController.requestPlanRefresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('모드 전환 실패: $error')));
      }
    }
  }

  void _openRoutes() => _onDestinationSelected(1);

  /// 홈 검색창: 일정 없이 목적지만으로 이동 탭에서 경로를 찾아요.
  void _searchDestination(Place place) {
    _requestedDestination.value = null;
    _requestedDestination.value = place;
    _onDestinationSelected(1);
  }

  void _openAssistant([String? question]) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => AssistantScreen(
              initialQuestion: question,
              // AI 답변의 버튼: 질문 화면을 닫고 그 화면으로 이동해요 (11/14)
              onNavigate: ({int? tab, Place? destination}) {
                Navigator.of(context).popUntil((route) => route.isFirst);
                if (destination != null) {
                  _searchDestination(destination);
                } else if (tab != null) {
                  _onDestinationSelected(tab);
                }
              },
            )),
      );

  void _openScheduleRoutes(Schedule schedule) {
    // 시연 일정은 일정 목록에 없는 표시용이라, 이동 탭의 시연 계획(서울역 → 고려대학교)을 그대로 보여 줘요 (11/21)
    if (DemoSchedule.isDemo(schedule)) {
      _onDestinationSelected(1);
      return;
    }
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
    // 3번은 더 이상 하단 탭이 아니에요. 위젯·AI 안내에서는 메모 화면으로 열어요.
    if (index >= 3) {
      _openMemo();
      return;
    }
    final target = index.clamp(0, _screens.length - 1).toInt();
    setState(() {
      _selectedIndex = target;
    });

    if (_pageController.hasClients) {
      _pageController.animateToPage(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  // 화면을 좌우로 스와이프했을 때
  void _onPageChanged(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  void dispose() {
    HomeWidgetBridge.requestedTab.removeListener(_onWidgetTabRequested);
    HomeWidgetBridge.quickCaptureRequested.removeListener(
      _onQuickCaptureRequested,
    );
    _pageController.dispose();
    _waypoint.dispose();
    _requestedSchedule.dispose();
    _requestedDestination.dispose();
    _requestedPlannerTab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // 맨 위 앱 로고 (11/16)
          Container(
            width: double.infinity,
            color: Colors.white,
            child: SafeArea(
              bottom: false,
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                alignment: Alignment.centerLeft,
                child: Image.asset('assets/branding/via_logo.png', height: 32, semanticLabel: 'Via'),
              ),
            ),
          ),
          Expanded(
            // 로고 줄이 상태 표시줄 자리를 썼으니 아래 화면들은 위쪽 여백을 다시 넣지 않아요.
            // Builder로 Scaffold 안쪽 MediaQuery를 써야 키보드 높이가 두 번 빠지지 않아요
            // (11/16: 입력할 때 화면이 거의 다 가려지던 문제)
            child: Builder(builder: (inner) => MediaQuery.removePadding(
              context: inner,
              removeTop: true,
              child: Stack(
                children: [
                  PageView(
                    // 지도를 끌 때 탭이 넘어가지 않게 좌우 넘김은 끄고 하단 탭으로만 이동해요
                    physics: const NeverScrollableScrollPhysics(),
                    controller: _pageController,
                    onPageChanged: _onPageChanged,
                    children: _screens,
                  ),
                  // 떠 있는 "AI 질문" 버튼은 뺐어요. AI 질문은 이동 중 지도 팝업에서만 해요 (#51 피드백 4, 11/14)
                ],
              ),
            )),
          ),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppTheme.border)),
            ),
            child: MediaQuery.removePadding(
              context: context,
              removeBottom: true,
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
                    label: '이동',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.calendar_month_outlined),
                    selectedIcon: Icon(Icons.calendar_month),
                    label: '할 일·일정',
                  ),
                ],
              ),
            ),
          ),
          // 맨 아래 아주 작게 팀 로고 (11/16)
          Container(
            width: double.infinity,
            color: Theme.of(context).navigationBarTheme.backgroundColor ??
                Theme.of(context).colorScheme.surfaceContainer,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Opacity(
                  opacity: 0.45,
                  child: Image.asset(
                    'assets/branding/team_logo.png',
                    height: 12,
                    semanticLabel: '팀 Sync-ro',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
