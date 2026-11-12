import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../models/schedule.dart';
import '../models/place.dart';
import 'place_search_screen.dart';
import '../providers/schedule_controller.dart';
import '../services/planner_store.dart';

class ScheduleFormScreen extends StatefulWidget {
  final Schedule? existing;

  /// 새 일정을 만들 때 미리 채워 둘 값 (예: AI 질문에서 읽은 일정). 저장하면 새 일정으로 추가돼요.
  final Schedule? initial;

  /// 시간표의 반복 일정을 고칠 때. 저장하면 반복 일정만 바뀌고 서버 일정은 만들지 않아요.
  final Routine? routine;

  /// 새 일정을 "매주 반복"으로 시작할 때 (시간표 빈 칸을 눌렀을 때)
  final bool startRepeating;

  const ScheduleFormScreen({super.key, this.existing, this.initial, this.routine, this.startRepeating = false});

  @override
  State<ScheduleFormScreen> createState() => _ScheduleFormScreenState();
}

class _ScheduleFormScreenState extends State<ScheduleFormScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _titleController;
  late final TextEditingController _locationController;
  late final TextEditingController _preparationController;

  late DateTime _startTime;
  late DateTime _endTime;

  bool _saving = false;
  Place? _selectedDestination;
  late String _originMode;
  Place? _selectedOrigin;
  late final TextEditingController _originController;

  /// 매주 반복 (새 일정·반복 일정 고치기에서만 보여요)
  late bool _repeat;
  late final Set<int> _repeatDays;
  bool get _editingRoutine => widget.routine != null;
  bool get _canRepeat => widget.existing == null;

  @override
  void initState() {
    super.initState();

    final now = DateTime.now();
    final routine = widget.routine;
    final seed = widget.existing ?? widget.initial ?? (routine == null ? null : routine.occurrence(routine.nextStart(now)));
    _repeat = routine != null || widget.startRepeating;
    _repeatDays = {...?routine?.weekdays};

    _titleController = TextEditingController(
      text: seed?.title ?? '',
    );

    _locationController = TextEditingController(
      text: seed?.location ?? '',
    );

    if (seed != null &&
        seed.destinationLatitude != null &&
        seed.destinationLongitude != null) {
      _selectedDestination = Place(
        id: seed.destinationPlaceId ?? '',
        name: seed.location,
        address: seed.destinationAddress ?? '',
        latitude: seed.destinationLatitude!,
        longitude: seed.destinationLongitude!,
      );
    }
    _originMode = seed?.originMode == 'place' ? 'place' : 'current';
    _originController = TextEditingController(text: seed?.originName ?? '');
    if (seed != null &&
        seed.originLatitude != null &&
        seed.originLongitude != null) {
      _selectedOrigin = Place(
        id: seed.originPlaceId ?? '',
        name: seed.originName ?? '출발지',
        address: seed.originAddress ?? '',
        latitude: seed.originLatitude!,
        longitude: seed.originLongitude!,
      );
    }
    _preparationController = TextEditingController(
      text: (seed?.preparationMinutes ?? 30).toString(),
    );

    _startTime =
        seed?.startTime ?? now.add(const Duration(hours: 1));

    _endTime =
        seed?.endTime ?? _startTime.add(const Duration(hours: 1));
    // 종료 시간은 화면에서 뺐어요 (길찾기에 안 쓰여요). 시간표에 보일 길이만 유지해요.
    final kept = _endTime.difference(_startTime);
    _duration = kept.inMinutes > 0 ? kept : const Duration(hours: 1);
    if (_repeatDays.isEmpty) _repeatDays.add(_startTime.weekday);
  }

  static const _dayNames = ['월', '화', '수', '목', '금', '토', '일'];

  int get _startMinutes => _startTime.hour * 60 + _startTime.minute;

  /// 반복이면 고른 요일 중 가장 가까운 회차로 맞춰요
  DateTime _firstOccurrence() => Routine(
        id: 0, title: '', weekdays: _repeatDays.toList(),
        startMinutes: _startMinutes, endMinutes: _startMinutes + 60,
      ).nextStart(DateTime.now());

  String get _repeatLabel {
    final days = [for (var d = 1; d <= 7; d++) if (_repeatDays.contains(d)) _dayNames[d - 1]].join('·');
    final hm = '${_startTime.hour.toString().padLeft(2, '0')}:${_startTime.minute.toString().padLeft(2, '0')}';
    return '매주 $days $hm';
  }

  Future<void> _pickTimeOnly() async {
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_startTime));
    if (time == null) return;
    setState(() => _setArrival(
        DateTime(_startTime.year, _startTime.month, _startTime.day, time.hour, time.minute)));
  }

  late Duration _duration;

  /// 도착 시각을 바꾸면 종료 시간도 같은 길이만큼 따라가요.
  void _setArrival(DateTime value) {
    _startTime = value;
    _endTime = value.add(_duration);
  }

  int get _prepMinutes => int.tryParse(_preparationController.text.trim()) ?? 0;

  void _changePrep(int delta) {
    final next = (_prepMinutes + delta).clamp(0, 180);
    setState(() => _preparationController.text = '$next');
  }

  /// "오늘 18:30", "내일 09:00", "11월 14일 (금) 09:00"
  String _arrivalLabel(DateTime value) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(value.year, value.month, value.day);
    final hm = '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
    final diff = day.difference(today).inDays;
    if (diff == 0) return '오늘 $hm';
    if (diff == 1) return '내일 $hm';
    const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    return '${value.month}월 ${value.day}일 (${weekdays[value.weekday - 1]}) $hm';
  }

  Future<DateTime?> _pickDateTime(DateTime initial) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );

    if (date == null || !mounted) return null;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );

    if (time == null) return null;

    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> _selectDestination() async {
    final place = await Navigator.push<Place>(
      context,
      MaterialPageRoute(builder: (_) => PlaceSearchScreen(
        title: '일정 목적지 선택',
        initialQuery: _locationController.text.trim(),
      )),
    );
    if (!mounted || place == null) return;
    setState(() {
      _selectedDestination = place;
      _locationController.text = place.name;
    });
  }

  Future<void> _selectOrigin() async {
    final place = await Navigator.push<Place>(
      context,
      MaterialPageRoute(builder: (_) => PlaceSearchScreen(
        title: '출발지 선택',
        initialQuery: _originController.text.trim(),
      )),
    );
    if (!mounted || place == null) return;
    setState(() {
      _selectedOrigin = place;
      _originController.text = place.name;
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    if (_repeat) {
      if (_repeatDays.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('반복할 요일을 하나 이상 골라 주세요.')),
        );
        return;
      }
      // 고른 요일 중 가장 가까운 회차 (항상 앞으로의 시각이에요)
      _setArrival(_firstOccurrence());
    }
    if (!_startTime.isAfter(DateTime.now())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('도착 시각이 이미 지났어요. 앞으로의 시각을 골라 주세요.')),
      );
      return;
    }
    _endTime = _startTime.add(_duration);

    if (_selectedDestination == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('목적지를 검색한 뒤 결과 목록에서 선택해 주세요.')),
      );
      return;
    }
    if (_originMode == 'place' && _selectedOrigin == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('출발지를 검색한 뒤 장소를 선택해 주세요.')),
      );
      return;
    }
    setState(() => _saving = true);

    final controller = ScheduleScope.of(context);
    final prep = int.parse(_preparationController.text.trim());

    // 반복 일정: 시간표(이 기기)에 저장. 서버 일정은 회차마다 "경로 보기"를 누를 때 만들어요.
    Routine? routineToSave;
    if (_repeat) {
      final store = PlannerStore.instance;
      final draft = Schedule(
        id: 0,
        title: _titleController.text.trim(),
        location: _selectedDestination!.name,
        destinationPlaceId: _selectedDestination!.id,
        destinationAddress: _selectedDestination!.address,
        destinationLatitude: _selectedDestination!.latitude,
        destinationLongitude: _selectedDestination!.longitude,
        originMode: _originMode,
        originPlaceId: _originMode == 'place' ? _selectedOrigin?.id : null,
        originName: _originMode == 'place' ? _selectedOrigin?.name : null,
        originAddress: _originMode == 'place' ? _selectedOrigin?.address : null,
        originLatitude: _originMode == 'place' ? _selectedOrigin?.latitude : null,
        originLongitude: _originMode == 'place' ? _selectedOrigin?.longitude : null,
        startTime: _startTime,
        endTime: _startTime.add(_duration),
        preparationMinutes: prep,
      );
      final base = widget.routine;
      routineToSave = Routine(
        id: base?.id ?? store.newRoutineId(),
        title: draft.title,
        location: draft.location,
        weekdays: [for (var d = 1; d <= 7; d++) if (_repeatDays.contains(d)) d],
        startMinutes: _startMinutes,
        endMinutes: (_startMinutes + _duration.inMinutes).clamp(_startMinutes + 1, 24 * 60).toInt(),
        colorIndex: base?.colorIndex ?? store.routines.length,
        trip: Routine.tripOf(draft),
      );
    }
    if (_editingRoutine) {
      try {
        await PlannerStore.instance.upsertRoutine(routineToSave!);
        if (mounted) Navigator.pop(context);
      } catch (error) {
        if (!mounted) return;
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('반복 일정 저장 실패: $error')));
      }
      return;
    }

    try {
    Schedule saved;
    if (widget.existing == null) {
      saved = await controller.addSchedule(
        title: _titleController.text.trim(),
        location: _selectedDestination!.name,
        destinationPlaceId: _selectedDestination!.id,
        destinationAddress: _selectedDestination!.address,
        destinationLatitude: _selectedDestination!.latitude,
        destinationLongitude: _selectedDestination!.longitude,
        originMode: _originMode,
        originPlaceId: _originMode == 'place' ? _selectedOrigin?.id : null,
        originName: _originMode == 'place' ? _selectedOrigin?.name : null,
        originAddress: _originMode == 'place' ? _selectedOrigin?.address : null,
        originLatitude: _originMode == 'place' ? _selectedOrigin?.latitude : null,
        originLongitude: _originMode == 'place' ? _selectedOrigin?.longitude : null,
        startTime: _startTime,
        endTime: _endTime,
        preparationMinutes: prep,
      );
    } else {
      saved = widget.existing!.copyWith(
          title: _titleController.text.trim(),
          location: _selectedDestination!.name,
          destinationPlaceId: _selectedDestination!.id,
          destinationAddress: _selectedDestination!.address,
          destinationLatitude: _selectedDestination!.latitude,
          destinationLongitude: _selectedDestination!.longitude,
          originMode: _originMode,
          clearOrigin: _originMode == 'current',
          originPlaceId: _selectedOrigin?.id,
          originName: _selectedOrigin?.name,
          originAddress: _selectedOrigin?.address,
          originLatitude: _selectedOrigin?.latitude,
          originLongitude: _selectedOrigin?.longitude,
          startTime: _startTime,
          endTime: _endTime,
          preparationMinutes: prep,
        );
      await controller.updateSchedule(saved);
    }
    // 첫 회차는 서버 일정으로 저장했고, 반복은 시간표에 넣어요
    if (routineToSave != null) await PlannerStore.instance.upsertRoutine(routineToSave);

    if (!mounted) return;

    if (controller.error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(controller.error!)));
    }

    setState(() => _saving = false);
    if (controller.error == null) {
      Navigator.pop(context, saved);
    }
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('일정 서버 저장 실패: $error')),
      );
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    _originController.dispose();
    _preparationController.dispose();
    super.dispose();
  }

  Widget _question(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_editingRoutine ? '반복 일정 수정' : (widget.existing == null ? '일정 추가' : '일정 수정'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Form(
            key: _formKey,
            child: Column(
              children: [
                // ① 이름
                _question('일정 이름'),
                TextFormField(
                  controller: _titleController,
                  decoration: const InputDecoration(
                    hintText: '예: 출근, 전공 수업, 친구 약속',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? '일정 이름을 입력해 주세요.'
                      : null,
                ),
                const SizedBox(height: 24),

                // ② 목적지
                _question('어디로 가요?'),
                TextFormField(
                  controller: _locationController,
                  readOnly: true,
                  onTap: _selectDestination,
                  decoration: InputDecoration(
                    hintText: '눌러서 장소 검색 (예: 을지로입구역)',
                    prefixIcon: const Icon(Icons.place_outlined),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.search),
                      onPressed: _selectDestination,
                    ),
                  ),
                  validator: (_) => _selectedDestination == null
                      ? '검색 결과에서 목적지를 선택해 주세요.' : null,
                ),
                if (_selectedDestination != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(_selectedDestination!.address,
                        style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                    ),
                  ),
                const SizedBox(height: 24),

                // ③ 출발지: 큰 선택 카드 두 개
                _question('어디서 출발해요?'),
                Row(children: [
                  Expanded(
                    child: _OriginChoice(
                      selected: _originMode == 'current',
                      icon: Icons.my_location,
                      title: '현재 위치',
                      subtitle: '나갈 때 있는 곳에서',
                      onTap: () => setState(() => _originMode = 'current'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _OriginChoice(
                      selected: _originMode == 'place',
                      icon: Icons.search,
                      title: '직접 고르기',
                      subtitle: '집, 학교 등 정해진 곳',
                      onTap: () => setState(() => _originMode = 'place'),
                    ),
                  ),
                ]),
                if (_originMode == 'place') ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _originController,
                    readOnly: true,
                    onTap: _selectOrigin,
                    decoration: InputDecoration(
                      hintText: '눌러서 출발 장소 검색',
                      prefixIcon: const Icon(Icons.trip_origin),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: _selectOrigin),
                    ),
                    validator: (_) => _originMode == 'place' && _selectedOrigin == null
                        ? '출발 장소를 선택해 주세요.' : null,
                  ),
                  if (_selectedOrigin != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, left: 4),
                      child: Align(alignment: Alignment.centerLeft,
                        child: Text(_selectedOrigin!.address,
                          style: const TextStyle(fontSize: 12, color: AppTheme.textMuted))),
                    ),
                ],
                const SizedBox(height: 24),

                // ④ 반복 (새 일정·반복 일정에서만)
                if (_canRepeat) ...[
                  _question('매주 반복해요?'),
                  Row(children: [
                    Expanded(
                      child: _OriginChoice(
                        selected: !_repeat,
                        icon: Icons.event,
                        title: '이번 한 번',
                        subtitle: '약속, 면접 등',
                        onTap: _editingRoutine ? () {} : () => setState(() => _repeat = false),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _OriginChoice(
                        selected: _repeat,
                        icon: Icons.repeat,
                        title: '매주 반복',
                        subtitle: '수업, 출근 등',
                        onTap: () => setState(() => _repeat = true),
                      ),
                    ),
                  ]),
                  if (_repeat) ...[
                    const SizedBox(height: 12),
                    Wrap(spacing: 6, children: [
                      for (var d = 1; d <= 7; d++)
                        FilterChip(
                          label: Text(_dayNames[d - 1]),
                          selected: _repeatDays.contains(d),
                          onSelected: (on) => setState(() => on ? _repeatDays.add(d) : _repeatDays.remove(d)),
                        ),
                    ]),
                    const Padding(
                      padding: EdgeInsets.only(top: 6, left: 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('시간표에 들어가요. 시간표에서 누르면 다음 회차 경로를 볼 수 있어요.',
                          style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                ],

                // ⑤ 도착 목표 (서버에 arrive_by 로 보내는 값이에요)
                _question('몇 시까지 도착해야 해요?'),
                Material(
                  color: AppTheme.primarySoft,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () async {
                      // 반복이면 요일은 위에서 고르니까 시각만
                      if (_repeat) return _pickTimeOnly();
                      final result = await _pickDateTime(_startTime);
                      if (result != null) setState(() => _setArrival(result));
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      child: Row(children: [
                        const Icon(Icons.flag_outlined, color: AppTheme.primary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(_repeat ? _repeatLabel : _arrivalLabel(_startTime),
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800,
                                color: AppTheme.primary)),
                        ),
                        const Icon(Icons.edit_calendar, color: AppTheme.primary),
                      ]),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 6, left: 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('이 시각에서 거꾸로 계산해서 언제 나가야 하는지 알려 드려요.',
                      style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                  ),
                ),
                const SizedBox(height: 24),

                // ⑥ 준비 시간
                _question('나가기 전 준비 시간'),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.border),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(children: [
                    IconButton(
                      onPressed: () => _changePrep(-5),
                      icon: const Icon(Icons.remove),
                      tooltip: '5분 줄이기',
                    ),
                    Expanded(
                      child: TextFormField(
                        controller: _preparationController,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                        decoration: const InputDecoration(border: InputBorder.none, suffixText: '분'),
                        validator: (value) {
                          final minutes = int.tryParse(value?.trim() ?? '');
                          if (minutes == null || minutes < 0 || minutes > 1440) {
                            return '0~1440 사이의 숫자를 입력해 주세요.';
                          }
                          return null;
                        },
                      ),
                    ),
                    IconButton(
                      onPressed: () => _changePrep(5),
                      icon: const Icon(Icons.add),
                      tooltip: '5분 늘리기',
                    ),
                  ]),
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 6, left: 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('출발 시각보다 이만큼 먼저 준비를 시작하라고 알려 드려요.',
                      style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 28),

          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '저장 중...' : '저장'),
          ),
        ],
      ),
    );
  }
}

/// 출발지 선택 카드 (현재 위치 / 직접 고르기)
class _OriginChoice extends StatelessWidget {
  const _OriginChoice({
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppTheme.primarySoft : Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? AppTheme.primary : AppTheme.border, width: 2),
          ),
          child: Row(children: [
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? AppTheme.primary : AppTheme.textMuted),
            const SizedBox(width: 10),
            Icon(icon, size: 20, color: selected ? AppTheme.primary : AppTheme.textMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(fontWeight: FontWeight.w700,
                    color: selected ? AppTheme.primary : AppTheme.textStrong)),
                Text(subtitle, style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
