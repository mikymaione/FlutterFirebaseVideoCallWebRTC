import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

Future<Map<String, dynamic>> getTurnCredential(String host, int port) async {
  final client = HttpClient(context: SecurityContext());

  client.badCertificateCallback = (X509Certificate cert, String host, int port) {
    if (kDebugMode) {
      print('getTurnCredential: Allow self-signed certificate => $host:$port. ');
    }

    return true;
  };

  final url = 'https://$host:$port/api/turn?service=turn&username=flutter-webrtc';
  final request = await client.getUrl(Uri.parse(url));
  final response = await request.close();
  final responseBody = await response.transform(const Utf8Decoder()).join();

  if (kDebugMode) {
    print('getTurnCredential:response => $responseBody.');
  }

  return const JsonDecoder().convert(responseBody);
}
