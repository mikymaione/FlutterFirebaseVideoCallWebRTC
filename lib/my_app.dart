import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_firebase_video_call_webrtc/my_home_page.dart';

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  static const _chars = 'AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz1234567890';
  static final _rnd = Random();

  static String getRandomString(int length) => String.fromCharCodes(
        Iterable.generate(
          length,
          (index) => _chars.codeUnitAt(_rnd.nextInt(_chars.length)),
        ),
      );

  late final String roomId;

  @override
  void initState() {
    super.initState();

    final uri = Uri.base;
    final fromPath = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : null;

    roomId = (fromPath != null && fromPath.isNotEmpty) ? fromPath : getRandomString(20);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "WebRTC - [MAIONE MIKΨ]",
      themeMode: ThemeMode.system,
      theme: ThemeData(
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
      ),
      home: MyHomePage(
        roomId: roomId,
      ),
    );
  }
}
