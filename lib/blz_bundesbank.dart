import 'dart:convert';

/// BLZ → банк (курц нэр) + хот (Bundesbank CSV-ийн «Ort»).
class DeBlzInfo {
  final String bank;
  final String city;
  const DeBlzInfo(this.bank, this.city);
}

/// Deutsche Bundesbank — Bankleitzahl CSV (ам официал түүхий файл).
/// Холбоос солигдвол шинээр нэмж болно.
const kBundesbankBlzCsvUrls = <String>[
  'https://www.bundesbank.de/resource/blob/602632/b84de66126cefe73755ec9edfdcce335/ml/blz_aktuell_csv/data/blz_aktuell_csv.csv',
  'https://www.bundesbank.de/resource/blob/602634/d86ad91aadbb033945358443266ff796/ml/blz_aktuell_csv/data/blz_aktuell_csv.csv',
  'https://www.bundesbank.de/resource/blob/831878/ee72640589f569533bcf857152683575/ml/blz_aktuell_csv/data/blz_aktuell_csv.csv',
];

/// Ихэнх файл UTF-8; зарим хуучин файл Latin-1 байж болно.
String decodeBundesbankBody(List<int> bytes) {
  final asUtf8 = utf8.decode(bytes, allowMalformed: true);
  if (!asUtf8.contains('\uFFFD')) return asUtf8;
  return latin1.decode(bytes);
}

String _csvCell(String raw) {
  var t = raw.trim();
  if (t.length >= 2 && t.startsWith('"') && t.endsWith('"')) {
    return t.substring(1, t.length - 1).replaceAll('""', '"');
  }
  return t;
}

/// Тэмдэгт мөр доторх «;» хашилтыг хүндэтгэж задлана (Bundesbank CSV).
List<String> splitBundesbankCsvLine(String line) {
  final out = <String>[];
  final buf = StringBuffer();
  var inQ = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '"') {
      if (inQ && i + 1 < line.length && line[i + 1] == '"') {
        buf.write('"');
        i++;
        continue;
      }
      inQ = !inQ;
      continue;
    }
    if (ch == ';' && !inQ) {
      out.add(buf.toString());
      buf.clear();
      continue;
    }
    buf.write(ch);
  }
  out.add(buf.toString());
  return out;
}

/// «;» тусгаарлагч — BLZ → банк + хот тусад нь.
Map<String, DeBlzInfo> parseBundesbankBlzCsv(String body) {
  var text = body;
  if (text.startsWith('\uFEFF')) text = text.substring(1);

  final lines =
      text.split(RegExp(r'\r?\n')).where((l) => l.trim().isNotEmpty).toList();
  if (lines.isEmpty) return {};

  final header =
      splitBundesbankCsvLine(lines.first).map((h) => _csvCell(h).toLowerCase()).toList();
  var blzIdx = header.indexWhere((h) => h == 'bankleitzahl');
  if (blzIdx < 0) {
    blzIdx = header.indexWhere((h) => h.contains('bankleitzahl'));
  }
  var nameIdx = header.indexWhere((h) => h.contains('kurzbezeichnung'));
  if (nameIdx < 0) {
    nameIdx = header.indexWhere((h) =>
        h == 'bezeichnung' || h.startsWith('bezeichnung '));
  }
  if (nameIdx < 0) {
    nameIdx = header.indexWhere((h) => h.contains('bezeichnung'));
  }

  final ortIdx = header.indexWhere((h) => h == 'ort');

  var startLine = 1;
  if (blzIdx < 0 || nameIdx < 0) {
    blzIdx = 0;
    nameIdx = 2;
    startLine = 0;
  }

  final map = <String, DeBlzInfo>{};
  for (var i = startLine; i < lines.length; i++) {
    final parts = splitBundesbankCsvLine(lines[i]);
    if (parts.length <= nameIdx || parts.length <= blzIdx) continue;
    final blz = _csvCell(parts[blzIdx]);
    if (!RegExp(r'^\d{8}$').hasMatch(blz)) continue;
    final bank = _csvCell(parts[nameIdx]);
    if (bank.isEmpty) continue;
    final city = (ortIdx >= 0 && ortIdx < parts.length)
        ? _csvCell(parts[ortIdx]).trim()
        : '';
    if (map.containsKey(blz)) continue;
    map[blz] = DeBlzInfo(bank, city);
  }
  return map;
}
