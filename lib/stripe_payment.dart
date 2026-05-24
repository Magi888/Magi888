import 'dart:convert';

import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:http/http.dart' as http;

/// Алдаагүй ажиллуулах: `--dart-define=STRIPE_PUBLISHABLE_KEY=pk_test_...`
const String kStripePublishableKey =
    String.fromEnvironment('STRIPE_PUBLISHABLE_KEY', defaultValue: '');

/// POST `{ amount_cents, currency, metadata, ... }` → `{ "client_secret": ... }`.
const String kStripePaymentIntentUrl = String.fromEnvironment(
  'STRIPE_PAYMENT_INTENT_URL',
  defaultValue: '',
);

/// Вэб Checkout / Voo хуудас (бүрэн URL). Хоосон бол хөтөч нээгдэхгүй.
const String kCheckoutVooUrl = String.fromEnvironment(
  'CHECKOUT_VOO_URL',
  defaultValue: '',
);

const String kStripeBackendBearer = String.fromEnvironment(
  'STRIPE_BACKEND_BEARER',
  defaultValue: '',
);

const String kStripeMerchantCountry = String.fromEnvironment(
  'STRIPE_MERCHANT_COUNTRY',
  defaultValue: 'DE',
);

const String kStripeGpayTestEnvOverride = String.fromEnvironment(
  'STRIPE_GPAY_TEST_ENV',
  defaultValue: '',
);

bool _stripeGooglePayTestEnv(bool liveMode) {
  switch (kStripeGpayTestEnvOverride.toLowerCase()) {
    case 'true':
    case '1':
      return true;
    case 'false':
    case '0':
      return false;
    default:
      return !liveMode;
  }
}

void configureStripePublishableKey() {
  if (kStripePublishableKey.isEmpty) return;
  Stripe.publishableKey = kStripePublishableKey;
}

enum StripeSheetOutcome {
  success,
  canceled,
  failed,
  backendError,
  needsWebCheckout,
}

/// Серверээс ирсэн сүүлийн алдааны товч мэдээлэл (Snackbar-д харуулах).
String? stripePaymentIntentLastError;

String _truncatePiDetail(String s, [int max = 220]) {
  final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (t.length <= max) return t;
  return '${t.substring(0, max)}…';
}

String? _parseStripePiHttpError(String body, int statusCode) {
  try {
    final d = json.decode(body);
    if (d is Map) {
      final err = d['error'];
      if (err != null) {
        return 'HTTP $statusCode: ${_truncatePiDetail(err.toString())}';
      }
      final msg = d['message'];
      if (msg != null) {
        return 'HTTP $statusCode: ${_truncatePiDetail(msg.toString())}';
      }
    }
  } catch (_) {}
  if (body.trim().isEmpty) return 'HTTP $statusCode (хоосон хариу)';
  return 'HTTP $statusCode: ${_truncatePiDetail(body)}';
}

/// Жижиг валютын нэгж (ихэнх валют ×100).
int stripeMinorUnits(double major, String currencyLower) {
  final c = currencyLower.toLowerCase();
  const zeroDec = {
    'bif',
    'clp',
    'djf',
    'gnf',
    'jpy',
    'kmf',
    'krw',
    'mga',
    'pyg',
    'rwf',
    'ugx',
    'vnd',
    'vuv',
    'xaf',
    'xof',
    'xpf'
  };
  if (zeroDec.contains(c)) return major.round();
  return (major * 100).round();
}

BillingDetails? _billingFromPayload(Map<String, dynamic> payloadExtra) {
  final emailRaw = payloadExtra['customer_email'];
  final nameRaw = payloadExtra['customer_name'];
  final phoneRaw = payloadExtra['phone'];

  final email = emailRaw is String && emailRaw.contains('@')
      ? emailRaw.trim()
      : null;
  final name =
      nameRaw is String && nameRaw.trim().isNotEmpty ? nameRaw.trim() : null;
  final phone =
      phoneRaw is String && phoneRaw.trim().isNotEmpty ? phoneRaw.trim() : null;

  if (email == null && name == null && phone == null) return null;
  return BillingDetails(email: email, name: name, phone: phone);
}

/// Stripe Payment Sheet — аппын шар өнгөтэй ойр төстэй харагдах байдал.
const PaymentSheetAppearance kStripePaymentSheetAppearance =
    PaymentSheetAppearance(
  colors: PaymentSheetAppearanceColors(
    primary: Color(0xFFFFD400),
    background: Color(0xFF1E1E1E),
    componentBackground: Color(0xFF2C2C2C),
    componentBorder: Color(0xFF505050),
    primaryText: Color(0xFFFFFFFF),
    secondaryText: Color(0xFFB0B0B0),
    componentText: Color(0xFFFFFFFF),
    placeholderText: Color(0xFF888888),
  ),
);

Future<StripeSheetOutcome> _presentStripePaymentSheetCore({
  required int amountMinorUnits,
  required String currencyLower,
  required Map<String, dynamic> payloadExtra,
  required String merchantDisplayName,
}) async {
  if (kStripePublishableKey.isEmpty) {
    return StripeSheetOutcome.needsWebCheckout;
  }
  final piUrl = kStripePaymentIntentUrl.trim();
  if (piUrl.isEmpty) {
    debugPrint('Stripe: STRIPE_PAYMENT_INTENT_URL хоосон.');
    return StripeSheetOutcome.backendError;
  }

  try {
    stripePaymentIntentLastError = null;
    final uri = Uri.parse(piUrl);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (kStripeBackendBearer.isNotEmpty)
        'Authorization': 'Bearer $kStripeBackendBearer',
    };

    final payload = <String, dynamic>{
      'amount_cents': amountMinorUnits,
      'currency': currencyLower.toLowerCase(),
      ...payloadExtra,
    };

    final res = await http
        .post(uri, headers: headers, body: jsonEncode(payload))
        .timeout(const Duration(seconds: 25));

    if (res.statusCode < 200 || res.statusCode >= 300) {
      stripePaymentIntentLastError =
          _parseStripePiHttpError(res.body, res.statusCode);
      debugPrint('Stripe PI HTTP ${res.statusCode}: ${res.body}');
      return StripeSheetOutcome.backendError;
    }

    final decoded = json.decode(res.body);
    if (decoded is! Map) {
      stripePaymentIntentLastError = 'PI хариу JSON объект биш.';
      return StripeSheetOutcome.backendError;
    }
    final map = Map<String, dynamic>.from(decoded);

    final secret = map['client_secret'] ??
        map['clientSecret'] ??
        map['paymentIntentClientSecret'];
    if (secret == null || secret.toString().isEmpty) {
      stripePaymentIntentLastError =
          'PI хариунд client_secret алга (серверээ шалгана уу).';
      debugPrint('Stripe PI: client_secret олдсонгүй');
      return StripeSheetOutcome.backendError;
    }

    final ekRaw = map['ephemeral_key'] ?? map['ephemeralKey'];
    final cidRaw = map['customer_id'] ?? map['customerId'];
    final ekStr = ekRaw?.toString();
    final cidStr = cidRaw?.toString();
    final hasCustomer = ekStr != null &&
        cidStr != null &&
        ekStr.isNotEmpty &&
        cidStr.isNotEmpty;

    final live = kStripePublishableKey.startsWith('pk_live');
    final curUpper = currencyLower.toUpperCase();

    final googlePay = defaultTargetPlatform == TargetPlatform.android
        ? PaymentSheetGooglePay(
            merchantCountryCode: kStripeMerchantCountry,
            currencyCode: curUpper,
            testEnv: _stripeGooglePayTestEnv(live),
          )
        : null;

    final billingDetails = _billingFromPayload(payloadExtra);

    final SetupPaymentSheetParameters params = hasCustomer
        ? SetupPaymentSheetParameters(
            merchantDisplayName: merchantDisplayName,
            paymentIntentClientSecret: secret.toString(),
            customerEphemeralKeySecret: ekStr,
            customerId: cidStr,
            style: ThemeMode.dark,
            googlePay: googlePay,
            appearance: kStripePaymentSheetAppearance,
            billingDetails: billingDetails,
            // Klarna Pay later / Ratenzahlung зэрэг хойшлогдсон баталгаажилтыг нээх
            allowsDelayedPaymentMethods: true,
          )
        : SetupPaymentSheetParameters(
            merchantDisplayName: merchantDisplayName,
            paymentIntentClientSecret: secret.toString(),
            style: ThemeMode.dark,
            googlePay: googlePay,
            appearance: kStripePaymentSheetAppearance,
            billingDetails: billingDetails,
            allowsDelayedPaymentMethods: true,
          );

    await Stripe.instance.initPaymentSheet(paymentSheetParameters: params);
    await Stripe.instance.presentPaymentSheet();
    return StripeSheetOutcome.success;
  } on StripeException catch (e) {
    debugPrint('StripeException: ${e.error}');
    if (e.error.code == FailureCode.Canceled) {
      return StripeSheetOutcome.canceled;
    }
    final lm = e.error.localizedMessage ?? '';
    if (lm.toLowerCase().contains('cancel')) {
      return StripeSheetOutcome.canceled;
    }
    return StripeSheetOutcome.failed;
  } catch (e, st) {
    stripePaymentIntentLastError = _truncatePiDetail(e.toString(), 180);
    debugPrint('Stripe sheet error: $e\n$st');
    return StripeSheetOutcome.failed;
  }
}

/// Шилжүүлэг (Европ → Монгол): сервер PI үүсгэж, Stripe Sheet нээнэ.
Future<StripeSheetOutcome> presentRemittanceStripePaymentSheet({
  required double amountMajor,
  required String currencyLower,
  required String customerEmail,
  required String customerName,
  required Map<String, String> metadata,
}) async {
  final minor = stripeMinorUnits(amountMajor, currencyLower);
  return _presentStripePaymentSheetCore(
    amountMinorUnits: minor,
    currencyLower: currencyLower,
    merchantDisplayName: 'MoneySENT — Шилжүүлэг',
    payloadExtra: {
      'customer_email': customerEmail,
      'customer_name': customerName,
      'flow': 'remittance',
      'metadata': metadata,
    },
  );
}

/// Voo багц төлбөр.
Future<StripeSheetOutcome> presentVooStripePaymentSheet({
  required double amountEur,
  required String planId,
  required String customerEmail,
  required String customerName,
  required String phone,
}) async {
  final minor = stripeMinorUnits(amountEur, 'eur');
  return _presentStripePaymentSheetCore(
    amountMinorUnits: minor,
    currencyLower: 'eur',
    merchantDisplayName: 'MoneySENT · Voo',
    payloadExtra: {
      'customer_email': customerEmail,
      'customer_name': customerName,
      'phone': phone,
      'plan_id': planId,
      'flow': 'voo',
    },
  );
}
