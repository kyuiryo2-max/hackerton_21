import 'package:flutter/material.dart';

import '../models/schedule.dart';
import '../models/place.dart';
import 'place_search_screen.dart';
import '../providers/schedule_controller.dart';

class ScheduleFormScreen extends StatefulWidget {
  final Schedule? existing;

  const ScheduleFormScreen({super.key, this.existing});

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

  @override
  void initState() {
    super.initState();

    final now = DateTime.now();

    _titleController = TextEditingController(
      text: widget.existing?.title ?? '',
    );

    _locationController = TextEditingController(
      text: widget.existing?.location ?? '',
    );

    if (widget.existing?.destinationLatitude != null &&
        widget.existing?.destinationLongitude != null) {
      _selectedDestination = Place(
        id: widget.existing!.destinationPlaceId ?? '',
        name: widget.existing!.location,
        address: widget.existing!.destinationAddress ?? '',
        latitude: widget.existing!.destinationLatitude!,
        longitude: widget.existing!.destinationLongitude!,
      );
    }
    _preparationController = TextEditingController(
      text: (widget.existing?.preparationMinutes ?? 30).toString(),
    );

    _startTime =
        widget.existing?.startTime ?? now.add(const Duration(hours: 1));

    _endTime =
        widget.existing?.endTime ?? _startTime.add(const Duration(hours: 1));
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

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    if (!_endTime.isAfter(_startTime)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('종료 시간은 시작 시간보다 늦어야 합니다.')));
      return;
    }

    if (_selectedDestination == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('목적지를 검색한 뒤 결과 목록에서 선택해 주세요.')),
      );
      return;
    }
    setState(() => _saving = true);

    final controller = ScheduleScope.of(context);

    if (widget.existing == null) {
      await controller.addSchedule(
        title: _titleController.text.trim(),
        location: _selectedDestination!.name,
        destinationPlaceId: _selectedDestination!.id,
        destinationAddress: _selectedDestination!.address,
        destinationLatitude: _selectedDestination!.latitude,
        destinationLongitude: _selectedDestination!.longitude,
        startTime: _startTime,
        endTime: _endTime,
        preparationMinutes: int.parse(_preparationController.text.trim()),
      );
    } else {
      await controller.updateSchedule(
        widget.existing!.copyWith(
          title: _titleController.text.trim(),
          location: _selectedDestination!.name,
          destinationPlaceId: _selectedDestination!.id,
          destinationAddress: _selectedDestination!.address,
          destinationLatitude: _selectedDestination!.latitude,
          destinationLongitude: _selectedDestination!.longitude,
          startTime: _startTime,
          endTime: _endTime,
          preparationMinutes: int.parse(_preparationController.text.trim()),
        ),
      );
    }

    if (!mounted) return;

    if (controller.error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(controller.error!)));
    }

    setState(() => _saving = false);
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    _preparationController.dispose();
    super.dispose();
  }

  String _format(DateTime value) {
    final y = value.year;
    final m = value.month.toString().padLeft(2, '0');
    final d = value.day.toString().padLeft(2, '0');
    final h = value.hour.toString().padLeft(2, '0');
    final min = value.minute.toString().padLeft(2, '0');

    return '$y-$m-$d $h:$min';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? '일정 추가' : '일정 수정')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Form(
            key: _formKey,
            child: Column(
              children: [
                TextFormField(
                  controller: _titleController,
                  decoration: const InputDecoration(
                    labelText: '일정 이름',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? '일정 이름을 입력해 주세요.'
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _locationController,
                  readOnly: true,
                  onTap: _selectDestination,
                  decoration: InputDecoration(
                    labelText: '목적지',
                    hintText: '눌러서 장소 검색',
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
                    padding: const EdgeInsets.only(top: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(_selectedDestination!.address,
                        style: Theme.of(context).textTheme.bodySmall),
                    ),
                  ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _preparationController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '준비 소요시간 (분)',
                    helperText: '추천 출발 시각 이전에 필요한 준비시간',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final minutes = int.tryParse(value?.trim() ?? '');
                    if (minutes == null || minutes < 0 || minutes > 1440) {
                      return '0~1440 사이의 정수를 입력해 주세요.';
                    }
                    return null;
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('시작 시간'),
            subtitle: Text(_format(_startTime)),
            trailing: const Icon(Icons.edit_calendar),
            onTap: () async {
              final result = await _pickDateTime(_startTime);
              if (result != null) {
                setState(() => _startTime = result);
              }
            },
          ),

          ListTile(
            leading: const Icon(Icons.event_available),
            title: const Text('종료 시간'),
            subtitle: Text(_format(_endTime)),
            trailing: const Icon(Icons.edit_calendar),
            onTap: () async {
              final result = await _pickDateTime(_endTime);
              if (result != null) {
                setState(() => _endTime = result);
              }
            },
          ),

          const SizedBox(height: 24),

          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '저장 중...' : '저장'),
          ),
        ],
      ),
    );
  }
}
