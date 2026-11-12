import 'active_route_controller.dart';
import '../config/runtime_mode.dart';
import '../services/real_data_service.dart';
import 'package:flutter/material.dart';

import '../models/schedule.dart';
import '../services/schedule_storage_service.dart';

class ScheduleController extends ChangeNotifier {
  final _storage = ScheduleStorageService();
  final _remote = RealDataService();

  List<Schedule> _schedules = [];
  bool _isLoading = true;
  String? _error;

  List<Schedule> get schedules => List.unmodifiable(_schedules);

  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> initialize() async {
    try {
      final local = await _storage.load() ?? <Schedule>[];
      _schedules = RuntimeMode.instance.isDemo
          ? local : await _remote.loadSchedules(previous: local);
      _sort();
      _error = null;
    } catch (e) {
      _error = '일정 불러오기 실패: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void _sort() {
    _schedules.sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  Future<void> _save() async {
    notifyListeners();
    try {
      await _storage.save(_schedules);
      _error = null;
    } catch (e) {
      _error = '일정 저장 실패: $e';
    }
    notifyListeners();
  }

  Future<Schedule> addSchedule({
    required String title,
    required String location,
    String? destinationPlaceId,
    String? destinationAddress,
    double? destinationLatitude,
    double? destinationLongitude,
    String originMode = 'current',
    String? originPlaceId,
    String? originName,
    String? originAddress,
    double? originLatitude,
    double? originLongitude,
    required DateTime startTime,
    required DateTime endTime,
    int preparationMinutes = 30,
  }) async {
    final nextId = _schedules.isEmpty
        ? 1
        : _schedules.map((e) => e.id).reduce((a, b) => a > b ? a : b) + 1;

    final added = Schedule(
        id: nextId,
        title: title,
        location: location,
        destinationPlaceId: destinationPlaceId,
        destinationAddress: destinationAddress,
        destinationLatitude: destinationLatitude,
        destinationLongitude: destinationLongitude,
        originMode: originMode,
        originPlaceId: originPlaceId,
        originName: originName,
        originAddress: originAddress,
        originLatitude: originLatitude,
        originLongitude: originLongitude,
        startTime: startTime,
        endTime: endTime,
        preparationMinutes: preparationMinutes,
      );
    final persisted = RuntimeMode.instance.isDemo ? added : await _remote.createSchedule(added);
    _schedules.add(persisted);
    _sort();
    await _save();
    activeRouteController.requestPlanRefresh();
    return persisted;
  }

  Future<void> updateSchedule(Schedule updated) async {
    final index = _schedules.indexWhere((e) => e.id == updated.id);

    if (index < 0) return;

    final saved = RuntimeMode.instance.isDemo ? updated : await _remote.updateSchedule(updated);
    _schedules[index] = saved;
    _sort();
    await _save();
    activeRouteController.requestPlanRefresh();
  }

  Future<void> deleteSchedule(int id) async {
    if (!RuntimeMode.instance.isDemo) await _remote.deleteSchedule(id);
    _schedules.removeWhere((e) => e.id == id);
    await _save();
    activeRouteController.requestPlanRefresh();
  }
  @override
  void dispose() {
    _remote.dispose();
    super.dispose();
  }
}

class ScheduleScope extends InheritedNotifier<ScheduleController> {
  const ScheduleScope({
    super.key,
    required ScheduleController controller,
    required super.child,
  }) : super(notifier: controller);

  static ScheduleController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ScheduleScope>();

    assert(scope != null, 'ScheduleScope를 찾을 수 없습니다.');
    return scope!.notifier!;
  }
}

//일정 추가 및 삭제시 연결된 화면에 변경사항 전달
