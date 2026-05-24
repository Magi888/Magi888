// Bundesbank Bankleitzahl CSV → assets/blz_de.json
// Ажиллуулах: төслийн үндсэн хавтаснаас
//   dart run tool/fetch_blz.dart
// Гараар татсан CSV:
//   dart run tool/fetch_blz.dart C:\path\blz_aktuell_csv.csv
//
// Эх үүсвэр: Deutsche Bundesbank — «Bankleitzahl» CSV.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:moneysent/blz_bundesbank.dart';

Future<void> main(List<String> args) async {
  String? body;
  String? usedUrl;

  if (args.isNotEmpty) {
    final f = File(args.first);
    if (await f.exists()) {
      body = decodeBundesbankBody(await f.readAsBytes());
      stdout.writeln('Файлаас уншлаа: ${f.path}');
    } else {
      stderr.writeln('Файл олдсонгүй: ${args.first}');
      exitCode = 1;
      return;
    }
  }

  for (final url in kBundesbankBlzCsvUrls) {
    if (body != null) break;
    try {
      final r =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 45));
      if (r.statusCode == 200 && r.body.contains(';')) {
        body = decodeBundesbankBody(r.bodyBytes);
        usedUrl = url;
        break;
      }
      stderr.writeln('$url → HTTP ${r.statusCode}');
    } catch (e) {
      stderr.writeln('$url → $e');
    }
  }

  if (body == null || body.isEmpty) {
    stderr.writeln(
      'CSV татаж чадсангүй. Bundesbank-ийн сайтаас «Bankleitzahl» CSV татаад:\n'
      '  dart run tool/fetch_blz.dart C:\\path\\blz_aktuell_csv.csv',
    );
    exitCode = 1;
    return;
  }

  if (usedUrl != null) {
    stdout.writeln('Эх үүсвэр: $usedUrl');
  }
  final map = parseBundesbankBlzCsv(body);
  stdout.writeln('Мөрүүд: ${map.length}');

  final enc = <String, dynamic>{};
  map.forEach((k, v) {
    enc[k] = {'bank': v.bank, 'city': v.city};
  });

  final outFile = File('${Directory.current.path}/assets/blz_de.json');
  await outFile.parent.create(recursive: true);
  await outFile.writeAsString(jsonEncode(enc));
  stdout.writeln('Бичигдлээ: ${outFile.path}');
}
