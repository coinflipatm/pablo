import 'package:http/http.dart' as http;

import 'intent_channel.dart';

/// Where the driver is going. Either free text (an address Routes API will
/// geocode) or a coordinate, with a label for display.
class Destination {
  const Destination._({required this.label, this.address, this.lat, this.lng});

  factory Destination.address(String text) {
    final String t = text.trim();
    return Destination._(label: t, address: t);
  }

  factory Destination.latLng(double lat, double lng, {String? label}) {
    return Destination._(
      label: label ?? '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
      lat: lat,
      lng: lng,
    );
  }

  final String label;
  final String? address;
  final double? lat;
  final double? lng;

  bool get hasLatLng => lat != null && lng != null;

  @override
  String toString() => 'Destination($label)';
}

/// Turns whatever Towbook, Maps, or a share sheet handed us into a Destination.
class DestinationParser {
  static final RegExp _coords =
      RegExp(r'^\s*(-?\d{1,3}(?:\.\d+)?)\s*,\s*(-?\d{1,3}(?:\.\d+)?)\s*$');
  static final RegExp _coordsWithLabel =
      RegExp(r'^\s*(-?\d{1,3}(?:\.\d+)?)\s*,\s*(-?\d{1,3}(?:\.\d+)?)\s*\((.+)\)\s*$');
  static final RegExp _url = RegExp(r'https?://\S+');
  static final RegExp _atCoords = RegExp(r'@(-?\d{1,3}\.\d+),(-?\d{1,3}\.\d+)');

  static Future<Destination?> fromIntent(IncomingIntent intent) async {
    final String? data = intent.data?.trim();
    if (data != null && data.isNotEmpty) {
      final Destination? d = await fromString(data);
      if (d != null) return d;
    }
    final String? text = intent.text?.trim();
    if (text != null && text.isNotEmpty) {
      return fromString(text);
    }
    return null;
  }

  /// Accepts a URI, a URL buried in text, bare coordinates, or an address.
  static Future<Destination?> fromString(String raw) async {
    final String s = raw.trim();
    if (s.isEmpty) return null;

    final Destination? coord = _parseCoords(s);
    if (coord != null) return coord;

    final RegExpMatch? urlMatch = _url.firstMatch(s);
    if (urlMatch != null && !s.startsWith('geo:') && !s.startsWith('google.navigation:')) {
      final Destination? fromUrl = await _fromHttp(urlMatch.group(0)!);
      if (fromUrl != null) return fromUrl;
      // A link we couldn't read: use any text around it.
      final String rest = s.replaceFirst(_url, '').trim();
      return rest.isEmpty ? null : Destination.address(rest);
    }

    if (s.startsWith('geo:')) return _fromGeo(s);
    if (s.startsWith('google.navigation:')) return _fromGoogleNavigation(s);

    return Destination.address(s);
  }

  static Destination? _parseCoords(String s) {
    final RegExpMatch? m = _coords.firstMatch(s);
    if (m != null) {
      final double? lat = double.tryParse(m.group(1)!);
      final double? lng = double.tryParse(m.group(2)!);
      if (lat != null && lng != null && _plausible(lat, lng)) {
        return Destination.latLng(lat, lng);
      }
    }
    final RegExpMatch? ml = _coordsWithLabel.firstMatch(s);
    if (ml != null) {
      final double? lat = double.tryParse(ml.group(1)!);
      final double? lng = double.tryParse(ml.group(2)!);
      if (lat != null && lng != null && _plausible(lat, lng)) {
        return Destination.latLng(lat, lng, label: ml.group(3)!.trim());
      }
    }
    return null;
  }

  static bool _plausible(double lat, double lng) =>
      lat.abs() <= 90 && lng.abs() <= 180 && !(lat == 0 && lng == 0);

  /// geo:lat,lng?q=...   geo:0,0?q=address   geo:lat,lng?z=15
  static Destination? _fromGeo(String s) {
    final String body = s.substring('geo:'.length);
    final int q = body.indexOf('?');
    final String coordPart = q >= 0 ? body.substring(0, q) : body;
    final Map<String, String> params =
        q >= 0 ? _splitQuery(body.substring(q + 1)) : <String, String>{};

    final String? query = params['q'];
    if (query != null && query.trim().isNotEmpty) {
      final Destination? asCoords = _parseCoords(query);
      if (asCoords != null) return asCoords;
      return Destination.address(query);
    }
    return _parseCoords(coordPart);
  }

  /// google.navigation:q=address   google.navigation:q=lat,lng&mode=d
  static Destination? _fromGoogleNavigation(String s) {
    final String body = s.substring('google.navigation:'.length);
    final Map<String, String> params = _splitQuery(body.startsWith('?') ? body.substring(1) : body);
    final String? query = params['q'];
    if (query == null || query.trim().isEmpty) return null;
    return _parseCoords(query) ?? Destination.address(query);
  }

  static Future<Destination?> _fromHttp(String url) async {
    Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return null;
    }
    uri = await _resolveShortLink(uri);

    final Map<String, String> qp = uri.queryParameters;
    for (final String key in <String>['destination', 'daddr', 'q', 'query', 'll']) {
      final String? v = qp[key];
      if (v != null && v.trim().isNotEmpty) {
        return _parseCoords(v) ?? Destination.address(v);
      }
    }

    final List<String> segs = uri.pathSegments.where((String p) => p.isNotEmpty).toList();
    final int mapsIdx = segs.indexOf('maps');
    if (mapsIdx >= 0 && segs.length > mapsIdx + 1) {
      final String kind = segs[mapsIdx + 1];
      final List<String> rest = segs
          .sublist(mapsIdx + 2)
          .where((String p) => !p.startsWith('@') && !p.startsWith('data='))
          .toList();
      if (kind == 'dir' && rest.isNotEmpty) {
        return _fromPathSegment(rest.last);
      }
      if ((kind == 'place' || kind == 'search') && rest.isNotEmpty) {
        return _fromPathSegment(rest.first);
      }
    }

    final RegExpMatch? at = _atCoords.firstMatch(uri.toString());
    if (at != null) {
      final double? lat = double.tryParse(at.group(1)!);
      final double? lng = double.tryParse(at.group(2)!);
      if (lat != null && lng != null && _plausible(lat, lng)) {
        return Destination.latLng(lat, lng);
      }
    }
    return null;
  }

  static Destination? _fromPathSegment(String seg) {
    final String decoded = Uri.decodeComponent(seg.replaceAll('+', ' ')).trim();
    if (decoded.isEmpty) return null;
    return _parseCoords(decoded) ?? Destination.address(decoded);
  }

  /// Follows maps.app.goo.gl / goo.gl redirects without downloading the page.
  static Future<Uri> _resolveShortLink(Uri uri) async {
    final Set<String> shortHosts = <String>{'maps.app.goo.gl', 'goo.gl', 'g.co'};
    if (!shortHosts.contains(uri.host)) return uri;

    Uri current = uri;
    final http.Client client = http.Client();
    try {
      for (int i = 0; i < 5; i++) {
        final http.Request req = http.Request('GET', current)..followRedirects = false;
        final http.StreamedResponse res =
            await client.send(req).timeout(const Duration(seconds: 6));
        final String? loc = res.headers['location'];
        if (res.statusCode >= 300 && res.statusCode < 400 && loc != null) {
          current = current.resolve(loc);
          continue;
        }
        break;
      }
    } catch (_) {
      // Offline or blocked: fall through with whatever we have.
    } finally {
      client.close();
    }
    return current;
  }

  static Map<String, String> _splitQuery(String q) {
    try {
      return Uri.splitQueryString(q);
    } catch (_) {
      return <String, String>{};
    }
  }
}
