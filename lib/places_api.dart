import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

/// A single autocomplete prediction from Places API (New).
class PlacePrediction {
  const PlacePrediction({
    required this.placeId,
    required this.mainText,
    required this.secondaryText,
    required this.fullText,
  });

  factory PlacePrediction.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> pp =
        (json['placePrediction'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final Map<String, dynamic> sf =
        (pp['structuredFormat'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    String text(Map<String, dynamic>? m) =>
        (m?['text'] as String?) ?? '';
    final String full = text(pp['text'] as Map<String, dynamic>?);
    final String main = text(sf['mainText'] as Map<String, dynamic>?);
    return PlacePrediction(
      placeId: pp['placeId'] as String? ?? '',
      mainText: main.isEmpty ? full : main,
      secondaryText: text(sf['secondaryText'] as Map<String, dynamic>?),
      fullText: full,
    );
  }

  final String placeId;
  final String mainText;
  final String secondaryText;
  final String fullText;
}

/// Lat/lng + formatted address returned by place details.
class PlaceDetail {
  const PlaceDetail({
    required this.lat,
    required this.lng,
    required this.formattedAddress,
  });

  final double lat;
  final double lng;
  final String formattedAddress;
}

/// Wraps Places API (New): Autocomplete + Place Details.
///
/// Uses session tokens so autocomplete + detail calls are billed as one lookup.
/// [androidPackage]/[androidCertSha1] are sent so an Android-restricted key
/// still works from plain HTTP calls.
class PlacesAutocomplete {
  PlacesAutocomplete({
    required this.apiKey,
    this.androidPackage,
    this.androidCertSha1,
  });

  final String apiKey;
  final String? androidPackage;
  final String? androidCertSha1;
  String _sessionToken = _newToken();

  static final Random _rng = Random();

  /// UUID-v4-shaped token, which is what the New API expects.
  static String _newToken() {
    String hex(int n) => List<String>.generate(
            n, (_) => _rng.nextInt(16).toRadixString(16))
        .join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-'
        '${(8 + _rng.nextInt(4)).toRadixString(16)}${hex(3)}-${hex(12)}';
  }

  Map<String, String> _headers({String? fieldMask}) {
    final Map<String, String> h = <String, String>{
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': apiKey,
    };
    if (fieldMask != null) h['X-Goog-FieldMask'] = fieldMask;
    if (androidPackage != null) h['X-Android-Package'] = androidPackage!;
    if (androidCertSha1 != null) {
      h['X-Android-Cert'] = androidCertSha1!.replaceAll(':', '');
    }
    return h;
  }

  /// Returns up to 5 predictions for [input], biased toward [lat]/[lng].
  /// Returns an empty list on error or when the API is not enabled.
  Future<List<PlacePrediction>> suggest(
    String input, {
    double? lat,
    double? lng,
  }) async {
    final String q = input.trim();
    if (q.length < 2 || apiKey.isEmpty) return <PlacePrediction>[];

    final Map<String, dynamic> body = <String, dynamic>{
      'input': q,
      'sessionToken': _sessionToken,
      'languageCode': 'en',
      'includedRegionCodes': <String>['us'],
    };
    if (lat != null && lng != null) {
      body['locationBias'] = <String, dynamic>{
        'circle': <String, dynamic>{
          'center': <String, dynamic>{'latitude': lat, 'longitude': lng},
          'radius': 50000.0, // API max; bias only, not a hard limit
        },
      };
    }

    try {
      final http.Response resp = await http
          .post(
            Uri.parse('https://places.googleapis.com/v1/places:autocomplete'),
            headers: _headers(),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return <PlacePrediction>[];
      final Map<String, dynamic> j =
          json.decode(resp.body) as Map<String, dynamic>;
      final List<dynamic> suggestions =
          (j['suggestions'] as List<dynamic>?) ?? <dynamic>[];
      return suggestions
          .whereType<Map<String, dynamic>>()
          .where((Map<String, dynamic> s) => s.containsKey('placePrediction'))
          .map(PlacePrediction.fromJson)
          .where((PlacePrediction p) => p.placeId.isNotEmpty)
          .take(5)
          .toList();
    } catch (_) {
      return <PlacePrediction>[];
    }
  }

  /// Fetches coordinates + formatted address for [placeId].
  /// Resets the session token after the call (billing session ends).
  Future<PlaceDetail?> detail(String placeId) async {
    final String token = _sessionToken;
    _sessionToken = _newToken(); // Always reset — whether the call succeeds or not.

    try {
      final Uri uri = Uri.https(
        'places.googleapis.com',
        '/v1/places/$placeId',
        <String, String>{'sessionToken': token, 'languageCode': 'en'},
      );
      final http.Response resp = await http
          .get(uri, headers: _headers(fieldMask: 'location,formattedAddress'))
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) return null;
      final Map<String, dynamic> j =
          json.decode(resp.body) as Map<String, dynamic>;
      final Map<String, dynamic>? loc = j['location'] as Map<String, dynamic>?;
      if (loc == null) return null;
      return PlaceDetail(
        lat: (loc['latitude'] as num).toDouble(),
        lng: (loc['longitude'] as num).toDouble(),
        formattedAddress: j['formattedAddress'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}
