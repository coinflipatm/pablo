import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import 'units.dart';

class Tractor {
  Tractor({
    required this.id,
    required this.name,
    required this.detail,
    required this.axles,
    required this.heightMm,
    required this.widthMm,
    required this.bumperToKingpinMm,
    required this.estimated,
  });

  factory Tractor.fromJson(Map<String, dynamic> j) => Tractor(
        id: j['id'] as String,
        name: j['name'] as String,
        detail: (j['detail'] as String?) ?? '',
        axles: (j['axles'] as num).toInt(),
        heightMm: (j['heightMm'] as num).toInt(),
        widthMm: (j['widthMm'] as num).toInt(),
        bumperToKingpinMm: (j['bumperToKingpinMm'] as num).toInt(),
        estimated: (j['estimated'] as bool?) ?? false,
      );

  final String id;
  final String name;
  final String detail;
  int axles;
  int heightMm;
  int widthMm;
  int bumperToKingpinMm;
  bool estimated;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'detail': detail,
        'axles': axles,
        'heightMm': heightMm,
        'widthMm': widthMm,
        'bumperToKingpinMm': bumperToKingpinMm,
        'estimated': estimated,
      };
}

class Trailer {
  Trailer({
    required this.id,
    required this.name,
    required this.detail,
    required this.axles,
    required this.lengthMm,
    required this.permitHeightMm,
    required this.permitWidthMm,
    required this.permitGrossKg,
    required this.estimated,
  });

  factory Trailer.fromJson(Map<String, dynamic> j) => Trailer(
        id: j['id'] as String,
        name: j['name'] as String,
        detail: (j['detail'] as String?) ?? '',
        axles: (j['axles'] as num).toInt(),
        lengthMm: (j['lengthMm'] as num).toInt(),
        permitHeightMm: (j['permitHeightMm'] as num).toInt(),
        permitWidthMm: (j['permitWidthMm'] as num).toInt(),
        permitGrossKg: (j['permitGrossKg'] as num).toInt(),
        estimated: (j['estimated'] as bool?) ?? false,
      );

  final String id;
  final String name;
  final String detail;
  int axles;
  int lengthMm;
  int permitHeightMm;
  int permitWidthMm;
  int permitGrossKg;
  bool estimated;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'detail': detail,
        'axles': axles,
        'lengthMm': lengthMm,
        'permitHeightMm': permitHeightMm,
        'permitWidthMm': permitWidthMm,
        'permitGrossKg': permitGrossKg,
        'estimated': estimated,
      };
}

class LightUnit {
  const LightUnit({required this.id, required this.name});

  factory LightUnit.fromJson(Map<String, dynamic> j) =>
      LightUnit(id: j['id'] as String, name: j['name'] as String);

  final String id;
  final String name;
}

/// What the driver is actually sitting in: a light unit, a bobtail tractor,
/// or a tractor + trailer. This is what gets sent to the Routes API.
class Combination {
  const Combination._({
    required this.title,
    required this.truckMode,
    this.axles,
    this.heightMm,
    this.widthMm,
    this.lengthMm,
    this.weightKg,
    this.estimated = false,
  });

  factory Combination.light(LightUnit u) =>
      Combination._(title: u.name, truckMode: false);

  factory Combination.bobtail(Tractor t) => Combination._(
        title: '${t.name} (bobtail)',
        truckMode: true,
        axles: t.axles,
        heightMm: t.heightMm,
        widthMm: t.widthMm,
        lengthMm: t.bumperToKingpinMm + 2500, // kingpin to rear of frame, rough
        weightKg: 15000,
        estimated: true,
      );

  factory Combination.rig(Tractor t, Trailer tr) => Combination._(
        title: '${t.name} + ${tr.name}',
        truckMode: true,
        axles: t.axles + tr.axles,
        heightMm: t.heightMm > tr.permitHeightMm ? t.heightMm : tr.permitHeightMm,
        widthMm: t.widthMm > tr.permitWidthMm ? t.widthMm : tr.permitWidthMm,
        lengthMm: t.bumperToKingpinMm + tr.lengthMm,
        weightKg: tr.permitGrossKg,
        estimated: t.estimated || tr.estimated,
      );

  final String title;
  final bool truckMode;
  final int? axles;
  final int? heightMm;
  final int? widthMm;
  final int? lengthMm;
  final int? weightKg;
  final bool estimated;

  String get summary {
    if (!truckMode) return 'Light duty · routed like a car';
    return '$axles axles · ${Units.ftIn(lengthMm)} long · ${Units.ftIn(heightMm)} high · '
        '${Units.ftIn(widthMm)} wide · ${Units.lb(weightKg)}';
  }

  /// Routes API routeModifiers.vehicleInfo
  Map<String, dynamic>? get vehicleInfo {
    if (!truckMode) return null;
    return <String, dynamic>{
      'totalAxleCount': axles,
      'totalHeightMm': heightMm,
      'totalWidthMm': widthMm,
      'totalLengthMm': lengthMm,
      'totalWeightKg': weightKg,
    };
  }
}

/// The fleet: defaults from assets/profiles.json, with any edits the user made
/// in the app layered on top.
class Fleet {
  Fleet({required this.tractors, required this.trailers, required this.lightUnits});

  final List<Tractor> tractors;
  final List<Trailer> trailers;
  final List<LightUnit> lightUnits;

  static const String _overridesKey = 'profile_overrides_v1';

  static Future<Fleet> load() async {
    final String raw = await rootBundle.loadString('assets/profiles.json');
    final Map<String, dynamic> j = jsonDecode(raw) as Map<String, dynamic>;
    final Fleet fleet = Fleet(
      tractors: (j['tractors'] as List<dynamic>)
          .map((dynamic e) => Tractor.fromJson(e as Map<String, dynamic>))
          .toList(),
      trailers: (j['trailers'] as List<dynamic>)
          .map((dynamic e) => Trailer.fromJson(e as Map<String, dynamic>))
          .toList(),
      lightUnits: (j['lightUnits'] as List<dynamic>)
          .map((dynamic e) => LightUnit.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
    await fleet._applyOverrides();
    return fleet;
  }

  Tractor? tractorById(String? id) {
    for (final Tractor t in tractors) {
      if (t.id == id) return t;
    }
    return null;
  }

  Trailer? trailerById(String? id) {
    for (final Trailer t in trailers) {
      if (t.id == id) return t;
    }
    return null;
  }

  LightUnit? lightById(String? id) {
    for (final LightUnit u in lightUnits) {
      if (u.id == id) return u;
    }
    return null;
  }

  Future<void> _applyOverrides() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_overridesKey);
      if (raw == null) return;
      final Map<String, dynamic> o = jsonDecode(raw) as Map<String, dynamic>;
      final Map<String, dynamic> tr = (o['tractors'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      final Map<String, dynamic> tl = (o['trailers'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      for (final Tractor t in tractors) {
        final Map<String, dynamic>? e = tr[t.id] as Map<String, dynamic>?;
        if (e == null) continue;
        t.axles = (e['axles'] as num?)?.toInt() ?? t.axles;
        t.heightMm = (e['heightMm'] as num?)?.toInt() ?? t.heightMm;
        t.widthMm = (e['widthMm'] as num?)?.toInt() ?? t.widthMm;
        t.bumperToKingpinMm = (e['bumperToKingpinMm'] as num?)?.toInt() ?? t.bumperToKingpinMm;
        t.estimated = false;
      }
      for (final Trailer t in trailers) {
        final Map<String, dynamic>? e = tl[t.id] as Map<String, dynamic>?;
        if (e == null) continue;
        t.axles = (e['axles'] as num?)?.toInt() ?? t.axles;
        t.lengthMm = (e['lengthMm'] as num?)?.toInt() ?? t.lengthMm;
        t.permitHeightMm = (e['permitHeightMm'] as num?)?.toInt() ?? t.permitHeightMm;
        t.permitWidthMm = (e['permitWidthMm'] as num?)?.toInt() ?? t.permitWidthMm;
        t.permitGrossKg = (e['permitGrossKg'] as num?)?.toInt() ?? t.permitGrossKg;
        t.estimated = false;
      }
    } catch (_) {
      // Bad or missing overrides: defaults stand.
    }
  }

  /// Persists the current numbers for every tractor and trailer as overrides.
  Future<void> saveOverrides() async {
    final Map<String, dynamic> o = <String, dynamic>{
      'tractors': <String, dynamic>{
        for (final Tractor t in tractors) t.id: t.toJson(),
      },
      'trailers': <String, dynamic>{
        for (final Trailer t in trailers) t.id: t.toJson(),
      },
    };
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_overridesKey, jsonEncode(o));
  }

  static Future<void> clearOverrides() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_overridesKey);
  }
}
