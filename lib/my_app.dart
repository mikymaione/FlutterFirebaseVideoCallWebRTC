import 'package:flutter/material.dart';
import 'package:flutter_firebase_video_call_webrtc/my_home_page.dart';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: true,
      title: 'Callibre © 2022-2025, [MAIONE MIKΨ]',
      themeMode: ThemeMode.system,
      theme: ThemeData(
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
      ),
      home: const MyHomePage(),
    );
  }
}
