import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'blz_bundesbank.dart';

/// Bundesbank-ийн Bankleitzahl → банк + хот.
class GermanBankLookup {
  GermanBankLookup._();

  static const _csvAssetPaths = <String>[
    'blz-aktuell-csv-zip-data/BLZ.CSV',
    'assets/blz_bundesbank.csv',
  ];

  static Map<String, DeBlzInfo>? _byBlz;
  static Future<void>? _inFlight;

  static bool get isReady => _byBlz != null && _byBlz!.isNotEmpty;

  /// `main()` болон шилжүүлгийн дэлгэцээс дуудна.
  static Future<void> load() async {
    while (true) {
      if (isReady) return;
      if (_inFlight != null) {
        await _inFlight;
        continue;
      }
      _inFlight = _loadFromAssets();
      try {
        await _inFlight;
      } finally {
        _inFlight = null;
      }
      return;
    }
  }

  static void _putJsonEntry(String k, dynamic v, Map<String, DeBlzInfo> m) {
    if (!RegExp(r'^\d{8}$').hasMatch(k)) return;
    if (v is Map<String, dynamic>) {
      final b = v['bank']?.toString().trim() ?? '';
      final c = v['city']?.toString().trim() ?? '';
      if (b.isNotEmpty) m[k] = DeBlzInfo(b, c);
      return;
    }
    final s = v?.toString().trim() ?? '';
    if (s.isEmpty) return;
    // Хуучин: "Банк · Хот" эсвэл зөвхөн банк
    if (s.contains(' · ')) {
      final p = s.split(' · ');
      m[k] = DeBlzInfo(p.first.trim(), p.length > 1 ? p[1].trim() : '');
    } else {
      m[k] = DeBlzInfo(s, '');
    }
  }

  static Future<void> _loadFromAssets() async {
    for (final path in _csvAssetPaths) {
      try {
        final bd = await rootBundle.load(path);
        final bytes = bd.buffer
            .asUint8List(bd.offsetInBytes, bd.lengthInBytes);
        final csv = decodeBundesbankBody(bytes);
        final m = parseBundesbankBlzCsv(csv);
        if (m.isNotEmpty) {
          _byBlz = m;
          return;
        }
      } catch (_) {}
    }

    try {
      final raw = await rootBundle.loadString('assets/blz_de.json');
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final m = <String, DeBlzInfo>{};
        decoded.forEach((k, v) {
          if (k is String) _putJsonEntry(k, v, m);
        });
        _byBlz = m;
      } else {
        _byBlz = {};
      }
    } catch (_) {
      if (_byBlz == null || _byBlz!.isEmpty) {
        _byBlz = {};
      }
    }
  }

  static bool hasOfficialBlz(String blz) {
    final m = _byBlz;
    return m != null && m.containsKey(blz);
  }

  static DeBlzInfo? deInfoForBlz(String blz) {
    final m = _byBlz;
    if (m == null || m.isEmpty) return null;
    return m[blz];
  }

  static String? nameForBlz(String blz) => deInfoForBlz(blz)?.bank;
}
