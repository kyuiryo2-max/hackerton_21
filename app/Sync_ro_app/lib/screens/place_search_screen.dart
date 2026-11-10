import 'package:flutter/material.dart';

import '../models/place.dart';
import '../services/place_search_service.dart';

class PlaceSearchScreen extends StatefulWidget {
  final String title;
  final String initialQuery;

  const PlaceSearchScreen({super.key, this.title = '장소 검색', this.initialQuery = ''});

  @override
  State<PlaceSearchScreen> createState() => _PlaceSearchScreenState();
}

class _PlaceSearchScreenState extends State<PlaceSearchScreen> {
  final TextEditingController _controller = TextEditingController();

  final PlaceSearchService _service = PlaceSearchService();

  List<Place> _results = [];

  bool _isLoading = false;
  String? _errorMessage;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialQuery;
    if (widget.initialQuery.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search();
      });
    }
  }

  Future<void> _search() async {
    final keyword = _controller.text.trim();
    final requestId = ++_requestId;

    if (keyword.isEmpty) {
      setState(() {
        _results = [];
        _errorMessage = null;
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _results = [];
    });

    try {
      final places = await _service.searchPlaces(keyword);

      if (!mounted || requestId != _requestId) {
        return;
      }

      setState(() {
        _results = places;
      });
    } catch (error) {
      if (!mounted || requestId != _requestId) {
        return;
      }

      setState(() {
        _errorMessage = '장소 검색 중 오류가 발생했습니다.\n$error';
      });
    } finally {
      if (mounted && requestId == _requestId) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _requestId++;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: const InputDecoration(
                      labelText: '장소명 또는 주소',
                      hintText: '예: 서울역',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _isLoading ? null : _search,
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
          ),

          if (_isLoading) const LinearProgressIndicator(),

          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.red),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _search,
                    child: const Text('다시 검색'),
                  ),
                ],
              ),
            ),

          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Text(
                      _isLoading
                          ? '장소를 검색하고 있습니다.'
                          : _errorMessage != null
                          ? '검색을 다시 시도해 주세요.'
                          : '검색 결과가 없습니다.\n'
                                '예: 안암역, 안암역3번출구, 청량리역\n'
                                '서버가 장소 검색을 지원하지 않으면 등록된 시연/샘플 장소만 표시됩니다.',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.separated(
                    itemCount: _results.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final place = _results[index];

                      return ListTile(
                        leading: const Icon(Icons.location_on_outlined),
                        title: Text(place.name),
                        subtitle: Text(place.address),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.pop(context, place);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
