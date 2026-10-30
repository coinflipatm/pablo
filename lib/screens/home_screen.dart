import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../destination.dart';
import '../hazards.dart';
import '../intent_channel.dart';
import '../places_api.dart';
import '../profiles.dart';
import '../routes_api.dart';
import '../settings.dart';
import 'navigate_screen.dart';
import 'pin_drop_screen.dart';
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

  String? _unitKey;
  String _trailerId = '';

  final TextEditingController _destCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  Destination? _destination;
  bool _destFromIntent = false;

  // Autocomplete
  late PlacesAutocomplete _places = PlacesAutocomplete(apiKey: kMapsApiKey);
  List<PlacePrediction> _suggestions = <PlacePrediction>[];
  bool _loadingSuggestions = false;
  Timer? _debounce;
  double? _currentLat;
  double? _currentLng;

  // Clipboard
  String? _clipboardText;

  bool _busy = false;
  String? _error;
  StreamSubscription<IncomingIntent>? _intentSub;

  @override
  void initState() {
    super.initState();
    _boot();
    _searchFocus.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _intentSub?.cancel();
    _destCtrl.dispose();
    _searchFocus.removeListener(_onFocusChange);
    _searchFocus.dispose();
    super.dispose();
  }

  // ─── Boot ──────────────────────────────────────────────────────────────────

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
      _places = PlacesAutocomplete(
        apiKey: kMapsApiKey,
        androidPackage: 'cv.towtruck.pablo',
        androidCertSha1: sha1,
      );
    });

    // Grab a quick location fix to bias autocomplete results.
    _grabLocation();

    _intentSub = IntentChannel.newIntents.listen(_handleIntent);
    final IncomingIntent initial = await IntentChannel.getInitial();
    await _handleIntent(initial);
  }

  Future<void> _grabLocation() async {
    try {
      final bool enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return;
      final LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) return;
      final Position pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.low),
      ).timeout(const Duration(seconds: 8));
      if (mounted) {
        setState(() {
          _currentLat = pos.latitude;
          _currentLng = pos.longitude;
        });
      }
    } catch (_) {}
  }

  Future<void> _handleIntent(IncomingIntent intent) async {
    if (intent.isEmpty) return;
    final Destination? d = await DestinationParser.fromIntent(intent);
    if (d == null || !mounted) return;
    setState(() {
      _destination = d;
      _destCtrl.text = d.label;
      _destFromIntent = true;
      _suggestions = <PlacePrediction>[];
      _error = null;
    });
    if ((_settings?.autoRoute ?? true) && _unitKey != null) {
      await _routeAndGo();
    }
  }

  // ─── Autocomplete ──────────────────────────────────────────────────────────

  void _onFocusChange() {
    if (_searchFocus.hasFocus) {
      _checkClipboard();
    } else {
      // Small delay so a tap on a suggestion registers before we hide the list.
      Future<void>.delayed(const Duration(milliseconds: 200), () {
        if (mounted && !_searchFocus.hasFocus) {
          setState(() => _suggestions = <PlacePrediction>[]);
        }
      });
    }
  }

  Future<void> _checkClipboard() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String? text = data?.text?.trim();
    if (!mounted) return;
    setState(() {
      _clipboardText = (text != null && text.isNotEmpty) ? text : null;
    });
  }

  void _onSearchChanged(String text) {
    if (_destFromIntent) setState(() => _destFromIntent = false);
    _destination = null;

    _debounce?.cancel();
    if (text.trim().length < 2) {
      setState(() {
        _suggestions = <PlacePrediction>[];
        _loadingSuggestions = false;
      });
      return;
    }
    setState(() => _loadingSuggestions = true);
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final List<PlacePrediction> results = await _places.suggest(
        text,
        lat: _currentLat,
        lng: _currentLng,
      );
      if (mounted) {
        setState(() {
          _suggestions = results;
          _loadingSuggestions = false;
        });
      }
    });
  }

  Future<void> _onSuggestionTap(PlacePrediction p) async {
    _searchFocus.unfocus();
    setState(() {
      _destCtrl.text = p.fullText;
      _suggestions = <PlacePrediction>[];
      _busy = true;
      _error = null;
    });

    final PlaceDetail? detail = await _places.detail(p.placeId);
    if (!mounted) return;

    if (detail != null) {
      _destination = Destination.latLng(
        detail.lat,
        detail.lng,
        label: detail.formattedAddress,
      );
      _destCtrl.text = detail.formattedAddress;
    } else {
      _destination = Destination.address(p.fullText);
    }
    setState(() => _busy = false);

    if (_settings?.autoRoute ?? true) {
      await _routeAndGo();
    }
  }

  Future<void> _onPasteSuggestion() async {
    final String? text = _clipboardText;
    if (text == null || text.isEmpty) return;

    final Destination? d = await DestinationParser.fromString(text);
    if (!mounted) return;
    setState(() {
      _destination = d;
      _destCtrl.text = d?.label ?? text;
      _destFromIntent = false;
      _suggestions = <PlacePrediction>[];
      _error = null;
      _clipboardText = null;
    });
    _searchFocus.unfocus();

    if (_settings?.autoRoute ?? true) {
      await _routeAndGo();
    }
  }

  void _clearSearch() {
    _debounce?.cancel();
    _destCtrl.clear();
    _destination = null;
    _destFromIntent = false;
    setState(() {
      _suggestions = <PlacePrediction>[];
      _loadingSuggestions = false;
      _error = null;
    });
    _searchFocus.requestFocus();
    _checkClipboard();
  }

  Future<void> _openPinDrop() async {
    _searchFocus.unfocus();
    final Destination? dest = await Navigator.of(context).push<Destination>(
      MaterialPageRoute<Destination>(
        builder: (_) => PinDropScreen(
          initialLat: _currentLat,
          initialLng: _currentLng,
        ),
      ),
    );
    if (dest == null || !mounted) return;
    setState(() {
      _destination = dest;
      _destCtrl.text = dest.label;
      _destFromIntent = false;
      _suggestions = <PlacePrediction>[];
      _error = null;
    });
    if (_settings?.autoRoute ?? true) {
      await _routeAndGo();
    }
  }

  // ─── Unit / trailer ────────────────────────────────────────────────────────

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

  // ─── Route ─────────────────────────────────────────────────────────────────

  Future<Position> _currentPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw Exception('Location is turned off on this phone.');
    }
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      throw Exception(
          'Pablo needs location permission to route from where you are.');
    }
    return Geolocator.getCurrentPosition(
      locationSettings:
          const LocationSettings(accuracy: LocationAccuracy.high),
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
    if (dest == null ||
        (!_destFromIntent && dest.label != _destCtrl.text.trim())) {
      dest = await DestinationParser.fromString(_destCtrl.text);
    }
    if (dest == null) {
      setState(() => _error = 'Where to? Type or paste an address.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _destination = dest;
    });

    try {
      final Position pos = await _currentPosition();
      if (mounted) {
        setState(() {
          _currentLat = pos.latitude;
          _currentLng = pos.longitude;
        });
      }
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

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final Fleet? fleet = _fleet;
    final Combination? combo = _combination;
    final ThemeData theme = Theme.of(context);
    final bool hasText = _destCtrl.text.isNotEmpty;
    final bool showSuggestions = _searchFocus.hasFocus &&
        (_suggestions.isNotEmpty ||
            _loadingSuggestions ||
            (_clipboardText != null && !hasText));

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/brand/pablo_icon.png',
                width: 34,
                height: 34,
                filterQuality: FilterQuality.medium,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'PABLO',
              style: TextStyle(letterSpacing: 4, fontWeight: FontWeight.w800),
            ),
          ],
        ),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // ── Search bar + suggestions ──────────────────────────────
                  Material(
                    color: const Color(0xFF181D26),
                    elevation: 4,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                          child: TextField(
                            controller: _destCtrl,
                            focusNode: _searchFocus,
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w500),
                            textInputAction: TextInputAction.go,
                            onSubmitted: (_) => _routeAndGo(),
                            onChanged: _onSearchChanged,
                            decoration: InputDecoration(
                              hintText: 'Where to?',
                              hintStyle: TextStyle(
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.4),
                                fontWeight: FontWeight.w400,
                              ),
                              prefixIcon: Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Icon(
                                  Icons.search,
                                  size: 24,
                                  color: hasText
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.onSurface
                                          .withValues(alpha: 0.45),
                                ),
                              ),
                              suffixIcon: hasText
                                  ? IconButton(
                                      tooltip: 'Clear',
                                      icon: Icon(
                                        Icons.cancel,
                                        color: theme.colorScheme.onSurface
                                            .withValues(alpha: 0.5),
                                      ),
                                      onPressed: _clearSearch,
                                    )
                                  : IconButton(
                                      tooltip: 'Drop a pin on the map',
                                      icon: Icon(
                                        Icons.add_location_alt_outlined,
                                        color: theme.colorScheme.onSurface
                                            .withValues(alpha: 0.5),
                                      ),
                                      onPressed: _openPinDrop,
                                    ),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 16),
                              filled: true,
                              fillColor: const Color(0xFF242B38),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide.none,
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(
                                  color: theme.colorScheme.primary
                                      .withValues(alpha: 0.6),
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (showSuggestions)
                          _SuggestionList(
                            suggestions: _suggestions,
                            loading: _loadingSuggestions,
                            clipboardText:
                                hasText ? null : _clipboardText,
                            onSuggestionTap: _onSuggestionTap,
                            onPasteTap: _onPasteSuggestion,
                          ),
                      ],
                    ),
                  ),

                  // ── Unit / combo / GO ─────────────────────────────────────
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          _SectionLabel('UNIT'),
                          const SizedBox(height: 6),
                          DropdownButtonFormField<String>(
                            value: _unitKey,
                            isExpanded: true,
                            style: const TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w600),
                            items: <DropdownMenuItem<String>>[
                              for (final Tractor t in fleet.tractors)
                                DropdownMenuItem<String>(
                                    value: 'tractor:${t.id}',
                                    child: Text(t.name)),
                              for (final LightUnit u in fleet.lightUnits)
                                DropdownMenuItem<String>(
                                    value: 'light:${u.id}',
                                    child: Text(u.name)),
                            ],
                            onChanged: _onUnitChanged,
                          ),
                          if (_isTractor) ...<Widget>[
                            const SizedBox(height: 14),
                            _SectionLabel('TRAILER'),
                            const SizedBox(height: 6),
                            DropdownButtonFormField<String>(
                              value: fleet.trailerById(_trailerId) == null
                                  ? ''
                                  : _trailerId,
                              isExpanded: true,
                              style: const TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w600),
                              items: <DropdownMenuItem<String>>[
                                const DropdownMenuItem<String>(
                                    value: '',
                                    child: Text('None (bobtail)')),
                                for (final Trailer t in fleet.trailers)
                                  DropdownMenuItem<String>(
                                      value: t.id, child: Text(t.name)),
                              ],
                              onChanged: _onTrailerChanged,
                            ),
                          ],
                          if (combo != null) ...<Widget>[
                            const SizedBox(height: 16),
                            _ComboCard(combo: combo),
                          ],
                          const SizedBox(height: 20),
                          FilledButton(
                            onPressed: _busy ? null : _routeAndGo,
                            child: _busy
                                ? const SizedBox(
                                    height: 26,
                                    width: 26,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 3,
                                        color: Colors.black),
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
                              message:
                                  'No Maps API key — routing and map will not work. '
                                  'Set MAPS_API_KEY in GitHub build secrets.',
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

// ─── Suggestion list ──────────────────────────────────────────────────────────

class _SuggestionList extends StatelessWidget {
  const _SuggestionList({
    required this.suggestions,
    required this.loading,
    required this.clipboardText,
    required this.onSuggestionTap,
    required this.onPasteTap,
  });

  final List<PlacePrediction> suggestions;
  final bool loading;
  final String? clipboardText;
  final ValueChanged<PlacePrediction> onSuggestionTap;
  final VoidCallback onPasteTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<Widget> items = <Widget>[];

    // Clipboard hint at top when field is empty.
    if (clipboardText != null) {
      final String preview = clipboardText!.length > 48
          ? '${clipboardText!.substring(0, 48)}…'
          : clipboardText!;
      items.add(_SuggestionTile(
        leading: Icons.content_paste_rounded,
        leadingColor: theme.colorScheme.primary,
        mainText: preview,
        secondaryText: 'Paste from clipboard',
        onTap: onPasteTap,
      ));
    }

    if (loading && suggestions.isEmpty) {
      items.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text('Searching…',
                style: TextStyle(
                    color:
                        theme.colorScheme.onSurface.withValues(alpha: 0.5))),
          ],
        ),
      ));
    }

    for (final PlacePrediction p in suggestions) {
      items.add(_SuggestionTile(
        leading: Icons.location_on_outlined,
        leadingColor: theme.colorScheme.onSurface.withValues(alpha: 0.45),
        mainText: p.mainText,
        secondaryText: p.secondaryText,
        onTap: () => onSuggestionTap(p),
      ));
    }

    if (items.isEmpty) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
              color:
                  theme.colorScheme.onSurface.withValues(alpha: 0.08)),
        ),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: items),
    );
  }
}

class _SuggestionTile extends StatelessWidget {
  const _SuggestionTile({
    required this.leading,
    required this.leadingColor,
    required this.mainText,
    required this.secondaryText,
    required this.onTap,
  });

  final IconData leading;
  final Color leadingColor;
  final String mainText;
  final String secondaryText;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: <Widget>[
            Icon(leading, size: 22, color: leadingColor),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    mainText,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (secondaryText.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      secondaryText,
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.55),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Combo card ───────────────────────────────────────────────────────────────

class _ComboCard extends StatelessWidget {
  const _ComboCard({required this.combo});
  final Combination combo;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color accent = combo.truckMode
        ? theme.colorScheme.primary
        : theme.colorScheme.secondary;
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: accent.withValues(alpha: 0.45)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  combo.truckMode
                      ? Icons.local_shipping
                      : Icons.directions_car,
                  color: accent,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  combo.truckMode ? 'TRUCK ROUTING' : 'CAR ROUTING',
                  style: TextStyle(
                      color: accent,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      fontSize: 12),
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
            Text(combo.summary,
                style: const TextStyle(fontSize: 14, height: 1.4)),
          ],
        ),
      ),
    );
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.5,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
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
        border: Border.all(
            color: theme.colorScheme.error.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(message,
          style: TextStyle(color: theme.colorScheme.onSurface)),
    );
  }
}
