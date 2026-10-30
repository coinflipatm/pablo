import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../destination.dart';
import '../hazards.dart';
import '../intent_channel.dart';
import '../profiles.dart';
import '../routes_api.dart';
import '../settings.dart';
import 'navigate_screen.dart';
import 'units_screen.dart';

const String kMapsApiKey = String.fromEnvironment('MAPS_API_KEY');

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Fleet? _fleet;
  AppSettings? _settings;
  List<Hazard> _hazards = <Hazard>[];
  String? _signingSha1;

  // Unit selection. _unitKey is 'light:<id>' or 'tractor:<id>'.
  String? _unitKey;
  String _trailerId = '';

  final TextEditingController _destCtrl = TextEditingController();
  Destination? _destination;
  bool _destFromIntent = false;

  bool _busy = false;
  String? _error;
  StreamSubscription<IncomingIntent>? _intentSub;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _intentSub?.cancel();
    _destCtrl.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final Fleet fleet = await Fleet.load();
    final AppSettings settings = await AppSettings.load();
    final List<Hazard> hazards = await Hazards.load();
    final String? sha1 = await IntentChannel.getSigningSha1();

    String? unitKey;
    if (settings.unitId != null) {
      unitKey = '${settings.unitKind}:${settings.unitId}';
    } else if (fleet.tractors.isNotEmpty) {
      unitKey = 'tractor:${fleet.tractors.first.id}';
    }

    if (!mounted) return;
    setState(() {
      _fleet = fleet;
      _settings = settings;
      _hazards = hazards;
      _signingSha1 = sha1;
      _unitKey = unitKey;
      _trailerId = settings.trailerId;
    });

    _intentSub = IntentChannel.newIntents.listen(_handleIntent);
    final IncomingIntent initial = await IntentChannel.getInitial();
    await _handleIntent(initial);
  }

  Future<void> _handleIntent(IncomingIntent intent) async {
    if (intent.isEmpty) return;
    final Destination? d = await DestinationParser.fromIntent(intent);
    if (d == null || !mounted) return;
    setState(() {
      _destination = d;
      _destCtrl.text = d.label;
      _destFromIntent = true;
      _error = null;
    });
    if ((_settings?.autoRoute ?? true) && _unitKey != null) {
      await _routeAndGo();
    }
  }

  Combination? get _combination {
    final Fleet? f = _fleet;
    final String? key = _unitKey;
    if (f == null || key == null) return null;
    final List<String> parts = key.split(':');
    if (parts.length != 2) return null;
    if (parts[0] == 'light') {
      final LightUnit? u = f.lightById(parts[1]);
      return u == null ? null : Combination.light(u);
    }
    final Tractor? t = f.tractorById(parts[1]);
    if (t == null) return null;
    final Trailer? tr = f.trailerById(_trailerId);
    return tr == null ? Combination.bobtail(t) : Combination.rig(t, tr);
  }

  bool get _isTractor => _unitKey?.startsWith('tractor:') ?? false;

  Future<void> _onUnitChanged(String? key) async {
    if (key == null) return;
    setState(() => _unitKey = key);
    final List<String> parts = key.split(':');
    await _settings?.setUnit(kind: parts[0], id: parts[1]);
  }

  Future<void> _onTrailerChanged(String? id) async {
    setState(() => _trailerId = id ?? '');
    await _settings?.setTrailer(id ?? '');
  }

  Future<void> _paste() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String? text = data?.text;
    if (text == null || text.trim().isEmpty) return;
    final Destination? d = await DestinationParser.fromString(text);
    if (!mounted) return;
    setState(() {
      _destination = d;
      _destCtrl.text = d?.label ?? text;
      _destFromIntent = false;
      _error = null;
    });
  }

  Future<Position> _currentPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw Exception('Location is turned off on this phone.');
    }
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      throw Exception('Pablo needs location permission to route from where you are.');
    }
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    ).timeout(const Duration(seconds: 15));
  }

  Future<void> _routeAndGo() async {
    if (_busy) return;
    final Combination? combo = _combination;
    if (combo == null) {
      setState(() => _error = 'Pick your unit first.');
      return;
    }

    Destination? dest = _destination;
    if (dest == null || (!_destFromIntent && dest.label != _destCtrl.text.trim())) {
      dest = await DestinationParser.fromString(_destCtrl.text);
    }
    if (dest == null) {
      setState(() => _error = 'Where to? Paste the address from the call.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _destination = dest;
    });

    try {
      final Position pos = await _currentPosition();
      final RoutesApi api = RoutesApi(
        apiKey: kMapsApiKey,
        androidPackage: 'cv.towtruck.pablo',
        androidCertSha1: _signingSha1,
      );
      final RouteResult route = await api.compute(
        originLat: pos.latitude,
        originLng: pos.longitude,
        destination: dest,
        combination: combo,
      );
      final List<HazardHit> hits = Hazards.onRoute(_hazards, route.points);
      if (!mounted) return;
      setState(() => _busy = false);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => NavigateScreen(
            route: route,
            destination: dest!,
            combination: combo,
            hazardHits: hits,
          ),
        ),
      );
      if (mounted) setState(() => _destFromIntent = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Fleet? fleet = _fleet;
    final Combination? combo = _combination;
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('PABLO', style: TextStyle(letterSpacing: 4, fontWeight: FontWeight.w800)),
        actions: <Widget>[
          IconButton(
            tooltip: 'Units & settings',
            icon: const Icon(Icons.tune),
            onPressed: fleet == null || _settings == null
                ? null
                : () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => UnitsScreen(
                          fleet: fleet,
                          settings: _settings!,
                          signingSha1: _signingSha1,
                          apiKeyPresent: kMapsApiKey.isNotEmpty,
                        ),
                      ),
                    );
                    if (mounted) setState(() {});
                  },
          ),
        ],
      ),
      body: fleet == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: <Widget>[
                  Text('WHERE TO', style: _label(theme)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _destCtrl,
                    style: const TextStyle(fontSize: 18),
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _routeAndGo(),
                    onChanged: (_) {
                      if (_destFromIntent) setState(() => _destFromIntent = false);
                    },
                    decoration: InputDecoration(
                      hintText: 'Address, coordinates, or a Maps link',
                      suffixIcon: IconButton(
                        tooltip: 'Paste',
                        icon: const Icon(Icons.content_paste),
                        onPressed: _paste,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('UNIT', style: _label(theme)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    initialValue: _unitKey,
                    isExpanded: true,
                    items: <DropdownMenuItem<String>>[
                      for (final Tractor t in fleet.tractors)
                        DropdownMenuItem<String>(value: 'tractor:${t.id}', child: Text(t.name)),
                      for (final LightUnit u in fleet.lightUnits)
                        DropdownMenuItem<String>(value: 'light:${u.id}', child: Text(u.name)),
                    ],
                    onChanged: _onUnitChanged,
                  ),
                  if (_isTractor) ...<Widget>[
                    const SizedBox(height: 12),
                    Text('TRAILER', style: _label(theme)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      initialValue: fleet.trailerById(_trailerId) == null ? '' : _trailerId,
                      isExpanded: true,
                      items: <DropdownMenuItem<String>>[
                        const DropdownMenuItem<String>(value: '', child: Text('None (bobtail)')),
                        for (final Trailer t in fleet.trailers)
                          DropdownMenuItem<String>(value: t.id, child: Text(t.name)),
                      ],
                      onChanged: _onTrailerChanged,
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (combo != null) _ComboCard(combo: combo),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _routeAndGo,
                    child: _busy
                        ? const SizedBox(
                            height: 26,
                            width: 26,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          )
                        : const Text('GO'),
                  ),
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 14),
                    _ErrorBox(message: _error!),
                  ],
                  if (kMapsApiKey.isEmpty) ...<Widget>[
                    const SizedBox(height: 14),
                    const _ErrorBox(
                      message: 'This build has no Maps API key. Routing and the map will not work '
                          'until MAPS_API_KEY is set in the GitHub build secrets.',
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  TextStyle _label(ThemeData theme) => TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.5,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
      );
}

class _ComboCard extends StatelessWidget {
  const _ComboCard({required this.combo});
  final Combination combo;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color accent = combo.truckMode ? theme.colorScheme.primary : theme.colorScheme.secondary;
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: accent.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(combo.truckMode ? Icons.local_shipping : Icons.directions_car, color: accent, size: 20),
                const SizedBox(width: 8),
                Text(
                  combo.truckMode ? 'TRUCK ROUTING' : 'CAR ROUTING',
                  style: TextStyle(color: accent, fontWeight: FontWeight.w800, letterSpacing: 1.2, fontSize: 12),
                ),
                if (combo.estimated) ...<Widget>[
                  const Spacer(),
                  Text(
                    'DIMENSIONS ESTIMATED',
                    style: TextStyle(
                      color: theme.colorScheme.error,
                      fontWeight: FontWeight.w700,
                      fontSize: 10,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Text(combo.summary, style: const TextStyle(fontSize: 14, height: 1.4)),
          ],
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withValues(alpha: 0.12),
        border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(message, style: TextStyle(color: theme.colorScheme.onSurface)),
    );
  }
}
