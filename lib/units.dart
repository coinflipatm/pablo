/// Unit helpers. Everything is stored metric (mm, kg) because that is what the
/// Routes API takes; everything is shown imperial because that is what a
/// driver and a permit say.
class Units {
  static const double mmPerInch = 25.4;
  static const double kgPerLb = 0.45359237;

  static String ftIn(int? mm) {
    if (mm == null) return '—';
    final int totalIn = (mm / mmPerInch).round();
    final int ft = totalIn ~/ 12;
    final int inch = totalIn % 12;
    return inch == 0 ? "$ft'" : "$ft' $inch\"";
  }

  static String lb(int? kg) {
    if (kg == null) return '—';
    final int lbs = (kg / kgPerLb).round();
    return '${_thousands(lbs)} lb';
  }

  static String miles(int meters) => '${(meters / 1609.344).toStringAsFixed(1)} mi';

  static String duration(int seconds) {
    final int h = seconds ~/ 3600;
    final int m = (seconds % 3600) ~/ 60;
    if (h == 0) return '$m min';
    return '${h}h ${m}m';
  }

  /// Parses 13'6", 13-6, 13 6, 13.5 (feet), 162in, 162" into millimeters.
  static int? parseFtInToMm(String raw) {
    final String s = raw.trim().toLowerCase();
    if (s.isEmpty) return null;

    final RegExpMatch? inches = RegExp(r'^(\d+(?:\.\d+)?)\s*(?:in|")$').firstMatch(s);
    if (inches != null) {
      return (double.parse(inches.group(1)!) * mmPerInch).round();
    }

    final RegExpMatch? ftAndIn =
        RegExp(r"""^(\d+)\s*(?:'|ft|-|\s)\s*(\d+(?:\.\d+)?)\s*(?:"|in)?$""").firstMatch(s);
    if (ftAndIn != null) {
      final double ft = double.parse(ftAndIn.group(1)!);
      final double inch = double.parse(ftAndIn.group(2)!);
      return ((ft * 12 + inch) * mmPerInch).round();
    }

    final RegExpMatch? ftOnly = RegExp(r"^(\d+(?:\.\d+)?)\s*(?:'|ft)?$").firstMatch(s);
    if (ftOnly != null) {
      return (double.parse(ftOnly.group(1)!) * 12 * mmPerInch).round();
    }
    return null;
  }

  /// Parses 80,000 / 80000 / 80000lb / 40 tons into kilograms.
  static int? parseLbToKg(String raw) {
    final String s = raw.trim().toLowerCase().replaceAll(',', '');
    if (s.isEmpty) return null;
    final RegExpMatch? tons = RegExp(r'^(\d+(?:\.\d+)?)\s*(?:t|ton|tons)$').firstMatch(s);
    if (tons != null) {
      return (double.parse(tons.group(1)!) * 2000 * kgPerLb).round();
    }
    final RegExpMatch? lbs = RegExp(r'^(\d+(?:\.\d+)?)\s*(?:lb|lbs)?$').firstMatch(s);
    if (lbs != null) {
      return (double.parse(lbs.group(1)!) * kgPerLb).round();
    }
    return null;
  }

  static String _thousands(int n) {
    final String s = n.toString();
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final int fromEnd = s.length - i;
      out.write(s[i]);
      if (fromEnd > 1 && fromEnd % 3 == 1) out.write(',');
    }
    return out.toString();
  }
}
