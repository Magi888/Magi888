import 'german_bank_lookup.dart';

String _normIban(String raw) =>
    raw.replaceAll(RegExp(r'\s'), '').toUpperCase();

/// Герман IBAN-ийн BBAN доторх 8 оронтой BLZ (байхгүй бол null).
String? germanBlzFromIbanRaw(String raw) {
  final s = _normIban(raw);
  if (!s.startsWith('DE') || s.length < 12) return null;
  final blz = s.substring(4, 12);
  if (!RegExp(r'^\d{8}$').hasMatch(blz)) return null;
  return blz;
}

String _englishCountryForIban(String raw) {
  final s = _normIban(raw);
  if (s.length < 2) return '';
  const cc = {
    'DE': 'Germany',
    'AT': 'Austria',
    'FR': 'France',
    'NL': 'Netherlands',
    'BE': 'Belgium',
    'ES': 'Spain',
    'IT': 'Italy',
    'PT': 'Portugal',
    'IE': 'Ireland',
    'FI': 'Finland',
    'GR': 'Greece',
    'LU': 'Luxembourg',
    'CH': 'Switzerland',
    'PL': 'Poland',
    'CZ': 'Czechia',
    'SK': 'Slovakia',
    'SI': 'Slovenia',
    'EE': 'Estonia',
    'LV': 'Latvia',
    'LT': 'Lithuania',
    'CY': 'Cyprus',
    'MT': 'Malta',
    'HR': 'Croatia',
    'BG': 'Bulgaria',
    'RO': 'Romania',
    'HU': 'Hungary',
    'GB': 'United Kingdom',
    'NO': 'Norway',
    'SE': 'Sweden',
    'DK': 'Denmark',
    'IS': 'Iceland',
    'LI': 'Liechtenstein',
  };
  final code = s.substring(0, 2);
  return cc[code] ?? '';
}

/// IBAN-ийн доор: «Банк, Хот, Улс» — тусдаа шошго, icon-гүй.
String ibanRecipientBankCityCountryLine(String raw) {
  final s = _normIban(raw);
  // DE needs full BLZ (8 digits from BBAN); others only need enough for their branch.
  if (s.length < 2) return '';

  if (s.startsWith('DE')) {
    if (s.length < 12) return '';
    final blz = s.substring(4, 12);
    if (!RegExp(r'^\d{8}$').hasMatch(blz)) return '';
    final info = GermanBankLookup.deInfoForBlz(blz);
    var bank = info?.bank ?? '';
    final city = (info?.city ?? '').trim();
    if (bank.isEmpty) bank = _deBankFromBlzHeuristic(blz);
    if (bank.isEmpty) return '';
    final country = 'Germany';
    if (city.isNotEmpty) return '$bank, $city, $country';
    return '$bank, $country';
  }

  if (s.startsWith('AT')) {
    final bank = _guessAustriaBank(s);
    if (bank.isEmpty) return '';
    return '$bank, Austria';
  }

  if (s.startsWith('FR')) {
    final bank = _frenchBankName(s);
    if (bank.isNotEmpty) return '$bank, France';
    if (s.length >= 14) return 'France';
    return '';
  }

  if (s.startsWith('ES')) {
    final bank = _spanishBankName(s);
    if (bank.isNotEmpty) return '$bank, Spain';
    if (s.length >= 9) return 'Spain';
    return '';
  }

  if (s.startsWith('NL')) {
    final bank = _dutchBankName(s);
    if (bank.isNotEmpty) return '$bank, Netherlands';
    if (s.length >= 8) return 'Netherlands';
    return '';
  }

  if (s.startsWith('BE')) {
    final bank = _belgianBankName(s);
    if (bank.isNotEmpty) return '$bank, Belgium';
    if (s.length >= 7) return 'Belgium';
    return '';
  }

  final ccEn = _englishCountryForIban(raw);
  if (ccEn.isEmpty) return '';
  final bank = ibanBankGuessLabel(raw);
  if (bank.isNotEmpty) return '$bank, $ccEn';
  return ccEn;
}

/// Хүлээн авагчийн банк (эвриистик / lookup-ийн банкын нэр л).
String ibanBankGuessLabel(String raw) {
  final s = _normIban(raw);
  if (s.length < 4) return '';
  final cc = s.substring(0, 2);
  switch (cc) {
    case 'DE':
      return _germanyBankLabel(s);
    case 'AT':
      return _guessAustriaBank(s);
    case 'FR':
      return _frenchBankName(s);
    case 'ES':
      return _spanishBankName(s);
    case 'NL':
      return _dutchBankName(s);
    case 'BE':
      return _belgianBankName(s);
    default:
      return '';
  }
}

/// Франц: IBAN-д «code banque» гэж ВВАН-ы эхний 5 тоо (FR + шалгалтын дараа).
/// Хот/салбарын нэр — нээлттэй салбарын каталоггүй тул улсын нэр л нэг мөрт орно.
String _frenchBankName(String s) {
  if (!s.startsWith('FR') || s.length < 14) return '';
  final code = s.substring(4, 9);
  if (!RegExp(r'^\d{5}$').hasMatch(code)) return '';
  final hit = _kFrBankByCode[code];
  if (hit != null) return hit;
  if (code.startsWith('1')) return 'Crédit Agricole';
  return '';
}

const Map<String, String> _kFrBankByCode = {
  '30002': 'UBS France',
  '30003': 'Société Générale',
  '30004': 'BNP Paribas',
  '30066': 'La Banque Postale',
  '20041': 'La Banque Postale',
  '10207': 'CIC',
  '10107': 'BRED Banque Populaire',
  '13335': 'Boursorama Banque',
  '11315': 'HSBC France',
  '18206': 'BNP Paribas Personal Finance',
  '15519': 'Fortuneo Banque',
  '17807': 'Orange Bank',
  '14518': 'Hello bank! (BNP Paribas)',
};

/// Испани: 4 оронтой «código de entidad».
String _spanishBankName(String s) {
  if (!s.startsWith('ES') || s.length < 9) return '';
  final ent = s.substring(4, 8);
  if (!RegExp(r'^\d{4}$').hasMatch(ent)) return '';
  return _kEsBankByCode[ent] ?? '';
}

const Map<String, String> _kEsBankByCode = {
  '0049': 'Banco Santander',
  '0182': 'BBVA',
  '2100': 'CaixaBank',
  '0081': 'Banco Sabadell',
  '0128': 'Banco Sabadell',
  '1465': 'ING Spain',
  '3025': 'Popular / Santander legacy',
  '2073': 'Unicaja Banco',
  '0487': 'Bankinter',
};

/// Нидерланд: ВВАН-д 4 үсэгтэй банкны код.
String _dutchBankName(String s) {
  if (!s.startsWith('NL') || s.length < 8) return '';
  final code = s.substring(4, 8);
  if (!RegExp(r'^[A-Z]{4}$').hasMatch(code)) return '';
  final hit = _kNlBankByCode[code];
  if (hit != null) return hit;
  return '';
}

const Map<String, String> _kNlBankByCode = {
  'ABNA': 'ABN AMRO',
  'INGB': 'ING',
  'RABO': 'Rabobank',
  'TRIO': 'Triodos Bank',
  'KNAB': 'Knab',
  'ASNB': 'ASN Bank',
  'BUNQ': 'bunq',
  'SNSB': 'SNS Bank (Volksbank)',
  'DEUT': 'Deutsche Bank (NL)',
  'HAND': 'Handelsbanken',
};

/// Бельги: эхний 3 тоо нь ихэнхдээ банкны код.
String _belgianBankName(String s) {
  if (!s.startsWith('BE') || s.length < 7) return '';
  final code = s.substring(4, 7);
  if (!RegExp(r'^\d{3}$').hasMatch(code)) return '';
  return _kBeBankByCode[code] ?? '';
}

const Map<String, String> _kBeBankByCode = {
  '001': 'BNP Paribas Fortis',
  '103': 'ING Belgium',
  '363': 'ING Belgium',
  '732': 'KBC Bank',
  '735': 'KBC Bank',
  '737': 'KBC Bank',
  '679': 'Argenta',
  '310': 'Belfius',
};

String _germanyBankLabel(String s) {
  if (s.length < 12) return '';
  final blz = s.substring(4, 12);
  if (!RegExp(r'^\d{8}$').hasMatch(blz)) return '';

  final official = GermanBankLookup.nameForBlz(blz);
  if (official != null && official.isNotEmpty) return official;

  return _deBankFromBlzHeuristic(blz);
}

String _deBankFromBlzHeuristic(String blz) {
  const exact = <String, String>{
    '50031010': 'ING',
    '50031000': 'ING',
    '50010517': 'ING',
    '10011001': 'N26 Bank',
    '37040044': 'Commerzbank',
    '20040000': 'Commerzbank',
    '12030000': 'DKB',
    '30020900': 'Targobank',
    '30030300': 'Santander Consumer Bank',
    '74061813': 'PSD Bank',
  };

  final direct = exact[blz];
  if (direct != null) return direct;

  if (blz.startsWith('100100') ||
      blz.startsWith('660100') ||
      blz.startsWith('760100') ||
      blz.startsWith('860100')) {
    return 'Postbank';
  }

  if (blz.startsWith('500310') || blz.startsWith('500105')) {
    return 'ING';
  }

  final mid = blz.substring(2, 5);
  if (mid == '070') return 'Deutsche Bank';
  if (mid == '040') return 'Commerzbank';
  if (mid == '050') return 'Sparkasse';

  if (blz.startsWith('700202') ||
      blz.startsWith('701600') ||
      blz.startsWith('701601') ||
      blz.startsWith('720690')) {
    return 'UniCredit (HypoVereinsbank)';
  }

  return '';
}

String _guessAustriaBank(String s) {
  if (s.length < 9) return '';
  final bc = s.substring(4, 9);
  if (!RegExp(r'^\d{5}$').hasMatch(bc)) return '';

  const map = <String, String>{
    '19000': 'Erste Bank / Sparkasse',
    '19100': 'Raiffeisenbank',
    '12000': 'Bank Austria (UniCredit)',
    '14000': 'easybank',
    '14200': 'easybank',
    '20100': 'Bank Austria (UniCredit)',
  };

  return map[bc] ?? '';
}
