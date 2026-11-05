
import 'package:flutter/material.dart';

import '../models/schedule.dart';
import '../providers/schedule_controller.dart';

class ScheduleFormScreen extends StatefulWidget {
  final Schedule? existing;

  const ScheduleFormScreen({
    super.key,
    this.existing,
  });

  @override
  State<ScheduleFormScreen> createState() =>
      _ScheduleFormScreenState();
}

class _ScheduleFormScreenState extends State<ScheduleFormScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _titleController;
  late final TextEditingController _locationController;

  late DateTime _startTime;
  late DateTime _endTime;

  bool _saving = false;

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

    _startTime = widget.existing?.startTime ??
        now.add(const Duration(hours: 1));

    _endTime = widget.existing?.endTime ??
        _startTime.add(const Duration(hours: 1));
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

    return DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    if (!_endTime.isAfter(_startTime)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('종료 시간은 시작 시간보다 늦어야 합니다.'),
        ),
      );
      return;
    }

    setState(() => _saving = true);

    final controller = ScheduleScope.of(context);

    if (widget.existing == null) {
      await controller.addSchedule(
        title: _titleController.text.trim(),
        location: _locationController.text.trim(),
        startTime: _startTime,
        endTime: _endTime,
      );
    } else {
      await controller.updateSchedule(
        widget.existing!.copyWith(
          title: _titleController.text.trim(),
          location: _locationController.text.trim(),
          startTime: _startTime,
          endTime: _endTime,
        ),
      );
    }

    if (!mounted) return;

    if (controller.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(controller.error!)),
      );
    }

    setState(() => _saving = false);
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
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
      appBar: AppBar(
        title: Text(
          widget.existing == null ? '일정 추가' : '일정 수정',
        ),
      ),
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
                  validator: (value) =>
                      value == null || value.trim().isEmpty
                          ? '일정 이름을 입력해 주세요.'
                          : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _locationController,
                  decoration: const InputDecoration(
                    labelText: '장소',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) =>
                      value == null || value.trim().isEmpty
                          ? '장소를 입력해 주세요.'
                          : null,
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
