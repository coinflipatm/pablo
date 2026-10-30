import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  /// Talks to MainActivity: we say when a route is live, it says when the
  /// app has shrunk into (or grown out of) the picture-in-picture window.
  static const MethodChannel _pip = MethodChannel('cv.towtruck.pablo/pip');

  StreamSubscription<RoadSnappedLocationUpdatedEvent>? _locationSub;
  StreamSubscription<NavInfoEvent>? _navInfoSub;
  final ValueNotifier<NavInfo?> _navInfo = ValueNotifier<NavInfo?>(null);
  Timer? _locationFallback;
  GoogleNavigationViewController? _controller;
  bool _inPip = false;

  bool _sessionInitialized = false;
  bool _settingDestinations = false;
  bool _guidanceRunning = false;
  String? _status = 'Starting navigation…';
  String? _error;

  @override
  void initState() {
    super.initState();
    _pip.setMethodCallHandler(_onPipCall);
    _start();
  }

  @override
  void dispose() {
    _setNavigating(false);
    _pip.setMethodCallHandler(null);
    _navInfoSub?.cancel();
    _navInfo.dispose();
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
        _navInfoSub ??= GoogleMapsNavigator.setNavInfoListener(
          (NavInfoEvent e) => _navInfo.value = e.navInfo,
          numNextStepsToPreview: 0,
        );
        _setNavigating(true);
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
    _controller = controller;
    await controller.setMyLocationEnabled(true);
  }

  void _setNavigating(bool on) {
    _pip.invokeMethod<void>('setNavigating', on).catchError((Object _) {});
  }

  Future<void> _onPipCall(MethodCall call) async {
    if (call.method != 'pipChanged') return;
    final bool pip = call.arguments == true;
    if (!mounted) return;
    setState(() => _inPip = pip);
    await _applyPipChrome(pip);
  }

  /// In the mini window Google's big header/footer and buttons would cover the
  /// whole map, so hide them and show our one-line turn strip instead.
  Future<void> _applyPipChrome(bool pip) async {
    final GoogleNavigationViewController? c = _controller;
    if (c == null) return;
    final List<Future<void> Function()> steps = <Future<void> Function()>[
      () => c.setNavigationHeaderEnabled(!pip),
      () => c.setNavigationFooterEnabled(!pip),
      () => c.setRecenterButtonEnabled(!pip),
      () => c.setReportIncidentButtonEnabled(!pip),
      () => c.settings.setCompassEnabled(!pip),
      if (pip) () => c.followMyLocation(CameraPerspective.tilted),
    ];
    for (final Future<void> Function() step in steps) {
      try {
        await step();
      } catch (_) {}
    }
  }

  Future<void> _stopAndLeave() async {
    _setNavigating(false);
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
            if (!_inPip) ...<Widget>[
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
            ],
            Expanded(
              key: const ValueKey<String>('map'),
              // SafeArea keeps Google's bottom bar above the phone's
              // back/home buttons instead of underneath them.
              child: SafeArea(
                top: false,
                child: GoogleMapsNavigationView(
                  onViewCreated: _onViewCreated,
                  initialNavigationUIEnabledPreference: NavigationUIEnabledPreference.automatic,
                ),
              ),
            ),
            if (_inPip)
              ValueListenableBuilder<NavInfo?>(
                valueListenable: _navInfo,
                builder: (BuildContext context, NavInfo? info, Widget? _) => _PipStrip(info: info),
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

/// Next-turn strip shown under the map in the picture-in-picture window.
class _PipStrip extends StatelessWidget {
  const _PipStrip({required this.info});
  final NavInfo? info;

  @override
  Widget build(BuildContext context) {
    final StepInfo? step = info?.currentStep;
    final int? meters = info?.distanceToCurrentStepMeters;
    final int? secs = info?.timeToFinalDestinationSeconds;
    final String? exit = step?.exitNumber;
    final String road = (exit != null && exit.isNotEmpty)
        ? 'Exit $exit'
        : (step?.simpleRoadName ?? step?.fullRoadName ?? '');
    final String eta = secs == null
        ? ''
        : TimeOfDay.fromDateTime(DateTime.now().add(Duration(seconds: secs))).format(context);
    final String sub = <String>[
      if (meters != null) _distance(meters),
      if (eta.isNotEmpty) eta,
    ].join(' · ');

    return Container(
      width: double.infinity,
      color: const Color(0xFF0B5E5A),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: <Widget>[
          Icon(_maneuverIcon(step?.maneuver), color: Colors.white, size: 30),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  road.isEmpty ? sub : road,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
                ),
                if (road.isNotEmpty && sub.isNotEmpty)
                  Text(
                    sub,
                    maxLines: 1,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _distance(int meters) {
    final double feet = meters * 3.28084;
    if (feet < 1000) return '${(feet / 50).round() * 50} ft';
    return Units.miles(meters);
  }

  static IconData _maneuverIcon(Maneuver? m) {
    if (m == null) return Icons.navigation;
    final String n = m.name;
    final bool left = n.contains('Left') || n.contains('Counterclockwise');
    if (n.startsWith('destination')) return Icons.flag;
    if (n.contains('UTurn')) return left ? Icons.u_turn_left : Icons.u_turn_right;
    if (n.startsWith('roundabout')) return left ? Icons.roundabout_left : Icons.roundabout_right;
    if (n.startsWith('merge')) return Icons.merge;
    if (n.startsWith('fork')) return left ? Icons.fork_left : Icons.fork_right;
    if (n.startsWith('offRamp') || n.startsWith('onRamp')) return left ? Icons.ramp_left : Icons.ramp_right;
    if (n.contains('Sharp')) return left ? Icons.turn_sharp_left : Icons.turn_sharp_right;
    if (n.contains('Slight') || n.contains('Keep')) return left ? Icons.turn_slight_left : Icons.turn_slight_right;
    if (n.contains('Left')) return Icons.turn_left;
    if (n.contains('Right')) return Icons.turn_right;
    return Icons.straight;
  }
}
