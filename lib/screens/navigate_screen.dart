import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_navigation_flutter/google_navigation_flutter.dart';

import '../destination.dart';
import '../hazards.dart';
import '../profiles.dart';
import '../routes_api.dart';
import '../units.dart';

/// Google's own turn-by-turn, locked to the route token Pablo computed for
/// this unit. Reroutes keep the truck profile because the token carries it.
class NavigateScreen extends StatefulWidget {
  const NavigateScreen({
    super.key,
    required this.route,
    required this.destination,
    required this.combination,
    required this.hazardHits,
  });

  final RouteResult route;
  final Destination destination;
  final Combination combination;
  final List<HazardHit> hazardHits;

  @override
  State<NavigateScreen> createState() => _NavigateScreenState();
}

class _NavigateScreenState extends State<NavigateScreen> {
  StreamSubscription<RoadSnappedLocationUpdatedEvent>? _locationSub;
  Timer? _locationFallback;

  bool _sessionInitialized = false;
  bool _settingDestinations = false;
  bool _guidanceRunning = false;
  String? _status = 'Starting navigation…';
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _locationFallback?.cancel();
    _locationSub?.cancel();
    if (_sessionInitialized) {
      GoogleMapsNavigator.cleanup();
    }
    super.dispose();
  }

  Future<void> _start() async {
    try {
      if (!await GoogleMapsNavigator.areTermsAccepted()) {
        final bool ok = await GoogleMapsNavigator.showTermsAndConditionsDialog('Pablo', 'towtruck.cv');
        if (!ok) {
          _fail('Google navigation terms were not accepted.');
          return;
        }
      }
      await GoogleMapsNavigator.initializeNavigationSession(
        notificationOptions: const NavigationNotificationOptions(resumeAppOnTap: true),
      );
      _sessionInitialized = true;

      // Routing is only possible once the SDK has a fix. Wait for the first
      // road-snapped location, with a timeout so a weak signal doesn't hang us.
      _locationSub = await GoogleMapsNavigator.setRoadSnappedLocationUpdatedListener(
        (RoadSnappedLocationUpdatedEvent _) => _setDestinations(),
      );
      _locationFallback = Timer(const Duration(seconds: 12), _setDestinations);
      if (mounted) setState(() => _status = 'Waiting for GPS…');
    } on SessionInitializationException catch (e) {
      switch (e.code) {
        case SessionInitializationError.termsNotAccepted:
          _fail('Google navigation terms were not accepted.');
        case SessionInitializationError.locationPermissionMissing:
          _fail('Location permission is missing.');
        case SessionInitializationError.notAuthorized:
          _fail('This build\'s Maps API key is not authorized for Navigation SDK.');
      }
    } catch (e) {
      _fail('Could not start navigation: $e');
    }
  }

  Future<void> _setDestinations() async {
    if (_settingDestinations || _guidanceRunning || !_sessionInitialized) return;
    _settingDestinations = true;
    _locationFallback?.cancel();
    if (mounted) setState(() => _status = 'Loading route…');

    try {
      final NavigationRouteStatus status = await GoogleMapsNavigator.setDestinations(
        Destinations(
          waypoints: <NavigationWaypoint>[
            NavigationWaypoint.withLatLngTarget(
              title: widget.destination.label,
              target: LatLng(latitude: widget.route.endLat, longitude: widget.route.endLng),
            ),
          ],
          displayOptions: NavigationDisplayOptions(showDestinationMarkers: true),
          routeTokenOptions: RouteTokenOptions(
            routeToken: widget.route.token,
            travelMode: NavigationTravelMode.driving,
          ),
        ),
      );

      if (status == NavigationRouteStatus.statusOk) {
        await GoogleMapsNavigator.startGuidance();
        await _locationSub?.cancel();
        _locationSub = null;
        if (mounted) {
          setState(() {
            _guidanceRunning = true;
            _status = null;
          });
        }
      } else {
        _settingDestinations = false;
        _fail('Google rejected the route: ${status.name}.');
      }
    } catch (e) {
      _settingDestinations = false;
      _fail('Could not load the route: $e');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _status = null;
    });
  }

  Future<void> _onViewCreated(GoogleNavigationViewController controller) async {
    await controller.setMyLocationEnabled(true);
  }

  Future<void> _stopAndLeave() async {
    try {
      if (_guidanceRunning) await GoogleMapsNavigator.stopGuidance();
      await GoogleMapsNavigator.clearDestinations();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final RouteResult r = widget.route;
    final bool fellBack = r.fallbackReason != null;
    final List<String> warnings = <String>[
      if (fellBack)
        'Truck routing refused, routed like a CAR. Watch for low bridges and weight limits. '
            '(${r.fallbackReason})',
      ...r.warnings,
    ];

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) _stopAndLeave();
      },
      child: Scaffold(
        body: Column(
          children: <Widget>[
            Material(
              color: theme.appBarTheme.backgroundColor,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(
                            r.truckMode ? Icons.local_shipping : Icons.directions_car,
                            size: 18,
                            color: r.truckMode ? theme.colorScheme.primary : theme.colorScheme.error,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${r.truckMode ? 'TRUCK' : 'CAR'} · ${Units.miles(r.distanceMeters)} · '
                              '${Units.duration(r.durationSeconds)}',
                              style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.5),
                            ),
                          ),
                          TextButton(
                            onPressed: _stopAndLeave,
                            child: const Text('END'),
                          ),
                        ],
                      ),
                      Text(
                        widget.combination.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (warnings.isNotEmpty) _Banner(color: theme.colorScheme.error, lines: warnings),
            if (widget.hazardHits.isNotEmpty)
              _Banner(
                color: const Color(0xFFF59E0B),
                lines: widget.hazardHits
                    .map((HazardHit h) =>
                        '${h.hazard.typeLabel} on route (${h.distanceM.round()} m): ${h.hazard.note}')
                    .toList(),
              ),
            if (_status != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                color: theme.colorScheme.surfaceContainerHighest,
                child: Row(
                  children: <Widget>[
                    const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                    Text(_status!),
                  ],
                ),
              ),
            if (_error != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                color: theme.colorScheme.error.withValues(alpha: 0.15),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(_error!, style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    OutlinedButton(onPressed: _stopAndLeave, child: const Text('Back')),
                  ],
                ),
              ),
            Expanded(
              child: GoogleMapsNavigationView(
                onViewCreated: _onViewCreated,
                initialNavigationUIEnabledPreference: NavigationUIEnabledPreference.automatic,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.color, required this.lines});
  final Color color;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border(left: BorderSide(color: color, width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final String l in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(l, style: const TextStyle(fontSize: 13, height: 1.3)),
            ),
        ],
      ),
    );
  }
}
