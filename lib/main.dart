import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_firebase_video_call_webrtc/firebase_options.dart';
import 'package:flutter_firebase_video_call_webrtc/my_app.dart';

Future<void> main() async {
  FlutterError.onError = (details) => FlutterError.presentError(details);
  
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  runApp(const MyApp());
}
