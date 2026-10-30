import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

/// A single autocomplete prediction from the Places API.
class PlacePrediction {
  const PlacePrediction({
    required this.placeId,
    required this.mainText,
    required this.secondaryText,
    required this.fullText,
  });

  factory PlacePrediction.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> sf =
        (json['structured_formatting'] as Map<String, dynamic>?) ??
            <String, dynamic>{};
    return PlacePrediction(
      placeId: json['place_id'] as String? ?? '',
      mainText: sf['main_text'] as String? ??
          json['description'] as String? ??
          '',
      secondaryText: sf['secondary_text'] as String? ?? '',
      fullText: json['description'] as String? ?? '',
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

/// Wraps the Places Autocomplete + Place Details APIs.
///
/// Uses session tokens so autocomplete + detail calls are billed as one lookup.
class PlacesAutocomplete {
  PlacesAutocomplete({required this.apiKey});

  final String apiKey;
  String _sessionToken = _newToken();

  static String _newToken() {
    final Random r = Random();
    return List<String>.generate(
            4, (_) => r.nextInt(0x10000).toRadixString(16).padLeft(4, '0'))
        .join('-');
  }

  /// Returns up to 5 predictions for [input], biased toward [lat]/[lng].
  /// Returns an empty list on error or when the API is not enabled.
  Future<List<PlacePrediction>> suggest(
    String input, {
    double? lat,
    double? lng,
  }) async {
    final String q = input.trim();
    if (q.length < 2) return <PlacePrediction>[];

    final Map<String, String> params = <String, String>{
      'input': q,
      'key': apiKey,
      'sessiontoken': _sessionToken,
      'language': 'en',
      'components': 'country:us',
    };
    if (lat != null && lng != null) {
      params['location'] = '$lat,$lng';
      params['radius'] = '200000'; // 200 km bias — enough for any Michigander
    }

    try {
      final Uri uri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/place/autocomplete/json',
        params,
      );
      final http.Response resp =
          await http.get(uri).timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return <PlacePrediction>[];
      final Map<String, dynamic> body =
          json.decode(resp.body) as Map<String, dynamic>;
      final String status = body['status'] as String? ?? '';
      if (status != 'OK' && status != 'ZERO_RESULTS') return <PlacePrediction>[];
      return (body['predictions'] as List<dynamic>)
          .map((dynamic p) =>
              PlacePrediction.fromJson(p as Map<String, dynamic>))
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
        'maps.googleapis.com',
        '/maps/api/place/details/json',
        <String, String>{
          'place_id': placeId,
          'key': apiKey,
          'fields': 'geometry,formatted_address',
          'sessiontoken': token,
        },
      );
      final http.Response resp =
          await http.get(uri).timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) return null;
      final Map<String, dynamic> body =
          json.decode(resp.body) as Map<String, dynamic>;
      if (body['status'] != 'OK') return null;
      final Map<String, dynamic> result =
          body['result'] as Map<String, dynamic>;
      final Map<String, dynamic> loc =
          ((result['geometry'] as Map<String, dynamic>)['location'])
              as Map<String, dynamic>;
      return PlaceDetail(
        lat: (loc['lat'] as num).toDouble(),
        lng: (loc['lng'] as num).toDouble(),
        formattedAddress: result['formatted_address'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}
