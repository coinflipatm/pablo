import 'dart:async';

import 'package:flutter/services.dart';

/// What Android handed us when Pablo was opened: a URI (geo:, google.navigation:,
/// a Maps link) and/or shared text.
class IncomingIntent {
  const IncomingIntent({this.action, this.data, this.text});

  final String? action;
  final String? data;
  final String? text;

  bool get isEmpty =>
      (data == null || data!.trim().isEmpty) &&
      (text == null || text!.trim().isEmpty);

  static IncomingIntent fromMap(Map<dynamic, dynamic>? m) {
    if (m == null) return const IncomingIntent();
    return IncomingIntent(
      action: m['action'] as String?,
      data: m['data'] as String?,
      text: m['text'] as String?,
    );
  }

  @override
  String toString() => 'IncomingIntent(action: $action, data: $data, text: $text)';
}

class IntentChannel {
  static const MethodChannel _channel = MethodChannel('cv.towtruck.pablo/intent');
  static final StreamController<IncomingIntent> _controller =
      StreamController<IncomingIntent>.broadcast();
  static bool _installed = false;

  /// Call once at startup so intents that arrive while the app is already
  /// running reach [newIntents].
  static void install() {
    if (_installed) return;
    _installed = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onNewIntent') {
        _controller.add(IncomingIntent.fromMap(call.arguments as Map?));
      }
    });
  }

  static Stream<IncomingIntent> get newIntents => _controller.stream;

  /// The intent that launched this activity, if any.
  static Future<IncomingIntent> getInitial() async {
    try {
      final Map<dynamic, dynamic>? m =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('getInitialIntent');
      return IncomingIntent.fromMap(m);
    } on PlatformException {
      return const IncomingIntent();
    } on MissingPluginException {
      return const IncomingIntent();
    }
  }

  /// SHA-1 of the signing certificate, colon separated. Used to restrict the
  /// Routes API key to this APK.
  static Future<String?> getSigningSha1() async {
    try {
      return await _channel.invokeMethod<String>('getSigningSha1');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
