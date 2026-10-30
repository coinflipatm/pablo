import 'dart:convert';

import 'package:http/http.dart' as http;

import 'destination.dart';
import 'polyline.dart';
import 'profiles.dart';

class RoutesApiException implements Exception {
  RoutesApiException(this.message, {this.status, this.httpCode});
  final String message;
  final String? status;
  final int? httpCode;

  @override
  String toString() => message;
}

class RouteResult {
  const RouteResult({
    required this.token,
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.warnings,
    required this.endLat,
    required this.endLng,
    required this.truckMode,
    this.fallbackReason,
  });

  final String token;
  final List<Pt> points;
  final int distanceMeters;
  final int durationSeconds;
  final List<String> warnings;
  final double endLat;
  final double endLng;

  /// True when Google computed this with travelMode TRUCK and the unit's
  /// dimensions. False means it was routed like a car.
  final bool truckMode;

  /// Set when truck routing was requested but Google refused it and Pablo fell
  /// back to car routing. Shown to the driver as a warning.
  final String? fallbackReason;

  RouteResult withFallback(String reason) => RouteResult(
        token: token,
        points: points,
        distanceMeters: distanceMeters,
        durationSeconds: durationSeconds,
        warnings: warnings,
        endLat: endLat,
        endLng: endLng,
        truckMode: truckMode,
        fallbackReason: reason,
      );
}

/// Thin client for Google Routes API computeRoutes. Large Vehicle Routing is
/// just travelMode TRUCK plus routeModifiers.vehicleInfo on the same endpoint.
class RoutesApi {
  RoutesApi({required this.apiKey, this.androidPackage, this.androidCertSha1});

  static const String _endpoint = 'https://routes.googleapis.com/directions/v2:computeRoutes';
  static const String _fieldMask =
      'routes.routeToken,routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline,'
      'routes.warnings,routes.routeLabels,routes.legs.endLocation';

  final String apiKey;
  final String? androidPackage;
  final String? androidCertSha1;

  Future<RouteResult> compute({
    required double originLat,
    required double originLng,
    required Destination destination,
    required Combination combination,
  }) async {
    if (apiKey.isEmpty) {
      throw RoutesApiException('No Maps API key in this build (MAPS_API_KEY).');
    }

    if (!combination.truckMode) {
      return _call(originLat, originLng, destination, 'DRIVE', null);
    }

    String? fallback;
    try {
      return await _call(originLat, originLng, destination, 'TRUCK', combination.vehicleInfo);
    } on RoutesApiException catch (e) {
      fallback = e.message;
    }
    final RouteResult car = await _call(originLat, originLng, destination, 'DRIVE', null);
    return car.withFallback(fallback);
  }

  Future<RouteResult> _call(
    double originLat,
    double originLng,
    Destination destination,
    String travelMode,
    Map<String, dynamic>? vehicleInfo,
  ) async {
    final Map<String, dynamic> dest = destination.hasLatLng
        ? <String, dynamic>{
            'location': <String, dynamic>{
              'latLng': <String, dynamic>{'latitude': destination.lat, 'longitude': destination.lng},
            },
          }
        : <String, dynamic>{'address': destination.address};

    final Map<String, dynamic> body = <String, dynamic>{
      'origin': <String, dynamic>{
        'location': <String, dynamic>{
          'latLng': <String, dynamic>{'latitude': originLat, 'longitude': originLng},
        },
      },
      'destination': dest,
      'travelMode': travelMode,
      // Required for route tokens, and the only mode that honours truck restrictions.
      'routingPreference': 'TRAFFIC_AWARE_OPTIMAL',
      'polylineQuality': 'HIGH_QUALITY',
      'languageCode': 'en-US',
      'units': 'IMPERIAL',
      if (vehicleInfo != null) 'routeModifiers': <String, dynamic>{'vehicleInfo': vehicleInfo},
    };

    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': apiKey,
      'X-Goog-FieldMask': _fieldMask,
      if (androidPackage != null) 'X-Android-Package': androidPackage!,
      if (androidCertSha1 != null) 'X-Android-Cert': androidCertSha1!.replaceAll(':', ''),
    };

    http.Response res;
    try {
      res = await http
          .post(Uri.parse(_endpoint), headers: headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw RoutesApiException('Network error talking to Google: $e');
    }

    Map<String, dynamic> j;
    try {
      j = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw RoutesApiException('Unreadable response from Google (HTTP ${res.statusCode}).',
          httpCode: res.statusCode);
    }

    if (res.statusCode != 200) {
      final Map<String, dynamic>? err = j['error'] as Map<String, dynamic>?;
      final String msg = (err?['message'] as String?) ?? 'HTTP ${res.statusCode}';
      final String? status = err?['status'] as String?;
      throw RoutesApiException('$travelMode routing refused: $msg', status: status, httpCode: res.statusCode);
    }

    final List<dynamic> routes = (j['routes'] as List<dynamic>?) ?? <dynamic>[];
    if (routes.isEmpty) {
      throw RoutesApiException('$travelMode routing found no route to "${destination.label}".');
    }
    final Map<String, dynamic> r = routes.first as Map<String, dynamic>;

    final String? token = r['routeToken'] as String?;
    if (token == null || token.isEmpty) {
      throw RoutesApiException('Google returned a route without a route token.');
    }

    final String encoded = ((r['polyline'] as Map<String, dynamic>?)?['encodedPolyline'] as String?) ?? '';
    final List<Pt> points = encoded.isEmpty ? <Pt>[] : decodePolyline(encoded);

    final List<dynamic> legs = (r['legs'] as List<dynamic>?) ?? <dynamic>[];
    double? endLat;
    double? endLng;
    if (legs.isNotEmpty) {
      final Map<String, dynamic>? latLng =
          (((legs.last as Map<String, dynamic>)['endLocation'] as Map<String, dynamic>?)?['latLng']
              as Map<String, dynamic>?);
      endLat = (latLng?['latitude'] as num?)?.toDouble();
      endLng = (latLng?['longitude'] as num?)?.toDouble();
    }
    if ((endLat == null || endLng == null) && points.isNotEmpty) {
      endLat = points.last.lat;
      endLng = points.last.lng;
    }
    if (endLat == null || endLng == null) {
      throw RoutesApiException('Google did not say where the route ends.');
    }

    final List<String> warnings = ((r['warnings'] as List<dynamic>?) ?? <dynamic>[])
        .map((dynamic w) => w.toString())
        .toList();
    final List<String> labels = ((r['routeLabels'] as List<dynamic>?) ?? <dynamic>[])
        .map((dynamic w) => w.toString())
        .toList();
    for (final String l in labels) {
      if (l.contains('RESTRICTION')) warnings.add('Google: $l');
    }

    return RouteResult(
      token: token,
      points: points,
      distanceMeters: ((r['distanceMeters'] as num?) ?? 0).toInt(),
      durationSeconds: _parseDuration(r['duration']),
      warnings: warnings,
      endLat: endLat,
      endLng: endLng,
      truckMode: travelMode == 'TRUCK',
    );
  }

  static int _parseDuration(dynamic d) {
    if (d == null) return 0;
    final String s = d.toString();
    return int.tryParse(s.endsWith('s') ? s.substring(0, s.length - 1) : s) ?? 0;
  }
}
