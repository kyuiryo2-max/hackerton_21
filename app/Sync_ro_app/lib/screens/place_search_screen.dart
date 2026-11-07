
import 'package:flutter/material.dart';

import '../data/mock_places.dart';

class PlaceSearchScreen extends StatefulWidget {
  final String title;

  const PlaceSearchScreen({
    super.key,
    required this.title,
  });

  @override
  State<PlaceSearchScreen> createState() =>
      _PlaceSearchScreenState();
}

class _PlaceSearchScreenState extends State<PlaceSearchScreen> {
  final TextEditingController _searchController =
      TextEditingController();

  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keyword = _query.trim().toLowerCase();

    final results = mockPlaces.where((place) {
      return place.name.toLowerCase().contains(keyword) ||
          place.address.toLowerCase().contains(keyword);
    }).toList();

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: '장소 이름 또는 주소 검색',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                ),
              ),
              onChanged: (value) {
                setState(() => _query = value);
              },
            ),
          ),
          Expanded(
            child: results.isEmpty
                ? const Center(
                    child: Text('검색 결과가 없습니다.'),
                  )
                : ListView.builder(
                    itemCount: results.length,
                    itemBuilder: (context, index) {
                      final place = results[index];

                      return ListTile(
                        leading: const Icon(Icons.place),
                        title: Text(place.name),
                        subtitle: Text(place.address),
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
