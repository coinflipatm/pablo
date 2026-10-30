import 'dart:math' as math;

class Pt {
  const Pt(this.lat, this.lng);
  final double lat;
  final double lng;
}

/// Google encoded polyline (precision 5) decoder.
List<Pt> decodePolyline(String encoded) {
  final List<Pt> out = <Pt>[];
  int index = 0;
  int lat = 0;
  int lng = 0;
  while (index < encoded.length) {
    int shift = 0;
    int result = 0;
    int b;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

    shift = 0;
    result = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

    out.add(Pt(lat / 1e5, lng / 1e5));
  }
  return out;
}

/// Great-circle distance in meters.
double haversineM(double lat1, double lng1, double lat2, double lng2) {
  const double r = 6371000.0;
  final double dLat = _rad(lat2 - lat1);
  final double dLng = _rad(lng2 - lng1);
  final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * math.sin(dLng / 2) * math.sin(dLng / 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

double _rad(double deg) => deg * math.pi / 180.0;

/// Shortest distance in meters from a point to a polyline (segment-aware, so a
/// hazard between two sparse vertices is still caught).
double distanceToPolylineM(double lat, double lng, List<Pt> line) {
  if (line.isEmpty) return double.infinity;
  if (line.length == 1) return haversineM(lat, lng, line[0].lat, line[0].lng);
  double best = double.infinity;
  for (int i = 0; i < line.length - 1; i++) {
    final double d = _distToSegmentM(lat, lng, line[i], line[i + 1]);
    if (d < best) best = d;
  }
  return best;
}

double _distToSegmentM(double lat, double lng, Pt a, Pt b) {
  // Equirectangular projection around the point: fine at segment scale.
  final double cosLat = math.cos(_rad(lat));
  final double ax = (a.lng - lng) * cosLat;
  final double ay = a.lat - lat;
  final double bx = (b.lng - lng) * cosLat;
  final double by = b.lat - lat;
  final double dx = bx - ax;
  final double dy = by - ay;
  final double len2 = dx * dx + dy * dy;
  double t = 0;
  if (len2 > 0) {
    t = (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0).toDouble();
  }
  final double px = ax + t * dx;
  final double py = ay + t * dy;
  final double degDist = math.sqrt(px * px + py * py);
  return degDist * 111320.0;
}
