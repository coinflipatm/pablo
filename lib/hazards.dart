import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'polyline.dart';

class Hazard {
  const Hazard({
    required this.id,
    required this.type,
    required this.note,
    required this.lat,
    required this.lng,
    required this.radiusM,
  });

  factory Hazard.fromJson(Map<String, dynamic> j) => Hazard(
        id: j['id'] as String,
        type: j['type'] as String,
        note: (j['note'] as String?) ?? '',
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
        radiusM: ((j['radiusM'] as num?) ?? 150).toDouble(),
      );

  final String id;
  final String type;
  final String note;
  final double lat;
  final double lng;
  final double radiusM;

  String get typeLabel {
    switch (type) {
      case 'low-bridge':
        return 'Low bridge';
      case 'no-truck':
        return 'No truck route';
      case 'weight-limit':
        return 'Weight limit';
      case 'width-restrict':
        return 'Width restriction';
      case 'construction':
        return 'Construction';
      case 'frost':
        return 'Frost law road';
      default:
        return type;
    }
  }
}

class HazardHit {
  const HazardHit({required this.hazard, required this.distanceM});
  final Hazard hazard;
  final double distanceM;
}

class Hazards {
  static Future<List<Hazard>> load() async {
    try {
      final String raw = await rootBundle.loadString('assets/hazards.json');
      final Map<String, dynamic> j = jsonDecode(raw) as Map<String, dynamic>;
      return (j['hazards'] as List<dynamic>)
          .map((dynamic e) => Hazard.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return <Hazard>[];
    }
  }

  /// Hazards whose radius the route passes through, nearest first.
  static List<HazardHit> onRoute(List<Hazard> hazards, List<Pt> route) {
    final List<HazardHit> hits = <HazardHit>[];
    for (final Hazard h in hazards) {
      final double d = distanceToPolylineM(h.lat, h.lng, route);
      if (d <= h.radiusM) hits.add(HazardHit(hazard: h, distanceM: d));
    }
    hits.sort((HazardHit a, HazardHit b) => a.distanceM.compareTo(b.distanceM));
    return hits;
  }
}
