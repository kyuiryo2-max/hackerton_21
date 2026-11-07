
import 'package:flutter/material.dart';

import '../models/place.dart';
import '../models/route_request.dart';
import '../models/schedule.dart';
import '../providers/schedule_controller.dart';
import '../services/route_service.dart';
import 'place_search_screen.dart';
import 'route_result_screen.dart';

class NavigationScreen extends StatefulWidget {
  final String? initialDestination;
  final DateTime? initialArrivalTime;

  const NavigationScreen({
    super.key,
    this.initialDestination,
    this.initialArrivalTime,
  });

  @override
  State<NavigationScreen> createState() =>
      _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen>
    with AutomaticKeepAliveClientMixin {
  final _formKey = GlobalKey<FormState>();

  final _originController = TextEditingController();
  final _destinationController = TextEditingController();

  final _routeService = RouteService();

  Place? _originPlace;
  Place? _destinationPlace;

  DateTime? _arrivalTime;
  bool _isLoading = false;
  bool _hasAppliedDefaultSchedule = false;

  @override
  bool get wantKeepAlive => true;

  bool get _hasExplicitSchedule =>
      widget.initialDestination != null ||
      widget.initialArrivalTime != null;

  @override
  void initState() {
    super.initState();

    _destinationController.text =
        widget.initialDestination ?? '';

    _arrivalTime = widget.initialArrivalTime;
  }

  Schedule? _findNextSchedule(List<Schedule> schedules) {
    final now = DateTime.now();

    final upcoming = schedules
        .where(
          (schedule) =>
              !schedule.isCompleted &&
              schedule.startTime.isAfter(now),
        )
        .toList()
      ..sort(
        (a, b) => a.startTime.compareTo(b.startTime),
      );

    return upcoming.isEmpty ? null : upcoming.first;
  }

  void _applySchedule(Schedule schedule) {
    _destinationController.text = schedule.location;
    _destinationPlace = null;
    _arrivalTime = schedule.startTime;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (_hasExplicitSchedule ||
        _hasAppliedDefaultSchedule) {
      return;
    }

    final controller = ScheduleScope.of(context);

    if (controller.isLoading) return;

    _hasAppliedDefaultSchedule = true;

    final nextSchedule =
        _findNextSchedule(controller.schedules);

    if (nextSchedule != null) {
      _applySchedule(nextSchedule);
    }
  }

  void _refreshFromNextSchedule() {
    final controller = ScheduleScope.of(context);

    final nextSchedule =
        _findNextSchedule(controller.schedules);

    if (nextSchedule == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('예정된 일정이 없습니다.'),
        ),
      );
      return;
    }

    setState(() => _applySchedule(nextSchedule));
  }

  Future<void> _searchPlace({
    required bool isOrigin,
  }) async {
    final selected = await Navigator.push<Place>(
      context,
      MaterialPageRoute(
        builder: (_) => PlaceSearchScreen(
          title: isOrigin ? '출발지 검색' : '목적지 검색',
        ),
      ),
    );

    if (selected == null || !mounted) return;

    setState(() {
      if (isOrigin) {
        _originPlace = selected;
        _originController.text = selected.name;
      } else {
        _destinationPlace = selected;
        _destinationController.text = selected.name;
      }
    });
  }

  Future<void> _selectArrivalTime() async {
    final now = DateTime.now();

    final initial = _arrivalTime != null &&
            _arrivalTime!.isAfter(now)
        ? _arrivalTime!
        : now.add(const Duration(hours: 1));

    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 5),
    );

    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );

    if (time == null || !mounted) return;

    setState(() {
      _arrivalTime = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  String _formatDateTime(DateTime value) {
    final year = value.year;
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');

    return '$year-$month-$day $hour:$minute';
  }

  Future<void> _searchRoute() async {
    if (!_formKey.currentState!.validate()) return;

    if (_arrivalTime == null ||
        !_arrivalTime!.isAfter(DateTime.now())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('미래의 도착 희망 시간을 선택해 주세요.'),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final request = RouteRequest(
        origin: _originController.text.trim(),
        destination: _destinationController.text.trim(),
        desiredArrivalTime: _arrivalTime!,
        originPlace: _originPlace,
        destinationPlace: _destinationPlace,
      );

      final recommendation =
          await _routeService.recommendRoute(request);

      if (!mounted) return;

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RouteResultScreen(
            request: request,
            recommendation: recommendation,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('이동 추천 실패: $error'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    _originController.dispose();
    _destinationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('이동 추천'),
        actions: [
          if (!_hasExplicitSchedule)
            IconButton(
              onPressed: _refreshFromNextSchedule,
              tooltip: '다음 일정 불러오기',
              icon: const Icon(Icons.event_available),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '이동 계획 설정',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            '도보와 대중교통을 함께 고려해 '
            '도착 희망 시간에 맞는 경로를 추천합니다.',
          ),
          const SizedBox(height: 24),
          Form(
            key: _formKey,
            child: Column(
              children: [
                TextFormField(
                  controller: _originController,
                  decoration: InputDecoration(
                    labelText: '출발지',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.my_location),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.search),
                      onPressed: () =>
                          _searchPlace(isOrigin: true),
                    ),
                  ),
                  onChanged: (_) => _originPlace = null,
                  validator: (value) =>
                      value == null || value.trim().isEmpty
                          ? '출발지를 입력해 주세요.'
                          : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _destinationController,
                  decoration: InputDecoration(
                    labelText: '목적지',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.location_on),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.search),
                      onPressed: () =>
                          _searchPlace(isOrigin: false),
                    ),
                  ),
                  onChanged: (_) => _destinationPlace = null,
                  validator: (value) =>
                      value == null || value.trim().isEmpty
                          ? '목적지를 입력해 주세요.'
                          : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            '도착 희망 시간',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _selectArrivalTime,
            icon: const Icon(Icons.calendar_month),
            label: Text(
              _arrivalTime == null
                  ? '날짜 및 시간 선택'
                  : _formatDateTime(_arrivalTime!),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _isLoading ? null : _searchRoute,
            icon: const Icon(Icons.route),
            label: Text(
              _isLoading ? '계산 중...' : '이동 추천 받기',
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '현재 경로 추천은 테스트 데이터 기반입니다. '
            '실제 대중교통 운행 정보는 아직 반영되지 않습니다.',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
