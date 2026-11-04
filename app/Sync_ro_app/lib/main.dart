
import 'package:flutter/material.dart';

void main() {
  runApp(const SyncRoApp());
}

class SyncRoApp extends StatelessWidget {
  const SyncRoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sync_ro_app',
      debugShowCheckedModeBanner: false,
      home: const Scaffold(
        backgroundColor: Colors.white,
        body: SizedBox.expand(),
      ),
    );
  }
}
