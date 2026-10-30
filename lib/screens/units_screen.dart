import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../profiles.dart';
import '../settings.dart';
import '../units.dart';

/// Edit the fleet's numbers in feet, inches and pounds. Saved on this phone;
/// no rebuild needed to correct a dimension against the permit.
class UnitsScreen extends StatefulWidget {
  const UnitsScreen({
    super.key,
    required this.fleet,
    required this.settings,
    required this.signingSha1,
    required this.apiKeyPresent,
  });

  final Fleet fleet;
  final AppSettings settings;
  final String? signingSha1;
  final bool apiKeyPresent;

  @override
  State<UnitsScreen> createState() => _UnitsScreenState();
}

class _UnitsScreenState extends State<UnitsScreen> {
  late bool _autoRoute = widget.settings.autoRoute;

  Future<void> _edit(String title, String current, Future<bool> Function(String) apply) async {
    final TextEditingController ctrl = TextEditingController(text: current);
    final String? value = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: "13'6\"  ·  53'  ·  80,000"),
          onSubmitted: (String v) => Navigator.of(ctx).pop(v),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text), child: const Text('Save')),
        ],
      ),
    );
    if (value == null) return;
    final bool ok = await apply(value);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't read that. Try 13'6\", 53', 162in, or 80,000.")),
      );
      return;
    }
    await widget.fleet.saveOverrides();
    if (mounted) setState(() {});
  }

  Future<bool> _setMm(void Function(int) setter, String raw) async {
    final int? mm = Units.parseFtInToMm(raw);
    if (mm == null || mm <= 0) return false;
    setter(mm);
    return true;
  }

  Future<bool> _setKg(void Function(int) setter, String raw) async {
    final int? kg = Units.parseLbToKg(raw);
    if (kg == null || kg <= 0) return false;
    setter(kg);
    return true;
  }

  Future<bool> _setInt(void Function(int) setter, String raw) async {
    final int? v = int.tryParse(raw.trim());
    if (v == null || v <= 0 || v > 20) return false;
    setter(v);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final Fleet f = widget.fleet;
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Units & settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
          SwitchListTile(
            title: const Text('Go automatically when opened from Towbook'),
            subtitle: const Text('Skips the GO button when a destination comes in from another app.'),
            value: _autoRoute,
            onChanged: (bool v) async {
              setState(() => _autoRoute = v);
              await widget.settings.setAutoRoute(v);
            },
          ),
          const Divider(),
          _Header('TRACTORS'),
          for (final Tractor t in f.tractors) ...<Widget>[
            _Title(t.name, t.detail, estimated: t.estimated),
            _Row('Axles', '${t.axles}',
                () => _edit('${t.name}: axles', '${t.axles}', (String v) => _setInt((int x) => t.axles = x, v))),
            _Row('Height', Units.ftIn(t.heightMm),
                () => _edit('${t.name}: height', Units.ftIn(t.heightMm), (String v) => _setMm((int x) => t.heightMm = x, v))),
            _Row('Width', Units.ftIn(t.widthMm),
                () => _edit('${t.name}: width', Units.ftIn(t.widthMm), (String v) => _setMm((int x) => t.widthMm = x, v))),
            _Row('Bumper to kingpin', Units.ftIn(t.bumperToKingpinMm),
                () => _edit('${t.name}: bumper to kingpin', Units.ftIn(t.bumperToKingpinMm),
                    (String v) => _setMm((int x) => t.bumperToKingpinMm = x, v))),
          ],
          const Divider(),
          _Header('TRAILERS  (permit envelope)'),
          for (final Trailer t in f.trailers) ...<Widget>[
            _Title(t.name, t.detail, estimated: t.estimated),
            _Row('Axles', '${t.axles}',
                () => _edit('${t.name}: axles', '${t.axles}', (String v) => _setInt((int x) => t.axles = x, v))),
            _Row('Length (kingpin to rear)', Units.ftIn(t.lengthMm),
                () => _edit('${t.name}: length', Units.ftIn(t.lengthMm), (String v) => _setMm((int x) => t.lengthMm = x, v))),
            _Row('Permit max height', Units.ftIn(t.permitHeightMm),
                () => _edit('${t.name}: permit height', Units.ftIn(t.permitHeightMm),
                    (String v) => _setMm((int x) => t.permitHeightMm = x, v))),
            _Row('Permit max width', Units.ftIn(t.permitWidthMm),
                () => _edit('${t.name}: permit width', Units.ftIn(t.permitWidthMm),
                    (String v) => _setMm((int x) => t.permitWidthMm = x, v))),
            _Row('Permit max gross', Units.lb(t.permitGrossKg),
                () => _edit('${t.name}: permit gross weight', Units.lb(t.permitGrossKg).replaceAll(' lb', ''),
                    (String v) => _setKg((int x) => t.permitGrossKg = x, v))),
          ],
          const Divider(),
          _Header('THIS BUILD'),
          ListTile(
            dense: true,
            title: const Text('Maps API key'),
            subtitle: Text(widget.apiKeyPresent ? 'Present' : 'MISSING: set MAPS_API_KEY in GitHub secrets'),
            trailing: Icon(
              widget.apiKeyPresent ? Icons.check_circle : Icons.error,
              color: widget.apiKeyPresent ? Colors.green : theme.colorScheme.error,
            ),
          ),
          ListTile(
            dense: true,
            title: const Text('Package name'),
            subtitle: const Text('cv.towtruck.pablo'),
          ),
          ListTile(
            dense: true,
            title: const Text('Signing SHA-1 (for API key restriction)'),
            subtitle: Text(widget.signingSha1 ?? 'unavailable', style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
            trailing: IconButton(
              icon: const Icon(Icons.copy),
              onPressed: widget.signingSha1 == null
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: widget.signingSha1!));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
                      }
                    },
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton(
              onPressed: () async {
                await Fleet.clearOverrides();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Reset to built-in defaults. Restart Pablo to reload.')),
                  );
                }
              },
              child: const Text('Reset dimensions to defaults'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.name, this.detail, {required this.estimated});
  final String name;
  final String detail;
  final bool estimated;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListTile(
      title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(detail),
      trailing: estimated
          ? Text(
              'ESTIMATED',
              style: TextStyle(color: theme.colorScheme.error, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1),
            )
          : null,
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, this.onTap);
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 32, right: 16),
      title: Text(label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(width: 6),
          const Icon(Icons.edit, size: 16),
        ],
      ),
      onTap: onTap,
    );
  }
}
