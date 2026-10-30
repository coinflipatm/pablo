import 'package:shared_preferences/shared_preferences.dart';

/// Per-phone settings. A driver sets their unit once; after that Pablo
/// opens, routes, and goes.
class AppSettings {
  AppSettings._(this._prefs);

  static const String _kUnitKind = 'unit_kind'; // 'light' | 'tractor'
  static const String _kUnitId = 'unit_id';
  static const String _kTrailerId = 'trailer_id'; // '' = bobtail
  static const String _kAutoRoute = 'auto_route';

  final SharedPreferences _prefs;

  static Future<AppSettings> load() async => AppSettings._(await SharedPreferences.getInstance());

  String get unitKind => _prefs.getString(_kUnitKind) ?? 'tractor';
  String? get unitId => _prefs.getString(_kUnitId);
  String get trailerId => _prefs.getString(_kTrailerId) ?? '';
  bool get autoRoute => _prefs.getBool(_kAutoRoute) ?? true;

  Future<void> setUnit({required String kind, required String id}) async {
    await _prefs.setString(_kUnitKind, kind);
    await _prefs.setString(_kUnitId, id);
  }

  Future<void> setTrailer(String id) => _prefs.setString(_kTrailerId, id);
  Future<void> setAutoRoute(bool v) => _prefs.setBool(_kAutoRoute, v);
}
