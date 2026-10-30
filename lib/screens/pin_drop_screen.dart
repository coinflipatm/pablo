import 'package:flutter/material.dart';
import 'package:google_navigation_flutter/google_navigation_flutter.dart';

import '../destination.dart';

/// Full-screen map where the driver can drop a pin to set the destination.
///
/// Returns a [Destination] (lat/lng) when the user taps "Use this location",
/// or null if they cancel.
class PinDropScreen extends StatefulWidget {
  const PinDropScreen({
    super.key,
    this.initialLat,
    this.initialLng,
  });

  /// Optional: center the map here on open (driver's current location).
  final double? initialLat;
  final double? initialLng;

  @override
  State<PinDropScreen> createState() => _PinDropScreenState();
}

class _PinDropScreenState extends State<PinDropScreen> {
  GoogleNavigationViewController? _controller;
  LatLng? _pin;
  String _pinLabel = '';
  bool _reverseGeocoding = false;

  static const LatLng _defaultCenter = LatLng(43.0, -83.7); // Genesee County

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool hasPinned = _pin != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Drop a Pin'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(null),
        ),
      ),
      body: Stack(
        children: <Widget>[
          // ── Map ────────────────────────────────────────────────────────────
          GoogleMapsNavigationView(
            initialCameraPosition: CameraPosition(
              target: widget.initialLat != null && widget.initialLng != null
                  ? LatLng(widget.initialLat!, widget.initialLng!)
                  : _defaultCenter,
              zoom: widget.initialLat != null ? 13 : 9,
            ),
            initialMapType: MapType.normal,
            onViewCreated: _onViewCreated,
          ),

          // ── Centre crosshair ──────────────────────────────────────────────
          const Center(
            child: _Crosshair(),
          ),

          // ── Top instruction banner ─────────────────────────────────────────
          Positioned(
            top: 12,
            left: 16,
            right: 16,
            child: Card(
              color: const Color(0xE0181D26),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.touch_app_outlined,
                        size: 18,
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.6)),
                    const SizedBox(width: 8),
                    const Text(
                      'Tap the map or pan to place the pin',
                      style: TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Bottom confirm card ────────────────────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (hasPinned) ...<Widget>[
                      Card(
                        color: const Color(0xE0181D26),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  Icon(Icons.location_pin,
                                      color: theme.colorScheme.primary,
                                      size: 18),
                                  const SizedBox(width: 6),
                                  Text(
                                    '${_pin!.latitude.toStringAsFixed(5)}, '
                                    '${_pin!.longitude.toStringAsFixed(5)}',
                                    style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600),
                                  ),
                                  if (_reverseGeocoding) ...<Widget>[
                                    const SizedBox(width: 8),
                                    const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 1.5),
                                    ),
                                  ],
                                ],
                              ),
                              if (_pinLabel.isNotEmpty) ...<Widget>[
                                const SizedBox(height: 4),
                                Text(
                                  _pinLabel,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.7),
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _onPlacePin,
                            child: const Text('PIN HERE'),
                          ),
                        ),
                        if (hasPinned) ...<Widget>[
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: FilledButton(
                              onPressed: _onConfirm,
                              child: const Text('USE THIS LOCATION'),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onViewCreated(GoogleNavigationViewController c) async {
    _controller = c;
    // Show the driver's blue dot but keep navigation UI hidden.
    await c.setMyLocationEnabled(true);
    await c.setRecenterButtonEnabled(true);
    await c.setNavigationHeaderEnabled(false);
    await c.setNavigationFooterEnabled(false);
    await c.setSpeedometerEnabled(false);
    await c.setTrafficIncidentCardsEnabled(false);
    await c.setNavigationUIEnabled(false);
  }

  /// Drop a pin at the current map center.
  Future<void> _onPlacePin() async {
    final GoogleNavigationViewController? c = _controller;
    if (c == null) return;

    // Use the camera target (center of visible map) as the pin.
    final CameraPosition cam = await c.getCameraPosition();
    final LatLng pos = cam.target;

    setState(() {
      _pin = pos;
      _pinLabel = '';
      _reverseGeocoding = false;
    });

    // Add a marker.
    await c.clearMarkers();
    await c.addMarkers(<MarkerOptions>[
      MarkerOptions(
        position: pos,
        infoWindow: const InfoWindow(title: 'Destination'),
      ),
    ]);
  }

  void _onConfirm() {
    final LatLng? pin = _pin;
    if (pin == null) return;
    final Destination dest = Destination.latLng(
      pin.latitude,
      pin.longitude,
      label: _pinLabel.isNotEmpty
          ? _pinLabel
          : '${pin.latitude.toStringAsFixed(5)}, ${pin.longitude.toStringAsFixed(5)}',
    );
    Navigator.of(context).pop(dest);
  }
}

// ─── Crosshair overlay ────────────────────────────────────────────────────────

class _Crosshair extends StatelessWidget {
  const _Crosshair();

  @override
  Widget build(BuildContext context) {
    final Color c = Theme.of(context).colorScheme.primary;
    return IgnorePointer(
      child: SizedBox(
        width: 40,
        height: 40,
        child: CustomPaint(painter: _CrosshairPainter(c)),
      ),
    );
  }
}

class _CrosshairPainter extends CustomPainter {
  _CrosshairPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final double cx = size.width / 2;
    final double cy = size.height / 2;
    final double arm = 10;
    final double gap = 4;
    // Horizontal arms
    canvas.drawLine(Offset(cx - arm - gap, cy), Offset(cx - gap, cy), p);
    canvas.drawLine(Offset(cx + gap, cy), Offset(cx + arm + gap, cy), p);
    // Vertical arms
    canvas.drawLine(Offset(cx, cy - arm - gap), Offset(cx, cy - gap), p);
    canvas.drawLine(Offset(cx, cy + gap), Offset(cx, cy + arm + gap), p);
    // Centre dot
    canvas.drawCircle(Offset(cx, cy), 2.5,
        Paint()..color = color..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(_CrosshairPainter old) => old.color != color;
}
