// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io' show File, Platform;
import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:html/parser.dart' as html;
import 'package:flutter_svg/flutter_svg.dart';

import 'stripe_payment.dart';
import 'iban_bank_guess.dart';
import 'german_bank_lookup.dart';

/// Google Cloud → Credentials → OAuth 2.0 → **Web application** Client ID (`*.apps.googleusercontent.com`).
/// Android-д ихэнх тохиолдолд заавал: энд эсвэл `android/.../strings.xml` → `default_web_client_id`.
/// `flutter run --dart-define=GOOGLE_WEB_CLIENT_ID=xxx.apps.googleusercontent.com`
const String _googleWebClientIdManual =
    '185168005519-4tc6c58a3dod1jhebs89uc8d98fo1dl1.apps.googleusercontent.com';

String _resolvedGoogleWebClientId() {
  final manual = _googleWebClientIdManual.trim();
  if (manual.isNotEmpty) return manual;
  const env = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID', defaultValue: '');
  return env.trim();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  configureStripePublishableKey();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  // runApp хурдан дуудагдана — native splash урт хугацаанд дэлгэц дээр «аварга лого» харагдахгүй.
  // Store-ууд [MoneySENTApp] дотор parallel ачаална.
  runApp(const MoneySENTApp());
}

// ─── User Store ────────────────────────────────────────────────────
class UserStore {
  static String name      = '';
  static String email     = '';
  static String phoneDE   = '';   // Германы утас (+49)
  static String phoneMN   = '';   // Монголын утас (+976)
  /// Герман гэрийн хаяг (Straße, PLZ, Stadt)
  static String addressStreet = '';
  static String addressZip = '';
  static String addressCity = '';
  static String avatarUrl = '';
  /// Баталгаажуулалтын selfie зэргийг аппын Documents-д хуулсан абсолют зам (профайлын зураг).
  static String localAvatarPath = '';
  static String loginType = ''; // 'google' | 'apple' | 'facebook' | 'email' | 'phone'

  // backward compat getter
  static String get phone => phoneMN.isNotEmpty ? phoneMN : phoneDE;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    name      = p.getString('user_name')      ?? '';
    email     = p.getString('user_email')     ?? '';
    phoneDE   = p.getString('user_phone_de')  ?? '';
    phoneMN   = p.getString('user_phone_mn')  ?? p.getString('user_phone') ?? '';
    addressStreet = p.getString('user_addr_street') ?? '';
    addressZip = p.getString('user_addr_plz') ?? '';
    addressCity = p.getString('user_addr_city') ?? '';
    avatarUrl = p.getString('user_avatar')    ?? '';
    localAvatarPath = p.getString('user_local_avatar') ?? '';
    loginType = p.getString('user_logintype') ?? '';
    await ContactVerificationStore.load();
  }

  static Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('user_name',      name);
    await p.setString('user_email',     email);
    await p.setString('user_phone_de',  phoneDE);
    await p.setString('user_phone_mn',  phoneMN);
    await p.setString('user_addr_street', addressStreet);
    await p.setString('user_addr_plz', addressZip);
    await p.setString('user_addr_city', addressCity);
    await p.setString('user_avatar',    avatarUrl);
    await p.setString('user_local_avatar', localAvatarPath);
    await p.setString('user_logintype', loginType);
  }

  /// Баталгаажуулалтын selfie-ийг Documents руу хуулж профайлын зураг болгоно.
  static Future<void> persistLocalAvatarFromPick(String pickedFilePath) async {
    if (kIsWeb || pickedFilePath.isEmpty) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final dest = File('${dir.path}/money_sent_profile_avatar.jpg');
      final bytes = await XFile(pickedFilePath).readAsBytes();
      await dest.writeAsBytes(bytes);
      localAvatarPath = dest.path;
      await save();
    } catch (_) {}
  }

  /// Локал профайл зургийг устгана (гарах үед).
  static Future<void> _removeLocalAvatarFile() async {
    if (kIsWeb || localAvatarPath.isEmpty) return;
    try {
      final f = File(localAvatarPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Гарах үед бүх локал хэрэглэгчийн өгөгдлийг цэвэрлэнэ.
  static Future<void> clearSession() async {
    await _removeLocalAvatarFile();
    name = '';
    email = '';
    phoneDE = '';
    phoneMN = '';
    addressStreet = '';
    addressZip = '';
    addressCity = '';
    avatarUrl = '';
    localAvatarPath = '';
    loginType = '';
    final p = await SharedPreferences.getInstance();
    await p.remove('user_name');
    await p.remove('user_email');
    await p.remove('user_phone_de');
    await p.remove('user_phone_mn');
    await p.remove('user_addr_street');
    await p.remove('user_addr_plz');
    await p.remove('user_addr_city');
    await p.remove('user_avatar');
    await p.remove('user_local_avatar');
    await p.remove('user_logintype');
    // Хуучин нэг утасны түлхүүр
    await p.remove('user_phone');
    await ContactVerificationStore.clearForLogout();
  }

  static Future<void> setGoogle({required String n, required String e, required String avatar}) async {
    name = n; email = e; loginType = 'google';
    // Google-ийн зургийг шууд ашиглана, байхгүй бол initials fallback
    final initials = n.trim().split(' ').map((w) => w.isNotEmpty ? w[0] : '').take(2).join('+');
    avatarUrl = avatar.isNotEmpty ? avatar
        : 'https://ui-avatars.com/api/?name=$initials&background=FFD400&color=000000&bold=true&size=128';
    await save();
    await ContactVerificationStore.applyProviderEmailTrust(e);
  }

  static Future<void> setFacebook({required String n, required String e, required String avatar}) async {
    name = n;
    email = e;
    loginType = 'facebook';
    final initials = n.trim().split(' ').map((w) => w.isNotEmpty ? w[0] : '').take(2).join('+');
    avatarUrl = avatar.isNotEmpty
        ? avatar
        : 'https://ui-avatars.com/api/?name=$initials&background=1877F2&color=FFFFFF&bold=true&size=128';
    await save();
    if (e.trim().isNotEmpty) await ContactVerificationStore.applyProviderEmailTrust(e);
  }

  static String get displayAvatar {
    if (avatarUrl.isNotEmpty) return avatarUrl;
    final nm = name.trim().isNotEmpty ? name.trim() : 'MS';
    final enc = Uri.encodeComponent(nm);
    return 'https://ui-avatars.com/api/?name=$enc&background=FFD400&color=000000&bold=true&size=128';
  }

  /// Локалд хадгалагдсан нэвтрэлт байгаа эсэх (нэвтрэх дэлгэц vs MainShell).
  static bool get hasSignedInProfile {
    if (loginType.trim().isNotEmpty) return true;
    if (email.trim().isNotEmpty) return true;
    if (phoneMN.trim().isNotEmpty || phoneDE.trim().isNotEmpty) return true;
    return false;
  }
}

enum ContactVerifyChannel { email, phoneDE, phoneMN }

class ContactOtpSendResult {
  final String? error;
  /// Backend (`VERIFY_API_BASE`) тохируулаагүй үед код энд буцаана — туршилтад ашиглана.
  final String? fallbackDevCode;
  ContactOtpSendResult({this.error, this.fallbackDevCode});
}

/// Имэйл ба утасны нэг удаагийн кодоор баталгаа.
/// Жинхэнэ SMS/имэйл илгээх: `--dart-define=VERIFY_API_BASE=https://api.example.com` болон POST `/send-otp`.
class ContactVerificationStore {
  static const _kEmailV = 'user_cv_email_verified';
  static const _kPhoneDeV = 'user_cv_ph_de_verified';
  static const _kPhoneMnV = 'user_cv_ph_mn_verified';
  static const _kEmailSnap = 'user_cv_email_snap';
  static const _kPhoneDeSnap = 'user_cv_ph_de_snap';
  static const _kPhoneMnSnap = 'user_cv_ph_mn_snap';

  static bool emailVerified = false;
  static bool phoneDEVerified = false;
  static bool phoneMNVerified = false;
  static String _emailSnap = '';
  static String _phoneDESnap = '';
  static String _phoneMNSnap = '';

  static String _apiBase() {
    const env = String.fromEnvironment('VERIFY_API_BASE', defaultValue: '');
    return env.trim();
  }

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    emailVerified = p.getBool(_kEmailV) ?? false;
    phoneDEVerified = p.getBool(_kPhoneDeV) ?? false;
    phoneMNVerified = p.getBool(_kPhoneMnV) ?? false;
    _emailSnap = p.getString(_kEmailSnap) ?? '';
    _phoneDESnap = p.getString(_kPhoneDeSnap) ?? '';
    _phoneMNSnap = p.getString(_kPhoneMnSnap) ?? '';
  }

  static Future<void> _persistMeta() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEmailV, emailVerified);
    await p.setBool(_kPhoneDeV, phoneDEVerified);
    await p.setBool(_kPhoneMnV, phoneMNVerified);
    await p.setString(_kEmailSnap, _emailSnap);
    await p.setString(_kPhoneDeSnap, _phoneDESnap);
    await p.setString(_kPhoneMnSnap, _phoneMNSnap);
  }

  /// Google / Facebook-ийн имэйлийг баталгаатайд тооцно.
  static Future<void> applyProviderEmailTrust(String e) async {
    final t = e.trim();
    if (t.isEmpty) return;
    _emailSnap = t;
    emailVerified = true;
    await _persistMeta();
  }

  static Future<void> clearForLogout() async {
    emailVerified = false;
    phoneDEVerified = false;
    phoneMNVerified = false;
    _emailSnap = '';
    _phoneDESnap = '';
    _phoneMNSnap = '';
    final p = await SharedPreferences.getInstance();
    await p.remove(_kEmailV);
    await p.remove(_kPhoneDeV);
    await p.remove(_kPhoneMnV);
    await p.remove(_kEmailSnap);
    await p.remove(_kPhoneDeSnap);
    await p.remove(_kPhoneMnSnap);
    for (final c in ContactVerifyChannel.values) {
      await p.remove(_otpKey(c));
      await p.remove(_expKey(c));
    }
  }

  static String _otpKey(ContactVerifyChannel c) => 'user_cv_otp_${c.name}';
  static String _expKey(ContactVerifyChannel c) => 'user_cv_exp_${c.name}';

  static Future<ContactOtpSendResult> sendOtp(ContactVerifyChannel channel, String destination) async {
    final d = destination.trim();
    if (d.isEmpty) return ContactOtpSendResult(error: 'Хаяг хоосон байна.');
    final code = (100000 + Random.secure().nextInt(900000)).toString();
    final p = await SharedPreferences.getInstance();
    final base = _apiBase();
    if (base.isNotEmpty) {
      try {
        final root = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
        final uri = Uri.parse('$root/send-otp');
        final res = await http
            .post(uri,
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({'channel': channel.name, 'to': d, 'code': code}))
            .timeout(const Duration(seconds: 20));
        if (res.statusCode < 200 || res.statusCode >= 300) {
          return ContactOtpSendResult(error: 'Сервер ${res.statusCode}');
        }
        await p.setString(_otpKey(channel), code);
        await p.setInt(
            _expKey(channel), DateTime.now().add(const Duration(minutes: 10)).millisecondsSinceEpoch);
        return ContactOtpSendResult();
      } catch (e) {
        return ContactOtpSendResult(error: 'Илгээх үед алдаа: $e');
      }
    }
    await p.setString(_otpKey(channel), code);
    await p.setInt(
        _expKey(channel), DateTime.now().add(const Duration(minutes: 10)).millisecondsSinceEpoch);
    return ContactOtpSendResult(fallbackDevCode: code);
  }

  static Future<String?> verifyOtp(ContactVerifyChannel channel, String input, {required String destinationSnapshot}) async {
    final p = await SharedPreferences.getInstance();
    final exp = p.getInt(_expKey(channel)) ?? 0;
    if (DateTime.now().millisecondsSinceEpoch > exp) return 'Кодын хугацаа дууссан. Дахин аваарай.';
    final expected = p.getString(_otpKey(channel)) ?? '';
    if (expected.isEmpty) return 'Эхлээд код аваарай.';
    if (input.trim() != expected) return 'Код таарахгүй байна.';
    await p.remove(_otpKey(channel));
    await p.remove(_expKey(channel));
    final snap = destinationSnapshot.trim();
    switch (channel) {
      case ContactVerifyChannel.email:
        emailVerified = true;
        _emailSnap = snap;
        break;
      case ContactVerifyChannel.phoneDE:
        phoneDEVerified = true;
        _phoneDESnap = snap;
        break;
      case ContactVerifyChannel.phoneMN:
        phoneMNVerified = true;
        _phoneMNSnap = snap;
        break;
    }
    await _persistMeta();
    return null;
  }

  static Future<void> reconcileAfterProfileSave() async {
    final e = UserStore.email.trim();
    final de = UserStore.phoneDE.trim();
    final mn = UserStore.phoneMN.trim();
    var changed = false;
    if (emailVerified && e != _emailSnap) {
      emailVerified = false;
      _emailSnap = '';
      changed = true;
    }
    if (phoneDEVerified && de != _phoneDESnap) {
      phoneDEVerified = false;
      _phoneDESnap = '';
      changed = true;
    }
    if (phoneMNVerified && mn != _phoneMNSnap) {
      phoneMNVerified = false;
      _phoneMNSnap = '';
      changed = true;
    }
    if (changed) await _persistMeta();
  }

  static bool isChannelVerified(ContactVerifyChannel c) {
    switch (c) {
      case ContactVerifyChannel.email:
        return emailVerified;
      case ContactVerifyChannel.phoneDE:
        return phoneDEVerified;
      case ContactVerifyChannel.phoneMN:
        return phoneMNVerified;
    }
  }
}

bool _facebookLoginSupportedPlatform() {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}

bool _googleLoginSupportedPlatform() => _facebookLoginSupportedPlatform();

String? _facebookPictureUrl(dynamic picture) {
  if (picture is! Map) return null;
  final data = picture['data'];
  if (data is! Map) return null;
  final url = data['url'];
  return url is String ? url : null;
}

// ─── Biometric Store ───────────────────────────────────────────────
class BiometricStore {
  static final _auth = LocalAuthentication();
  static bool _enabled = false;
  static bool get enabled => _enabled;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _enabled = p.getBool('biometric_enabled') ?? false;
  }

  static Future<void> setEnabled(bool v) async {
    _enabled = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('biometric_enabled', v);
  }

  static Future<bool> isAvailable() async {
    try {
      return await _auth.canCheckBiometrics || await _auth.isDeviceSupported();
    } catch (_) { return false; }
  }

  static Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'MoneySENT нэвтрэхийн тулд биометрик шалгалт хийнэ',
        options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
      );
    } catch (_) { return false; }
  }
}

/// Мэдэгдлийн тохиргоо (локал хадгалалт; ирээдүйд push-тай холбогдоно).
class NotificationPrefsStore {
  static bool _txUpdates = true;
  static bool _promotions = false;

  static bool get txUpdates => _txUpdates;
  static bool get promotions => _promotions;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _txUpdates = p.getBool('notif_tx_updates') ?? true;
    _promotions = p.getBool('notif_promotions') ?? false;
  }

  static Future<void> setTxUpdates(bool v) async {
    _txUpdates = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('notif_tx_updates', v);
  }

  static Future<void> setPromotions(bool v) async {
    _promotions = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('notif_promotions', v);
  }
}

/// Апп анх нээх / урт хугацаанд background-д байсны дараа нэвтрэх түгжээ шаардах эсэх.
bool appSessionLockRequired() =>
    PasscodeStore.isLockActive || BiometricStore.enabled;

// ─── Passcode (Paysend-style 4-digit app lock) ─────────────────────
class PasscodeStore {
  static const _kEnabled = 'passcode_enabled';
  static const _kHash = 'passcode_hash';
  static const _kSalt = 'passcode_salt';

  static bool _enabled = false;
  static String _hash = '';
  static String _salt = '';

  static final _saltRng = Random.secure();

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _enabled = p.getBool(_kEnabled) ?? false;
    _hash = p.getString(_kHash) ?? '';
    _salt = p.getString(_kSalt) ?? '';
    if (_enabled && (_hash.isEmpty || _salt.isEmpty)) {
      _enabled = false;
      _hash = '';
      _salt = '';
      await _persist();
    }
  }

  /// Идэвхтэй бөгөөд хадгалагдсан пасскод байвал апп түгжэгдэнэ.
  static bool get isLockActive => _enabled && _hash.isNotEmpty && _salt.isNotEmpty;

  static String _randomSalt() {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    return List.generate(36, (_) => chars[_saltRng.nextInt(chars.length)]).join();
  }

  static String _digest(String pin) =>
      sha256.convert(utf8.encode('$_salt|$pin')).toString();

  static Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, _enabled);
    if (_hash.isEmpty) {
      await p.remove(_kHash);
      await p.remove(_kSalt);
    } else {
      await p.setString(_kHash, _hash);
      await p.setString(_kSalt, _salt);
    }
  }

  static Future<bool> verify(String pin) async {
    if (!isLockActive) return true;
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) return false;
    return _digest(pin) == _hash;
  }

  static Future<void> enableWithPin(String pin) async {
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) return;
    _salt = _randomSalt();
    _hash = _digest(pin);
    _enabled = true;
    await _persist();
  }

  static Future<bool> tryDisable(String pin) async {
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) return false;
    if (_digest(pin) != _hash) return false;
    _enabled = false;
    _hash = '';
    _salt = '';
    await _persist();
    return true;
  }

  static Future<bool> changePin(String oldPin, String newPin) async {
    if (!RegExp(r'^\d{4}$').hasMatch(newPin)) return false;
    if (_digest(oldPin) != _hash) return false;
    _salt = _randomSalt();
    _hash = _digest(newPin);
    await _persist();
    return true;
  }
}

class _PasscodeDots extends StatelessWidget {
  final int filled;
  const _PasscodeDots({required this.filled});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(
            4,
            (i) => Container(
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < filled ? kYellow : Colors.white12,
                    border: Border.all(color: kYellow.withOpacity(0.45)),
                    boxShadow: i < filled
                        ? [BoxShadow(color: kYellow.withOpacity(0.35), blurRadius: 8)]
                        : null,
                  ),
                )),
      );
}

class _PasscodeKeypad extends StatelessWidget {
  final void Function(String digit) onDigit;
  final VoidCallback onBackspace;
  final VoidCallback? onBiometric;
  final bool showBiometric;

  const _PasscodeKeypad({
    required this.onDigit,
    required this.onBackspace,
    this.onBiometric,
    this.showBiometric = false,
  });

  Widget _key(BuildContext context, String label, VoidCallback? tap) {
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: tap,
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            height: 54,
            child: Center(
              child: label == '⌫'
                  ? Icon(Icons.backspace_outlined, color: Colors.white.withOpacity(0.65), size: 22)
                  : Text(label,
                      style: GoogleFonts.notoSans(
                          color: Colors.white, fontSize: 23, fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget row(List<String> cells) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: cells.map((lab) {
              if (lab == '__bio__') {
                return Expanded(
                  child: SizedBox(
                    height: 54,
                    child: showBiometric && onBiometric != null
                        ? IconButton(
                            onPressed: onBiometric,
                            icon: Icon(Icons.fingerprint_rounded, color: kYellow, size: 34),
                          )
                        : const SizedBox(),
                  ),
                );
              }
              if (lab == '⌫') return _key(context, '⌫', onBackspace);
              return _key(context, lab, () => onDigit(lab));
            }).toList(),
          ),
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row(['1', '2', '3']),
        row(['4', '5', '6']),
        row(['7', '8', '9']),
        row(['__bio__', '0', '⌫']),
      ],
    );
  }
}

class PasscodeLockScreen extends StatefulWidget {
  /// `true`: апп эхлэх / Login-ээс — амжилтанд [MainShell] эсвэл нэвтрэлт байхгүй бол [LoginScreen].
  final bool replaceHomeOnSuccess;

  const PasscodeLockScreen({super.key, this.replaceHomeOnSuccess = true});

  @override
  State<PasscodeLockScreen> createState() => _PasscodeLockScreenState();
}

class _PasscodeLockScreenState extends State<PasscodeLockScreen> {
  String _digits = '';
  bool _bioAvailable = false;

  @override
  void initState() {
    super.initState();
    BiometricStore.isAvailable().then((v) {
      if (mounted) setState(() => _bioAvailable = v);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometricUnlock());
  }

  Future<void> _tryBiometricUnlock() async {
    await Future.delayed(const Duration(milliseconds: 420));
    if (!mounted || !BiometricStore.enabled || !_bioAvailable) return;
    final ok = await BiometricStore.authenticate();
    if (ok && mounted) _onUnlockSuccess();
  }

  void _onUnlockSuccess() {
    if (!mounted) return;
    if (widget.replaceHomeOnSuccess) {
      final next = UserStore.hasSignedInProfile ? const MainShell() : const LoginScreen();
      Navigator.pushReplacement(
          context,
          PageRouteBuilder(
            pageBuilder: (_, a, __) => next,
            transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
            transitionDuration: const Duration(milliseconds: 420)));
    } else {
      Navigator.pop(context);
    }
  }

  void _append(String d) {
    if (_digits.length >= 4) return;
    setState(() => _digits += d);
    if (_digits.length == 4) _submitPin();
  }

  void _backspace() {
    if (_digits.isEmpty) return;
    setState(() => _digits = _digits.substring(0, _digits.length - 1));
  }

  Future<void> _submitPin() async {
    if (!PasscodeStore.isLockActive) {
      setState(() => _digits = '');
      return;
    }
    final ok = await PasscodeStore.verify(_digits);
    if (!mounted) return;
    if (ok) {
      _onUnlockSuccess();
    } else {
      setState(() => _digits = '');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: kRed,
        content: Text('Буруу Passcode', style: GoogleFonts.notoSans(fontWeight: FontWeight.w600)),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final needsPin = PasscodeStore.isLockActive;
    final biometricOnly = !needsPin && BiometricStore.enabled;

    if (biometricOnly) {
      return Scaffold(
        backgroundColor: kBg,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 28),
                msAppLogo(size: 72),
                const SizedBox(height: 20),
                Text(
                  'MoneySENT',
                  style: GoogleFonts.montserrat(
                      color: kYellow, fontWeight: FontWeight.w900, fontSize: 22, letterSpacing: 1),
                ),
                const SizedBox(height: 12),
                Text(
                  'Face ID / хурууны хээ',
                  style: GoogleFonts.notoSans(
                      color: Colors.white70, fontWeight: FontWeight.w800, fontSize: 17),
                ),
                const SizedBox(height: 8),
                Text(
                  _bioAvailable
                      ? 'Нэвтрэхийн тулд доорх товч эсвэл системийн биометрик цонхыг ашиглана уу.'
                      : 'Энэ төхөөрөмж дээр биометрик ашиглах боломжгүй. Профайл → Миний мэдээлэл → Passcode.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 36),
                if (_bioAvailable)
                  IconButton(
                    iconSize: 88,
                    onPressed: _tryBiometricUnlock,
                    icon: Icon(Icons.fingerprint_rounded, color: kYellow, size: 72),
                  ),
                if (_bioAvailable)
                  TextButton(
                    onPressed: _tryBiometricUnlock,
                    child: Text('Дахин шалгах',
                        style: GoogleFonts.notoSans(color: kYellow, fontWeight: FontWeight.w700)),
                  ),
                const Spacer(),
                Text(
                  'Тохиргоо → Профайл → Миний мэдээлэл',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.notoSans(color: Colors.white24, fontSize: 11),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(children: [
            const SizedBox(height: 28),
            msAppLogo(size: 72),
            const SizedBox(height: 20),
            Text('MoneySENT',
                style: GoogleFonts.montserrat(
                    color: kYellow, fontWeight: FontWeight.w900, fontSize: 22, letterSpacing: 1)),
            const SizedBox(height: 8),
            Text('Passcode оруулна уу',
                style: GoogleFonts.notoSans(color: Colors.white70, fontWeight: FontWeight.w700, fontSize: 17)),
            const SizedBox(height: 28),
            _PasscodeDots(filled: _digits.length),
            const SizedBox(height: 36),
            _PasscodeKeypad(
              onDigit: _append,
              onBackspace: _backspace,
              showBiometric: BiometricStore.enabled && _bioAvailable,
              onBiometric: _tryBiometricUnlock,
            ),
            const Spacer(),
            Text('Профайл → Миний мэдээлэл → Passcode',
                style: GoogleFonts.notoSans(color: Colors.white24, fontSize: 11)),
            const SizedBox(height: 16),
          ]),
        ),
      ),
    );
  }
}

enum PasscodeManageKind { enable, changePin, disable }

class PasscodeManageScreen extends StatefulWidget {
  final PasscodeManageKind kind;
  const PasscodeManageScreen({super.key, required this.kind});

  @override
  State<PasscodeManageScreen> createState() => _PasscodeManageScreenState();
}

class _PasscodeManageScreenState extends State<PasscodeManageScreen> {
  String _entry = '';
  int _phase = 0;
  String? _pendingFirst;
  String? _pendingNew;
  String? _oldVerified;

  String get _hint {
    switch (widget.kind) {
      case PasscodeManageKind.enable:
        return _phase == 0 ? '4 орон оруулна уу' : 'Дахин оруулж баталгаажуулна уу';
      case PasscodeManageKind.changePin:
        if (_phase == 0) return 'Одоогийн Passcode';
        if (_phase == 1) return 'Шинэ Passcode';
        return 'Шинэ Passcode-оо дахин оруулна уу';
      case PasscodeManageKind.disable:
        return 'Passcode-оо оруулна уу';
    }
  }

  String get _title {
    switch (widget.kind) {
      case PasscodeManageKind.enable:
        return 'Passcode тохируулах';
      case PasscodeManageKind.changePin:
        return 'Passcode солих';
      case PasscodeManageKind.disable:
        return 'Passcode унтраах';
    }
  }

  Future<void> _onFourDigits(String pin) async {
    switch (widget.kind) {
      case PasscodeManageKind.enable:
        if (_phase == 0) {
          setState(() {
            _pendingFirst = pin;
            _phase = 1;
            _entry = '';
          });
          return;
        }
        if (pin == _pendingFirst) {
          await PasscodeStore.enableWithPin(pin);
          if (mounted) Navigator.pop(context, true);
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              behavior: SnackBarBehavior.floating,
              backgroundColor: kRed,
              content: Text('Тохирохгүй байна. Дахин эхлэнэ үү.', style: GoogleFonts.notoSans()),
            ));
            setState(() {
              _phase = 0;
              _pendingFirst = null;
              _entry = '';
            });
          }
        }
        return;

      case PasscodeManageKind.changePin:
        if (_phase == 0) {
          final ok = await PasscodeStore.verify(pin);
          if (!mounted) return;
          if (!ok) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              behavior: SnackBarBehavior.floating,
              backgroundColor: kRed,
              content: Text('Буруу Passcode', style: GoogleFonts.notoSans()),
            ));
            setState(() => _entry = '');
            return;
          }
          setState(() {
            _oldVerified = pin;
            _phase = 1;
            _entry = '';
          });
          return;
        }
        if (_phase == 1) {
          setState(() {
            _pendingNew = pin;
            _phase = 2;
            _entry = '';
          });
          return;
        }
        if (pin == _pendingNew) {
          final ok = await PasscodeStore.changePin(_oldVerified!, pin);
          if (!mounted) return;
          if (ok) {
            Navigator.pop(context, true);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              behavior: SnackBarBehavior.floating,
              backgroundColor: kRed,
              content: Text('Солих боломжгүй', style: GoogleFonts.notoSans()),
            ));
            setState(() {
              _phase = 0;
              _oldVerified = null;
              _pendingNew = null;
              _entry = '';
            });
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              behavior: SnackBarBehavior.floating,
              backgroundColor: kRed,
              content: Text('Шинэ Passcode таарахгүй байна', style: GoogleFonts.notoSans()),
            ));
            setState(() {
              _phase = 1;
              _pendingNew = null;
              _entry = '';
            });
          }
        }
        return;

      case PasscodeManageKind.disable:
        final ok = await PasscodeStore.tryDisable(pin);
        if (!mounted) return;
        if (ok) {
          await BiometricStore.setEnabled(false);
          if (!mounted) return;
          Navigator.pop(context, true);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: kRed,
            content: Text('Буруу Passcode', style: GoogleFonts.notoSans()),
          ));
          setState(() => _entry = '');
        }
    }
  }

  void _append(String d) {
    if (_entry.length >= 4) return;
    setState(() => _entry += d);
    if (_entry.length == 4) {
      final p = _entry;
      _onFourDigits(p);
    }
  }

  void _backspace() {
    if (_entry.isEmpty) return;
    setState(() => _entry = _entry.substring(0, _entry.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: kYellow, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(_title,
            style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(children: [
            const SizedBox(height: 12),
            Text(_hint,
                textAlign: TextAlign.center,
                style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 14, height: 1.4)),
            const SizedBox(height: 28),
            _PasscodeDots(filled: _entry.length),
            const SizedBox(height: 36),
            _PasscodeKeypad(onDigit: _append, onBackspace: _backspace),
            const Spacer(),
          ]),
        ),
      ),
    );
  }
}

const kYellow = Color(0xFFFFD400); // лого / хар дэлгэцний шартай ижил өтгөн шар
const kYellowDeep = Color(0xFFE6AC00); // градиентын доод ирмэг
const kBg     = Color(0xFF6B6B6B);
const kCard   = Color(0xFF7A7A7A);
const kCard2  = Color(0xFF808080);
const kBorder = Color(0xFF909090);
const kGreen  = Color(0xFF00C9A7);
const kPurple = Color(0xFF7B61FF);
const kRed    = Color(0xFFFF6B6B);
const kBlue   = Color(0xFF4A90E2);

/// App logo
Widget msAppLogo({double size = 96, BoxFit fit = BoxFit.contain}) => Image.asset(
      'assets/logo.png',
      width: size, height: size, fit: fit,
      filterQuality: FilterQuality.high,
      errorBuilder: (_, __, ___) =>
          Icon(Icons.account_balance_wallet_rounded, size: size * 0.58, color: kYellow),
    );

// ─── IBAN validation ─────────────────────────────────────────────
String _normalizeIban(String raw) => raw.replaceAll(RegExp(r'\s'), '').toUpperCase();
bool looksLikeIban(String raw) {
  final s = _normalizeIban(raw);
  return RegExp(r'^[A-Z]{2}\d{2}[A-Z0-9]+$').hasMatch(s) && s.length >= 15 && s.length <= 34;
}
bool isValidIban(String raw) {
  final iban = _normalizeIban(raw);
  if (iban.length < 15 || iban.length > 34) return false;
  if (!RegExp(r'^[A-Z]{2}\d{2}[A-Z0-9]+$').hasMatch(iban)) return false;
  final rearranged = iban.substring(4) + iban.substring(0, 4);
  final buf = StringBuffer();
  for (var i = 0; i < rearranged.length; i++) {
    final c = rearranged.codeUnitAt(i);
    buf.write(c >= 65 && c <= 90 ? c - 55 : String.fromCharCode(c));
  }
  var rem = 0;
  for (final ch in buf.toString().split('')) { rem = (rem * 10 + int.parse(ch)) % 97; }
  return rem == 1;
}

/// IBAN-ийн эхний 2 үсэг → улсын нэр (монголоор).
String _ibanCountryNameFromCode(String code) {
  const map = {
    'DE': 'Герман',
    'AT': 'Австри',
    'BE': 'Бельги',
    'BG': 'Болгар',
    'HR': 'Хорват',
    'CY': 'Кипр',
    'CZ': 'Чех',
    'DK': 'Дани',
    'EE': 'Эстони',
    'ES': 'Испани',
    'FI': 'Финланд',
    'FR': 'Франц',
    'GR': 'Грек',
    'HU': 'Унгар',
    'IE': 'Ирланд',
    'IS': 'Исланд',
    'IT': 'Итали',
    'LT': 'Литва',
    'LU': 'Люксембург',
    'LV': 'Латви',
    'MT': 'Мальта',
    'NL': 'Нидерланд',
    'NO': 'Норвеги',
    'PL': 'Польш',
    'PT': 'Португали',
    'RO': 'Румын',
    'SE': 'Швед',
    'SI': 'Словени',
    'SK': 'Словак',
    'CH': 'Швейцарь',
    'GB': 'Их Британи',
    'LI': 'Лихтенштейн',
    'MC': 'Монако',
    'SM': 'Сан-Марино',
    'VA': 'Ватикан',
    'AD': 'Андорра',
    'MN': 'Монгол',
  };
  return map[code] ?? '';
}

/// Жижиг тайлбарт — ойлгомжтой англи нэр (зарим улс).
String _ibanCountryEnglishHint(String code) {
  const en = {
    'DE': 'Germany',
    'AT': 'Austria',
    'BE': 'Belgium',
    'ES': 'Spain',
    'FR': 'France',
    'IT': 'Italy',
    'NL': 'Netherlands',
    'CH': 'Switzerland',
    'GB': 'United Kingdom',
    'PL': 'Poland',
    'IE': 'Ireland',
    'PT': 'Portugal',
  };
  final n = en[code];
  return n != null ? ' ($n)' : '';
}

/// Хадгалсан дансыг чиглэлээр ялгах — IBAN эсвэл монгол 18 орон.
bool savedAccountIsEuIbanSlot(String accountNo) => looksLikeIban(accountNo);
bool savedAccountIsMongolianLocalSlot(String accountNo) =>
    isMongolianAccountValid(accountNo);

/// Европ руу илгээх хүлээн авагчийн нэр: монгол кирилл / монгол бичиг биш, латин галлигац.
bool recipientNameHasNonLatinScript(String name) {
  for (final unit in name.runes) {
    if (unit >= 0x0400 && unit <= 0x04FF) return true; // Кирилл
    if (unit >= 0x1800 && unit <= 0x18AF) return true; // Монгол бичиг
  }
  return false;
}

// ─── Монгол дансны шалгалт ───────────────────────────────────────
// Монголын ихэнх банк 8–12 оронтой тоон дансны дугаар ашигладаг
// "MN" + тоо хэлбэртэй дансны дугаар (тоон хэсэг 8–12 орон)
String mnAccountDigits(String raw) =>
    raw.replaceAll(RegExp(r'\s'), '').replaceFirst(RegExp(r'^MN', caseSensitive: false), '').replaceAll(RegExp(r'\D'), '');

/// Дансны эхний орон → банк — **арвидыг** (10–19, 20–29…) тодорхойлно (эвриистик).
/// Капитал банк бусад банктай нэгдсэн тул тусад нь үлдээхгүй; орчин үеийн данс ихэнхээр Голомтод холбогдоно.
const Map<String, String> kMongolianBankByFirstDigit = {
  '1': 'Голомт банк',
  '2': 'Хас банк',
  '3': 'Голомт банк',
  '4': 'Худалдаа Хөгжлийн Банк (ХХБ)',
  '5': 'Хаан банк',
  '6': 'Ард кредит банк',
  '7': 'Төрийн банк',
  '8': 'Монголын хөгжлийн банк',
  '9': 'Богд банк',
};

/// Эхний 2 орон → банк. Анхдагч: `1` → 10–19, `5` → 50–59 гэх мэт.
/// Тодорхой хос (`62`, `71` гэх мэт)-ыг солиж болно — доорх `…Overrides` руу нэмээд `_twoDigitBankTable`‑д нэгтгэнэ.
const Map<String, String> kMongolianBankTwoDigitOverrides = {
  // Жишээ: '62': 'Транс банк',
};

Map<String, String> _twoDigitBankTable() => {
      for (final e in kMongolianBankByFirstDigit.entries)
        for (var i = 0; i <= 9; i++) '${e.key}$i': e.value,
      ...kMongolianBankTwoDigitOverrides,
    };

late final Map<String, String> kMongolianBankByTwoDigits =
    Map<String, String>.unmodifiable(_twoDigitBankTable());

/// Монгол IBAN (`MN` + 18 тэмдэгт): **шалгалт 2** + **үндэсний банкны код 4** + **данс 12**.
/// Жишээ: `MN850005005003685858` — эхний 2 нь шалгалт (`85`), дараагийн 4 нь Хаан банк (`0005`).
/// Эх сурвалж: ISO 13616 / Wikipedia «IBAN» (Mongolia: MNkk bbbb c…).
///
/// Баталгаажсан жагсаалтыг [Монголбанк](https://www.mongolbank.mn) зэргээс өргөтгөнө.
const Map<String, String> kMongolianBankByNationalBankCode = {
  '0005': 'Хаан банк',
  // ХХБ — IBAN дээрх 4 оронтой код 0004 (жишээ MN15 0004 …)
  '0004': 'Худалдаа Хөгжлийн Банк (ХХБ)',
  // Голомтын IBAN үндэсний код (жишээ каталогууд)
  '0015': 'Голомт банк',
  // Ард кредит: IBAN дээрх 4 оронтой код 0052 (жишээ MN74 0052 …)
  '0052': 'Ард кредит банк',
};
String destinationAccountForDisplay(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return '—';
  if (looksLikeIban(t)) {
    final iban = _normalizeIban(t);
    final sb = StringBuffer();
    for (var i = 0; i < iban.length; i += 4) {
      if (i > 0) sb.write(' ');
      sb.write(iban.substring(i, min(i + 4, iban.length)));
    }
    return sb.toString();
  }
  return mnAccountDigits(t);
}

/// Хадгалсан дансны жагсаалт / карт дээр: Монгол **18 цифр** бол урд нь **MN** залгана.
/// Бүтэн IBAN бол зайтай формат (destinationAccountForDisplay).
String savedAccountDisplayNo(String accountNo) {
  final t = accountNo.trim();
  if (t.isEmpty) return t;
  if (looksLikeIban(t)) return destinationAccountForDisplay(t);
  final d = mnAccountDigits(t);
  if (RegExp(r'^\d{18}$').hasMatch(d)) return 'MN$d';
  return t;
}

/// Хуулах — зайгүй бүтэн IBAN эсвэл MN+18.
String savedAccountClipboardText(String accountNo) {
  final t = accountNo.trim();
  if (t.isEmpty) return t;
  if (looksLikeIban(t)) return _normalizeIban(t);
  final d = mnAccountDigits(t);
  if (RegExp(r'^\d{18}$').hasMatch(d)) return 'MN$d';
  return t;
}

bool isMongolianAccountValid(String raw) {
  final digits = mnAccountDigits(raw);
  return RegExp(r'^\d{18}$').hasMatch(digits);
}

// Монгол: IBAN-BBAN 18 орон (шаардлага) эсвэл хуучин эхний 2 орон (эвриистик).
String guessMongoBank(String raw) {
  final s = mnAccountDigits(raw);
  if (s.length == 18 && RegExp(r'^\d{18}$').hasMatch(s)) {
    final national = s.substring(2, 6);
    final byIban = kMongolianBankByNationalBankCode[national];
    if (byIban != null) return byIban;
  }
  if (s.length < 2 || s[0] == '0') return '';
  final two = s.substring(0, 2);
  return kMongolianBankByTwoDigits[two] ?? '';
}

String fmtMnt(num n) => NumberFormat('#,###', 'en_US').format(n.round());

// ─── Member Tier систем ───────────────────────────────────────────
enum MemberTier { bronze, silver, gold, platinum }

extension MemberTierInfo on MemberTier {
  String get label {
    switch(this){
      case MemberTier.bronze:   return 'Bronze';
      case MemberTier.silver:   return 'Silver';
      case MemberTier.gold:     return 'Gold';
      case MemberTier.platinum: return 'Platinum';
    }
  }
  String get icon {
    switch(this){
      case MemberTier.bronze:   return '🥉';
      case MemberTier.silver:   return '🥈';
      case MemberTier.gold:     return '👑';
      case MemberTier.platinum: return '💎';
    }
  }
  Color get color {
    switch(this){
      case MemberTier.bronze:   return const Color(0xFFCD7F32);
      case MemberTier.silver:   return const Color(0xFFC0C0C0);
      case MemberTier.gold:     return kYellow;
      case MemberTier.platinum: return const Color(0xFF00D4FF);
    }
  }
  // Шимтгэлийн хөнгөлөлт хувиар
  double get discount {
    switch(this){
      case MemberTier.bronze:   return 0.0;
      case MemberTier.silver:   return 0.05;
      case MemberTier.gold:     return 0.10;
      case MemberTier.platinum: return 0.20;
    }
  }
  // Дараагийн tier-д хүрэх шаардлагатай гүйлгээний тоо
  int get nextTarget {
    switch(this){
      case MemberTier.bronze:   return 10;
      case MemberTier.silver:   return 50;
      case MemberTier.gold:     return 100;
      case MemberTier.platinum: return 9999;
    }
  }
  int get minTx {
    switch(this){
      case MemberTier.bronze:   return 0;
      case MemberTier.silver:   return 10;
      case MemberTier.gold:     return 50;
      case MemberTier.platinum: return 100;
    }
  }
  String get benefit {
    switch(this){
      case MemberTier.bronze:   return 'Үндсэн гишүүн · Шимтгэлийн хөнгөлөлтгүй';
      case MemberTier.silver:   return '5% шимтгэлийн хөнгөлөлт · Хурдан дэмжлэг';
      case MemberTier.gold:     return '10% шимтгэлийн хөнгөлөлт · VIP дэмжлэг · Тусгай ханш';
      case MemberTier.platinum: return '20% хөнгөлөлт · Хувийн менежер · Шуурхай шилжүүлэг';
    }
  }
}

MemberTier getMemberTier(int txCount) {
  if (txCount >= 100) return MemberTier.platinum;
  if (txCount >= 50)  return MemberTier.gold;
  if (txCount >= 10)  return MemberTier.silver;
  return MemberTier.bronze;
}

double calcFee(double amount) {
  if (amount <= 0)    return 0;
  if (amount <= 100)  return 6;
  if (amount <= 1000) return amount * 0.06;
  if (amount <= 5000) return amount * 0.04;
  return amount * 0.03;
}

class MSLogo extends StatelessWidget {
  final double size;
  final bool dark;
  const MSLogo({super.key, this.size = 1.0, this.dark = true});
  @override
  Widget build(BuildContext context) {
    return RichText(
        text: TextSpan(children: [
          TextSpan(text: 'Money',
              style: GoogleFonts.montserrat(color: dark ? Colors.black : Colors.white,
                  fontWeight: FontWeight.w900, fontSize: 20 * size, letterSpacing: -0.5)),
          TextSpan(text: 'SENT',
              style: GoogleFonts.montserrat(color: dark ? Colors.black : kYellow,
                  fontWeight: FontWeight.w900, fontSize: 20 * size, letterSpacing: 1)),
        ]));
  }
}

// ─── Rate Service ─────────────────────────────────────────────────
class RateService {
  // Fallback ханш (Хаан Банк api · бэлэн cashBuy/cashSell ойролцоогоор)
  static final Map<String, double> _buy = {
    'USD': 3567, 'EUR': 4120, 'JPY': 22.19, 'CHF': 4469,
    'GBP': 4734, 'HKD': 452.8, 'CNY': 523.7, 'KRW': 2.28,
    'CAD': 2566, 'AUD': 2505, 'CZK': 168.0,
  };
  static final Map<String, double> _sell = {
    'USD': 3595, 'EUR': 4224, 'JPY': 22.76, 'CHF': 4644,
    'GBP': 4867, 'HKD': 460.6, 'CNY': 530.3, 'KRW': 2.48,
    'CAD': 2637, 'AUD': 2607, 'CZK': 176.0,
  };

  static DateTime? _lastFetch;
  static bool _fetching = false;
  static Timer? _timer;

  // Дуудагчид UI refresh хийлгэхийн тулд callback
  static VoidCallback? onRatesUpdated;

  static Map<String, double> get buyRates  => _buy;
  static Map<String, double> get sellRates => _sell;

  static String get lastUpdated => _lastFetch == null
      ? 'Шинэчлэгдээгүй'
      : '${_lastFetch!.hour.toString().padLeft(2,'0')}:${_lastFetch!.minute.toString().padLeft(2,'0')}';

  /// Апп эхлэхэд нэг удаа дуудна — цаашид 5 минут тутам автомат татна
  static void startAutoFetch({VoidCallback? onUpdate}) {
    onRatesUpdated = onUpdate;
    fetch();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => fetch());
  }

  static void stopAutoFetch() => _timer?.cancel();

  static Future<void> fetch() async {
    if (_fetching) return;
    _fetching = true;
    try {
      // 1. Хаан Банкны JSON (эхлээд албан api — cashBuyRate/cashSellRate = бэлэн)
      final apis = [
        'https://api.khanbank.com/v1/rates',
        'https://www.khanbank.com/api/v1/rate',
        'https://www.khanbank.com/mn/personal/rate',
      ];

      for (final url in apis) {
        try {
          final res = await http.get(Uri.parse(url), headers: {
            'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36',
            'Accept': 'application/json, text/html',
          }).timeout(const Duration(seconds: 8));

          if (res.statusCode != 200 || res.body.isEmpty) continue;

          // JSON хариу
          if (res.headers['content-type']?.contains('json') == true ||
              res.body.trimLeft().startsWith('[') ||
              res.body.trimLeft().startsWith('{')) {
            if (_parseJson(res.body)) {
              _lastFetch = DateTime.now();
              onRatesUpdated?.call();
              debugPrint('✅ Khan rates updated from $url at ${lastUpdated}');
              return;
            }
          }

          // HTML хариу — table parse
          if (_parseHtml(res.body)) {
            _lastFetch = DateTime.now();
            onRatesUpdated?.call();
            debugPrint('✅ Khan rates parsed from HTML at ${lastUpdated}');
            return;
          }
        } catch (e) {
          debugPrint('Rate fetch attempt $url failed: $e');
        }
      }
      debugPrint('⚠️ All rate sources failed, using fallback');
    } finally {
      _fetching = false;
    }
  }

  /// JSON-оос ханш унших. Эхлээд **бэлэн** (`cashBuyRate` / `cashSellRate`),
  /// байхгүй эсвэл буруу бол `buyRate` / `sellRate` (ихэвчлэн бэлэн бус)-д унагана.
  static bool _parseJson(String body) {
    try {
      final decoded = json.decode(body);
      final list = decoded is List ? decoded : (decoded is Map ? decoded['data'] ?? decoded['rates'] ?? [] : []);
      if (list is! List || list.isEmpty) return false;
      int count = 0;
      for (final raw in list) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final cur = (item['currency'] ?? item['code'] ?? item['cur'] ?? '').toString().toUpperCase();
        if (!_buy.containsKey(cur)) continue;

        final cashBuy = _toDouble(item['cashBuyRate']);
        final cashSell = _toDouble(item['cashSellRate']);
        final trBuy = _toDouble(item['buyRate'] ?? item['buy'] ?? item['avax'] ?? item['buying']);
        final trSell = _toDouble(item['sellRate'] ?? item['sell'] ?? item['zarah'] ?? item['selling']);

        double? effBuy;
        double? effSell;
        if (cashBuy != null &&
            cashSell != null &&
            cashBuy > 0 &&
            cashSell >= cashBuy) {
          effBuy = cashBuy;
          effSell = cashSell;
        } else if (trBuy != null &&
            trSell != null &&
            trBuy > 0 &&
            trSell >= trBuy) {
          effBuy = trBuy;
          effSell = trSell;
        }
        if (effBuy != null && effSell != null) {
          _buy[cur] = effBuy;
          _sell[cur] = effSell;
          count++;
        }
      }
      return count > 0;
    } catch (_) {
      return false;
    }
  }

  static bool _parseHtml(String body) {
    try {
      final document = html.parse(body);
      final allCurs = [..._buy.keys];
      int count = 0;
      for (final row in document.querySelectorAll('tr')) {
        final cols = row.querySelectorAll('td');
        if (cols.length < 3) continue;
        String cur = '';
        for (final col in cols) {
          final t = col.text.trim().toUpperCase();
          if (allCurs.contains(t)) { cur = t; break; }
        }
        if (cur.isEmpty) continue;
        final nums = <double>[];
        for (final col in cols) {
          final v = _toDouble(col.text.replaceAll(',', '').replaceAll('₮', '').replaceAll(' ', '').trim());
          if (v != null && v > 0) nums.add(v);
        }
        if (nums.length >= 2) {
          final buy  = nums[nums.length >= 3 ? nums.length - 2 : 0];
          final sell = nums[nums.length - 1];
          if (buy > 0 && sell > 0 && sell >= buy) {
            _buy[cur] = buy; _sell[cur] = sell; count++;
          }
        }
      }
      return count > 0;
    } catch (_) { return false; }
  }

  static double? _toDouble(dynamic v) =>
      v == null ? null : double.tryParse(v.toString().replaceAll(',', '').trim());
} // end RateService

// ─── Saved Account ────────────────────────────────────────────────
class SavedAccount {
  final String bank, accountNo, name;
  const SavedAccount({required this.bank, required this.accountNo, required this.name});
  Map<String,dynamic> toJson() => {'bank':bank,'accountNo':accountNo,'name':name};
  factory SavedAccount.fromJson(Map<String,dynamic> j) =>
      SavedAccount(bank:j['bank'], accountNo:j['accountNo'], name:j['name']??'');
}

class AccountStore {
  /// Хуучин ганц түлхүүр — нэг удаа одоогийн нэвтэрсэн хэрэглэгч рүү шилжүүлнэ.
  static const _legacyKey = 'saved_accounts';
  static List<SavedAccount> _accounts = [];
  static List<SavedAccount> get accounts => _accounts;

  /// Имэйл эсвэл утас — хэрэглэгч тус бүрт тусдаа жагсаалт.
  static String _userScopeId() {
    final em = UserStore.email.trim().toLowerCase();
    if (em.isNotEmpty) return em;
    final mn = UserStore.phoneMN.trim().replaceAll(RegExp(r'\D'), '');
    if (mn.isNotEmpty) return 'mn:$mn';
    final de = UserStore.phoneDE.trim().replaceAll(RegExp(r'\D'), '');
    if (de.isNotEmpty) return 'de:$de';
    return '';
  }

  static String? _prefsKey() {
    final id = _userScopeId();
    if (id.isEmpty) return null;
    final enc = base64Url.encode(utf8.encode(id)).replaceAll('=', '');
    return 'saved_accounts_v2_$enc';
  }

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final key = _prefsKey();
    if (key == null) {
      _accounts = [];
      return;
    }
    var raw = prefs.getStringList(key) ?? [];
    if (raw.isEmpty) {
      final legacy = prefs.getStringList(_legacyKey) ?? [];
      if (legacy.isNotEmpty) {
        raw = List<String>.from(legacy);
        await prefs.setStringList(key, raw);
        await prefs.remove(_legacyKey);
      }
    }
    _accounts = raw.map((s) => SavedAccount.fromJson(json.decode(s))).toList();
  }

  static Future<void> _persist() async {
    final key = _prefsKey();
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(key, _accounts.map((a) => json.encode(a.toJson())).toList());
  }

  static Future<void> save(SavedAccount acc) async {
    if (_prefsKey() == null) return;
    if (_accounts.any((a) => a.accountNo == acc.accountNo)) return;
    _accounts.insert(0, acc);
    await _persist();
  }

  static Future<void> remove(String accountNo) async {
    if (_prefsKey() == null) return;
    _accounts.removeWhere((a) => a.accountNo == accountNo);
    await _persist();
  }
}

// ─── Tracking ─────────────────────────────────────────────────────
enum TxStep {
  sent,
  received,
  processing,
  converting,
  sending,
  awaiting_admin_confirm,
  delivered,
}

extension TxStepInfo on TxStep {
  /// `dir`: `eu_to_mn` | `mn_to_eu`
  String labelFor(String dir) {
    final toMn = dir == 'eu_to_mn';
    switch (this) {
      case TxStep.sent:
        return 'Илгээгдсэн';
      case TxStep.received:
        return 'Хүлээн авсан';
      case TxStep.processing:
        return 'Боловсруулж байна';
      case TxStep.converting:
        return 'Хөрвүүлж байна';
      case TxStep.sending:
        return toMn ? 'Монгол руу илгээж байна' : 'Европ руу илгээж байна';
      case TxStep.awaiting_admin_confirm:
        return 'Админ баталгаажуулалт';
      case TxStep.delivered:
        return 'Хүргэгдсэн ✓';
    }
  }

  String descFor(String dir) {
    final toMn = dir == 'eu_to_mn';
    switch (this) {
      case TxStep.sent:
        return 'Шилжүүлэг бүртгэгдлээ';
      case TxStep.received:
        return toMn ? 'MoneySENT данс руу орлоо' : 'Төлбөр хүлээн авлаа';
      case TxStep.processing:
        return 'Баталгаажуулж шалгаж байна';
      case TxStep.converting:
        return toMn ? 'Хаан банкны ханшаар хөрвүүлж байна' : 'Төгрөгийг EUR-д хөрвүүлж байна';
      case TxStep.sending:
        return toMn
            ? 'Таны Монгол банкны данс руу төгрөг буух болж байна'
            : 'Таны Европын дансанд EUR шилжих болж байна';
      case TxStep.awaiting_admin_confirm:
        return 'Оператор таны гүйлгээг шалгаад баталгаажуултал та түр хүлээнэ үү.';
      case TxStep.delivered:
        return toMn ? 'Данс руу амжилттай орлоо! 🎉' : 'Европын дансанд EUR амжилттай орлоо! 🎉';
    }
  }

  String get eta { switch(this) {
    case TxStep.sent:                    return '0 мин';
    case TxStep.received:                return '2-5 мин';
    case TxStep.processing:              return '5-10 мин';
    case TxStep.converting:              return '10-15 мин';
    case TxStep.sending:                 return '15-25 мин';
    case TxStep.awaiting_admin_confirm: return 'Админоос хамаарна';
    case TxStep.delivered:               return '—';
  }}
  IconData get icon { switch(this) {
    case TxStep.sent:                    return Icons.send_rounded;
    case TxStep.received:                return Icons.account_balance_wallet_rounded;
    case TxStep.processing:              return Icons.manage_search_rounded;
    case TxStep.converting:              return Icons.currency_exchange_rounded;
    case TxStep.sending:                 return Icons.rocket_launch_rounded;
    case TxStep.awaiting_admin_confirm: return Icons.verified_user_outlined;
    case TxStep.delivered:               return Icons.check_circle_rounded;
  }}
}

class TxRecord {
  final String id, date, from, to, currency;
  final String dir;       // 'eu_to_mn' | 'mn_to_eu'
  final String payId;     // 'wise' | 'n26' | 'khanbank' ...
  final String accountNo; // хүлээн авагчийн данс
  final String destName;  // хүлээн авагчийн нэр
  /// Манай EUR/SEPA данс руу шилжүүлэхэд заавал оруулах reference (Send.mn / Ria-тай адил урсгал).
  final String referenceCode;
  final bool reverseMode;
  /// eu_to_mn: илгээсэн дүн (валют `currency`); mn_to_eu: хүлээн авах EUR.
  final double amount, fee;
  /// eu_to_mn: Монгол дансанд очих MNT; mn_to_eu: төлсөн нийт MNT.
  final int mnt;
  TxStep currentStep;
  final List<MapEntry<TxStep, DateTime>> stepHistory;
  final SavedAccount? destAccount;
  /// Хэрэглэгч банкны аппаас EUR шилжүүлж дууслаа гэж MoneySENT дээр дарсан (Revolut-д орсон эсэхийг батлахгүй).
  bool userDeclaredBankSepaSent;
  /// MN→EU гар/Голомт урсгал: ₮ манай Хаан дансанд шилжүүлснээ апп дээр мэдэгдсэн эсэх.
  bool userDeclaredMntBankSent;
  TxRecord({
    required this.id,
    required this.date,
    required this.from,
    required this.to,
    required this.currency,
    required this.amount,
    required this.fee,
    required this.mnt,
    this.dir = 'eu_to_mn',
    this.payId = 'wise',
    this.accountNo = '',
    this.destName = '',
    this.referenceCode = '',
    this.reverseMode = false,
    this.destAccount,
    this.currentStep = TxStep.sent,
    this.userDeclaredBankSepaSent = false,
    this.userDeclaredMntBankSent = false,
    List<MapEntry<TxStep, DateTime>>? stepHistory,
  }) : stepHistory = stepHistory ?? [MapEntry(TxStep.sent, DateTime.now())];
  bool get isCompleted => currentStep == TxStep.delivered;
  int  get stepIndex   => TxStep.values.indexOf(currentStep);
}

/// Харуулалтад ашиглах урсгал (`dir` буруу үлдсэн ч `from`/`to` зөв бол энд тааруулна).
String txFlowDir(TxRecord tx) {
  if (tx.from == 'Монгол' && tx.to == 'Европ') return 'mn_to_eu';
  if (tx.from == 'Европ' && tx.to == 'Хаан Банк') return 'eu_to_mn';
  return tx.dir;
}

/// mn_to_eu хуучин алдаатай хадгалалт: `amount`-д MNT, `mnt`-д EUR дүн буруу хадгалагдсан тохиолдол.
bool legacyMnToEuMisstored(TxRecord tx) {
  if (txFlowDir(tx) != 'mn_to_eu') return false;
  // Шинэ семантик: төлсөн MNT (`mnt`) нь EUR авалтаас ханшийн дагуу их байна.
  if (tx.mnt >= (tx.amount * 80).round()) return false;
  return true;
}

String txHeroPrimary(TxRecord tx) {
  if (txFlowDir(tx) == 'mn_to_eu') {
    if (legacyMnToEuMisstored(tx)) {
      return '₮ ${fmtMnt(tx.amount.round())}';
    }
    return '₮ ${fmtMnt(tx.mnt)}';
  }
  return '${tx.amount.toStringAsFixed(0)} ${tx.currency}';
}

String txHeroSecondary(TxRecord tx) {
  if (txFlowDir(tx) == 'mn_to_eu') {
    if (legacyMnToEuMisstored(tx)) {
      return '→ € ${tx.mnt}';
    }
    return '→ € ${tx.amount.toStringAsFixed(2)}';
  }
  return '→ ₮ ${fmtMnt(tx.mnt)}';
}

/// Жагсаалтын баруун багана — гол дүн.
String txListPrimaryAmt(TxRecord tx) {
  if (txFlowDir(tx) == 'mn_to_eu') {
    if (legacyMnToEuMisstored(tx)) {
      return '₮ ${fmtMnt(tx.amount.round())}';
    }
    return '₮ ${fmtMnt(tx.mnt)}';
  }
  return '${tx.amount.toStringAsFixed(0)} ${tx.currency}';
}

String txListSecondaryAmt(TxRecord tx) {
  if (txFlowDir(tx) == 'mn_to_eu') {
    if (legacyMnToEuMisstored(tx)) {
      return '€ ${tx.mnt}';
    }
    return '€ ${tx.amount.toStringAsFixed(2)}';
  }
  return '₮ ${fmtMnt(tx.mnt)}';
}

String txSnackSubtitle(TxRecord tx) {
  if (txFlowDir(tx) == 'mn_to_eu') {
    if (legacyMnToEuMisstored(tx)) {
      return '₮ ${fmtMnt(tx.amount.round())} төлж € ${tx.mnt} хүлээн авлаа';
    }
    return '₮ ${fmtMnt(tx.mnt)} төлж € ${tx.amount.toStringAsFixed(2)} хүлээн авлаа';
  }
  return '${tx.amount.toStringAsFixed(0)} ${tx.currency} → ₮ ${fmtMnt(tx.mnt)} данс руу орлоо';
}

String txCompletedBanner(TxRecord tx) {
  if (txFlowDir(tx) == 'mn_to_eu') {
    if (legacyMnToEuMisstored(tx)) {
      return '€ ${tx.mnt} Европын дансанд очлоо';
    }
    return '€ ${tx.amount.toStringAsFixed(2)} Европын дансанд очлоо';
  }
  return '₮ ${fmtMnt(tx.mnt)} таны дансанд орлоо';
}

/// MSCard «Хүлээн авах» мөр — eu_to_mn үед MNT, mn_to_eu үед EUR.
String txReceiveSummaryLine(TxRecord tx) {
  if (txFlowDir(tx) == 'mn_to_eu') {
    if (legacyMnToEuMisstored(tx)) return '€ ${tx.mnt}';
    return '€ ${tx.amount.toStringAsFixed(2)}';
  }
  return '₮ ${fmtMnt(tx.mnt)}';
}

String txAdminAmountLine(TxRecord tx) {
  if (txFlowDir(tx) == 'mn_to_eu') {
    if (legacyMnToEuMisstored(tx)) {
      return '₮ ${fmtMnt(tx.amount.round())} → € ${tx.mnt}';
    }
    return '₮ ${fmtMnt(tx.mnt)} → € ${tx.amount.toStringAsFixed(2)}';
  }
  return '${tx.amount.toStringAsFixed(2)} ${tx.currency} → ₮ ${fmtMnt(tx.mnt)}';
}

// ─── Payment Methods ─────────────────────────────────────────────
class PayMethod {
  final String id, name, icon, url;
  final Color color;
  /// Орчин үеийн лого — Simple Icons CDN (`cdn.simpleicons.org`). Null бол `icon` текст/эмодзи.
  final String? brandSlug;

  /// Хүлээн авах SEPA данс (Revolut · Герман) — байгууллагын нэр + эзэмшигч.
  static const sepaCompanyName = 'PROMON Solutions';
  static const sepaAccountHolder = 'Munkhmandal Jargalsaikhan';
  static const wiseIban = 'DE55 1001 0178 9052 6702 69';
  static const wiseBic = 'REVODEB2';

  /// Хуучин кодонд нэг мөрөөр харуулахад (IBAN бүлэг ижил).
  static const wiseName = sepaCompanyName;
  static const n26Iban = wiseIban;
  static const n26Bic = wiseBic;

  /// Банкны аппанд талбарууд руу буулгаж наахад зориулсан бүтэн текст.
  static String sepaBankAppPasteBundle({
    required String amountDisplay,
    required String referenceCode,
  }) {
    final iban = wiseIban.replaceAll(' ', '');
    return 'IBAN: $iban\n'
        'BIC: $wiseBic\n'
        'Хүлээн авагч (байгууллага): $sepaCompanyName\n'
        'Эзэмшигч: $sepaAccountHolder\n'
        'Дүн: $amountDisplay\n'
        'Reference / тайлбар: $referenceCode';
  }

  /// Монгол → Европ «Гараар шилжүүлэх»: ₮ эхлээд манай Хаан дансанд → админ шалгаад EU IBAN-р гүйлгээ.
  static const mnManualDepositAccount = 'MN850005005003685858';
  static const mnManualDepositBankName = 'Хаан банк';
  static const mnManualDepositHolder = 'Мөнхмандал Жаргалсайхан';
  /// Хаан банкны апп дээр харагдах богино дансны дугаар.
  static const mnManualDepositAppShort = '5003685858';

  static String mnManualBankPasteBundle({
    required String mntAmountDisplay,
    required String mntAmountPlain,
    required String depositReference,
  }) {
    final acct = mnManualDepositAccount.replaceAll(' ', '');
    return '--- MoneySENT · Хаан банк хүлээн авах ---\n'
        'Богино данс №: $mnManualDepositAppShort\n'
        'Данс бүтэн: $acct\n'
        'Банк: $mnManualDepositBankName\n'
        'Хүлээн авагч: $mnManualDepositHolder\n'
        'Дүн (дэлгэц): $mntAmountDisplay\n'
        'Дүн (зөвхөн тоо, дүн талбарт): $mntAmountPlain\n'
        'Гүйлгээний утга: $depositReference\n'
        'Reference 2 / нэмэлт талбар: $depositReference\n'
        '--- Аппын талбар бүрт дээрхийг тус тусад нь оруулна уу ---';
  }

  const PayMethod({
    required this.id,
    required this.name,
    required this.icon,
    required this.url,
    required this.color,
    this.brandSlug,
  });
}

/// Олон өнгийн албан ёсны лого — CDN-д өнгө өгөлгүй ачаална.
const _simpleIconSlugNoTint = {'googlepay', 'paypal'};

String _payMethodBrandSvgUri(PayMethod m) {
  final slug = m.brandSlug!;
  if (_simpleIconSlugNoTint.contains(slug)) {
    return 'https://cdn.simpleicons.org/$slug';
  }
  final hex = (m.color.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
  return 'https://cdn.simpleicons.org/$slug/$hex';
}

/// Банкны албан домэйн — Clearbit logo API (logo.clearbit.com).
String? payMethodClearbitHost(PayMethod m) {
  final u = m.url.trim();
  if (u.isEmpty) return null;
  try {
    var host = Uri.parse(u).host.toLowerCase();
    if (host.startsWith('www.')) host = host.substring(4);
    return host.isEmpty ? null : host;
  } catch (_) {
    return null;
  }
}

/// Сайн чанартай favicon (ихэнх банкны албан домэйнд Clearbit-ээс илүү тогтвортой).
String payMethodGoogleFaviconUrl(String host) =>
    'https://www.google.com/s2/favicons?sz=128&domain=${Uri.encodeComponent(host)}';

/// Android: Голомтын апп суулгасан эсэхийг `getLaunchIntentForPackage`-аар шалгаж дараалан нээх.
/// Зөв package ID нь төхөөрөмж болон Store-ийн хувилбараас хамаарна — жагсаалтад нэмж болно.
const List<String> kGolomtAndroidPackageCandidates = [
  'mn.golomtbank.gbmobile',
  'mn.golomtbank.golomtbankdigitalbanking',
  'mn.golomtbank.digitalbanking',
  'mn.golomtbank.mobile',
];

const MethodChannel _androidAppLauncherChannel =
    MethodChannel('com.moneysent/app_launcher');

Future<String?> _tryLaunchFirstInstalledAndroidPackage(
    List<String> packageNames) async {
  if (kIsWeb || !Platform.isAndroid) return null;
  try {
    final Object? res = await _androidAppLauncherChannel.invokeMethod<Object?>(
      'launchFirstInstalled',
      packageNames,
    );
    if (res is String && res.isNotEmpty) return res;
  } catch (e, st) {
    debugPrint('launchFirstInstalled: $e\n$st');
  }
  return null;
}

/// MN→EU «Голомт» горимд хэрэглэгчийг банкны апп руу чиглүүлнэ.
Future<void> launchGolomtBankMobileApp() async {
  // Android: натив руу дамжуулах — зөвхөн Play Store биш, суулгасан аппыг шууд нээнэ.
  if (!kIsWeb && Platform.isAndroid) {
    final started = await _tryLaunchFirstInstalledAndroidPackage(
        kGolomtAndroidPackageCandidates);
    if (started != null) return;

    for (final scheme in ['golomtbank://', 'golomtbank://open', 'golomt://']) {
      final u = Uri.parse(scheme);
      try {
        if (await launchUrl(u, mode: LaunchMode.externalApplication)) return;
      } catch (_) {}
    }

    // `details?id=` буруу package → Play Store «Item not found». Хайлт ашиглана.
    final playSearch = Uri.parse(
        'https://play.google.com/store/search?q=Golomt+Digital+Banking&c=apps');
    try {
      if (await canLaunchUrl(playSearch) &&
          await launchUrl(playSearch, mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (_) {}
  }

  if (!kIsWeb && Platform.isIOS) {
    for (final scheme in ['golomtbank://', 'golomt://']) {
      final u = Uri.parse(scheme);
      try {
        if (await canLaunchUrl(u) &&
            await launchUrl(u, mode: LaunchMode.externalApplication)) {
          return;
        }
      } catch (_) {}
    }
  }

  final site = Uri.parse('https://www.golomtbank.mn/');
  if (await canLaunchUrl(site)) {
    await launchUrl(site, mode: LaunchMode.externalApplication);
  }
}

Widget _payMethodLogoFallback(PayMethod method, double size) {
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: method.color.withOpacity(0.22),
      borderRadius: BorderRadius.circular(size * 0.22),
    ),
    child: Icon(Icons.account_balance_rounded, color: method.color, size: size * 0.52),
  );
}

Widget payMethodBrandAvatar(PayMethod method, {double size = 28}) {
  final slug = method.brandSlug;
  if (slug != null && slug.isNotEmpty) {
    final uri = _payMethodBrandSvgUri(method);
    final svg = SvgPicture.network(
      uri,
      fit: BoxFit.contain,
      placeholderBuilder: (_) => Center(
        child: SizedBox(
          width: size * 0.45,
          height: size * 0.45,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: method.color.withOpacity(0.45),
          ),
        ),
      ),
    );
    final padded = slug == 'applepay'
        ? DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(size * 0.22),
            ),
            child: Padding(
              padding: EdgeInsets.all(size * 0.12),
              child: svg,
            ),
          )
        : svg;
    return SizedBox(
      width: size,
      height: size,
      child: padded,
    );
  }
  final host = payMethodClearbitHost(method);
  if (host != null) {
    Widget logoNet(String url, Widget Function() onError) {
      return Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => onError(),
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Center(
            child: SizedBox(
              width: size * 0.42,
              height: size * 0.42,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: method.color.withOpacity(0.45),
              ),
            ),
          );
        },
      );
    }

    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.2),
        child: logoNet(payMethodGoogleFaviconUrl(host), () => logoNet(
              'https://logo.clearbit.com/$host',
              () => logoNet(
                    'https://icons.duckduckgo.com/ip3/$host.ico',
                    () => _payMethodLogoFallback(method, size),
                  ),
            )),
      ),
    );
  }
  if (method.id == 'manuel' || method.id == 'mn_manuel') {
    return Icon(Icons.swap_horiz_rounded, color: method.color, size: size * 0.92);
  }
  if (method.id == 'loan_install') {
    return Icon(Icons.savings_rounded, color: method.color, size: size * 0.92);
  }
  if (method.id == 'sepa') {
    return Icon(Icons.account_balance_rounded, color: method.color, size: size * 0.92);
  }
  return Text(method.icon, style: TextStyle(fontSize: size * 0.85));
}

const _euMethods = [
  PayMethod(id:'google_pay', name:'Google Pay', icon:'G', color:Color(0xFF4285F4), url:'', brandSlug:'googlepay'),
  PayMethod(id:'apple_pay', name:'Apple Pay', icon:'🍏', color:Color(0xFFFFFFFF), url:'', brandSlug:'applepay'),
  PayMethod(id:'paypal', name:'PayPal', icon:'🅿️', color:Color(0xFF003087), url:'https://www.paypal.me/munkhmandal', brandSlug:'paypal'),
  PayMethod(id:'klarna', name:'Klarna', icon:'💗', color:Color(0xFFB68FF7), url:'', brandSlug:'klarna'),
  PayMethod(id:'sepa', name:'SEPA', icon:'🏦', color:Color(0xFF00C9A7), url:'', brandSlug:'revolut'),
  PayMethod(id:'manuel', name:'Гар аргаар шилжүүлэх', icon:'', color:Color(0xFF00B9FF), url:''),
  PayMethod(id:'loan_install', name:'Зээлээр шилжүүлэх', icon:'💳', color:Color(0xFFB388FF), url:''),
];

const _mnMethods = [
  PayMethod(id:'khanbank',  name:'Хаан Банк',    icon:'🏦', color:Color(0xFF005B9A), url:'https://www.khanbank.com'),
  /// MN→EU: Хаан дансанд ₮ хүлээн авах («гараар» урсгалтай ижил) + Голомт апп руу чиглүүлнэ.
  PayMethod(id:'golomt',    name:'Голомт Банк',  icon:'🏛️', color:Color(0xFFE31837), url:'https://www.golomtbank.mn/'),
  PayMethod(id:'tdb',       name:'ХХБ (TDB)',    icon:'🏢', color:Color(0xFF1A3A6E), url:'https://tdbm.mn'),
  PayMethod(id:'qpay',      name:'QPay',         icon:'📱', color:Color(0xFF00A651), url:'https://qpay.mn'),
  PayMethod(id:'socialpay', name:'SocialPay',    icon:'💙', color:Color(0xFF1877F2), url:'https://socialpay.mn'),
  PayMethod(id:'ardapp',    name:'Ard App',      icon:'🔴', color:Color(0xFFE31837), url:'https://ard.mn'),
  PayMethod(id:'mn_manuel', name:'Гараар шилжүүлэх', icon:'', color:Color(0xFF00B9FF), url:''),
  PayMethod(id:'loan_install', name:'Зээлээр шилжүүлэх (3 хуваалт)', icon:'💳', color:Color(0xFFB388FF), url:''),
];

const _quickEUR = [10.0,20.0,50.0,100.0,250.0,500.0];
const _quickMNT = [50000.0,100000.0,200000.0,500000.0,1000000.0,2000000.0];

// ─── App ─────────────────────────────────────────────────────────
class MoneySENTApp extends StatefulWidget {
  const MoneySENTApp({super.key});
  @override
  State<MoneySENTApp> createState() => _MoneySENTAppState();
}

class _MoneySENTAppState extends State<MoneySENTApp> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // Хэрэглэгчид харагдах анхны frame хурдан: BLZ CSV зэрэг хүнд ачааллыг хойшлуулна.
    await Future.wait([
      UserStore.load(),
      PasscodeStore.load(),
      BiometricStore.load(),
    ]);
    if (!mounted) return;
    setState(() => _ready = true);

    unawaited(Future.wait([
      VerifyStore.load(),
      LoanStore.load(),
      RateRequestQueueStore.load(),
      AdminStore.load(),
      AccountStore.load(),
      GermanBankLookup.load(),
      NotificationPrefsStore.load(),
    ]).then((_) {
      if (mounted) setState(() {});
    }));
    RateService.startAutoFetch();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'MoneySENT',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: kBg,
          textTheme: GoogleFonts.notoSansTextTheme(ThemeData.dark().textTheme),
          colorScheme: const ColorScheme.dark(primary: kYellow, surface: kCard),
        ),
        home: _ready
            ? (appSessionLockRequired()
                ? const PasscodeLockScreen(replaceHomeOnSuccess: true)
                : (UserStore.hasSignedInProfile ? const MainShell() : const LoginScreen()))
            : const Scaffold(
                backgroundColor: kBg,
                body: SizedBox.expand(),
              ),
      );
}

// ─── LOGIN ───────────────────────────────────────────────────────
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override State<LoginScreen> createState() => _LoginState();
}
class _LoginState extends State<LoginScreen> with SingleTickerProviderStateMixin {
  int _tab = 0;
  bool _bioAvailable = false;
  bool _fbBusy = false;
  bool _googleBusy = false;
  late AnimationController _ac;
  late Animation<double> _fade, _y;

  @override void initState() {
    super.initState();
    _ac = AnimationController(vsync:this, duration:const Duration(milliseconds:600));
    _fade = Tween<double>(begin:0,end:1).animate(CurvedAnimation(parent:_ac, curve:Curves.easeIn));
    _y    = Tween<double>(begin:30,end:0).animate(CurvedAnimation(parent:_ac, curve:Curves.easeOut));
    _ac.forward();
    BiometricStore.isAvailable().then((v) { if (mounted) setState(() => _bioAvailable = v); });
    if (BiometricStore.enabled) _tryBiometric();
  }
  @override void dispose() { _ac.dispose(); super.dispose(); }

  Future<void> _tryBiometric() async {
    await Future.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    final ok = await BiometricStore.authenticate();
    if (ok && mounted) await _goHome();
  }

  Future<void> _goHome() async {
    await AccountStore.load();
    if (!mounted) return;
    final dest =
        appSessionLockRequired() ? const PasscodeLockScreen(replaceHomeOnSuccess: true) : const MainShell();
    Navigator.pushReplacement(context, PageRouteBuilder(
      pageBuilder: (_,a,__) => dest,
      transitionsBuilder: (_,a,__,c) => SlideTransition(
          position:Tween<Offset>(begin:const Offset(1,0), end:Offset.zero)
              .animate(CurvedAnimation(parent:a, curve:Curves.easeOutCubic)), child:c),
      transitionDuration:const Duration(milliseconds:500)));
  }

  Future<void> _signInWithGoogle() async {
    if (!_googleLoginSupportedPlatform()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: kRed,
        content: Text(
          'Google нэвтрэлт зөвхөн Android / iOS дээр ажиллана.',
          style: GoogleFonts.notoSans(fontSize: 13),
        ),
      ));
      return;
    }
    setState(() => _googleBusy = true);
    try {
      final webClientId = _resolvedGoogleWebClientId();
      final googleSignIn = GoogleSignIn(
        scopes: const ['email', 'profile'],
        serverClientId: webClientId.isEmpty ? null : webClientId,
      );
      // signIn() нь currentUser үлдсэн бол pickerгүйгээр хуучин аккаунтыг буцаадаг.
      // signOut() → заавал аккаунт сонгох дэлгэц нээгдэнэ.
      await googleSignIn.signOut();
      final account = await googleSignIn.signIn();
      if (!mounted) return;
      if (account == null) {
        setState(() => _googleBusy = false);
        return;
      }
      var email = account.email.trim();
      if (email.isEmpty) {
        final id = account.id.trim();
        email = id.isNotEmpty
            ? 'google_$id@moneysent.google.local'
            : 'google_user@moneysent.google.local';
      }
      final name = account.displayName?.trim().isNotEmpty == true
          ? account.displayName!.trim()
          : (email.contains('@') ? email.split('@').first : 'Google');
      final photo = account.photoUrl ?? '';
      await UserStore.setGoogle(n: name, e: email, avatar: photo);
      if (!mounted) return;
      setState(() => _googleBusy = false);
      await _goHome();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _googleBusy = false);
      final webId = _resolvedGoogleWebClientId();
      final androidNeedWebId = defaultTargetPlatform == TargetPlatform.android &&
          e.code == 'sign_in_failed' &&
          webId.isEmpty;
      final detail = androidNeedWebId
          ? 'Android: Web Client ID (`strings.xml` → default_web_client_id эсвэл кодын `_googleWebClientIdManual`) болон Keystore SHA-1-ийг Cloud Console Android OAuth client-д нэмсэн эсэхээ шалгана уу.'
          : 'OAuth client / SHA-1 (Android), Web Client ID, iOS GIDClientID шалгана уу.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: kRed,
        content: Text(
          'Google алдаа (${e.code}). $detail',
          style: GoogleFonts.notoSans(fontSize: 12, height: 1.35),
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _googleBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: kRed,
        content: Text('Google: $e', style: GoogleFonts.notoSans(fontSize: 12)),
      ));
    }
  }

  Future<void> _signInWithFacebook() async {
    if (!_facebookLoginSupportedPlatform()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: kRed,
        content: Text(
          'Facebook нэвтрэлт зөвхөн Android / iOS дээр ажиллана.',
          style: GoogleFonts.notoSans(fontSize: 13),
        ),
      ));
      return;
    }
    setState(() => _fbBusy = true);
    try {
      final result = await FacebookAuth.instance.login(
        permissions: ['email', 'public_profile'],
      );
      if (!mounted) return;
      if (result.status == LoginStatus.cancelled) {
        setState(() => _fbBusy = false);
        return;
      }
      if (result.status != LoginStatus.success || result.accessToken == null) {
        setState(() => _fbBusy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: kRed,
          content: Text(
            result.message ?? 'Facebook нэвтрэлт амжилтгүй. Meta App ID болон Client Token-оо шалгана уу.',
            style: GoogleFonts.notoSans(fontSize: 13, height: 1.35),
          ),
        ));
        return;
      }
      final userData = await FacebookAuth.instance.getUserData(
        fields: 'name,email,picture.width(200)',
      );
      if (!mounted) return;
      setState(() => _fbBusy = false);
      final name = (userData['name'] as String?)?.trim().isNotEmpty == true
          ? (userData['name'] as String).trim()
          : 'Facebook';
      var email = (userData['email'] as String?)?.trim() ?? '';
      final id = userData['id']?.toString() ?? '';
      if (email.isEmpty && id.isNotEmpty) {
        email = 'fb_$id@moneysent.facebook.local';
      }
      if (email.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: kRed,
          content: Text(
            'Facebook данснаас имэйл аваагүй. Имэйлийн зөвшөөрлийг Meta-д асаана уу.',
            style: GoogleFonts.notoSans(fontSize: 13),
          ),
        ));
        return;
      }
      final picUrl = _facebookPictureUrl(userData['picture']) ?? '';
      await UserStore.setFacebook(n: name, e: email, avatar: picUrl);
      if (!mounted) return;
      await _goHome();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _fbBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: kRed,
        content: Text(
          'Facebook алдаа (${e.code}). App ID / Client Token / Package name / Key hash шалгана уу.',
          style: GoogleFonts.notoSans(fontSize: 12, height: 1.35),
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _fbBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: kRed,
        content: Text('Facebook: $e', style: GoogleFonts.notoSans(fontSize: 12)),
      ));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor:kBg,
      body:AnimatedBuilder(animation:_ac, builder:(_,__)=>Transform.translate(
          offset:Offset(0,_y.value),
          child:FadeTransition(opacity:_fade,
              child:SafeArea(child:SingleChildScrollView(padding:const EdgeInsets.symmetric(horizontal:28),
                  child:Column(crossAxisAlignment:CrossAxisAlignment.center, children:[
                    const SizedBox(height:48),
                    Container(width:90,height:90,
                        decoration:BoxDecoration(boxShadow:[BoxShadow(color:kYellow.withOpacity(0.3), blurRadius:30, spreadRadius:3)]),
                        child:msAppLogo(size:90)),
                    const SizedBox(height:20),
                    RichText(text:TextSpan(children:[
                      TextSpan(text:'Money', style:GoogleFonts.imperialScript(color:Colors.white, fontWeight:FontWeight.w900, fontSize:34)),
                      TextSpan(text:'SENT', style:GoogleFonts.montserrat(color:kYellow, fontWeight:FontWeight.w900, fontSize:28, letterSpacing:2)),
                    ])),
                    const SizedBox(height:8),
                    Text('Тавтай морилно уу', style:GoogleFonts.notoSans(color:Colors.white38, fontSize:13)),
                    const SizedBox(height:36),
                    if(_tab==0)...[
                      if(BiometricStore.enabled && _bioAvailable)...[
                        GestureDetector(
                          onTap: _tryBiometric,
                          child: Container(width:double.infinity, padding:const EdgeInsets.symmetric(vertical:15),
                              decoration:BoxDecoration(
                                gradient: const LinearGradient(colors:[kYellow, kYellowDeep]),
                                borderRadius:BorderRadius.circular(14)),
                              child:Row(mainAxisAlignment:MainAxisAlignment.center, children:[
                                const Icon(Icons.fingerprint_rounded, color:Colors.black, size:24),
                                const SizedBox(width:10),
                                Text('Face ID / Хурууны хээгээр нэвтрэх',
                                    style:GoogleFonts.notoSans(color:Colors.black, fontWeight:FontWeight.w800, fontSize:14)),
                              ])),
                        ),
                        const SizedBox(height:12),
                        Row(children:[const Expanded(child:Divider(color:Color(0xFF444444))),
                          Padding(padding:const EdgeInsets.symmetric(horizontal:14),
                              child:Text('эсвэл', style:GoogleFonts.notoSans(color:Colors.white38,fontSize:12))),
                          const Expanded(child:Divider(color:Color(0xFF444444)))]),
                        const SizedBox(height:12),
                      ],
                      _SBtn(
                          icon: 'G',
                          ic: const Color(0xFF4285F4),
                          label: _googleBusy
                              ? 'Google-тай холбогдож байна…'
                              : 'Google-ээр нэвтрэх',
                          onTap: (_googleBusy || _fbBusy)
                              ? () {}
                              : _signInWithGoogle),
                      const SizedBox(height:10),
                      _SBtn(apple:true, label:'Apple-ээр нэвтрэх', onTap: () { _goHome(); }),
                      const SizedBox(height:10),
                      _SBtn(
                          icon: 'f',
                          ic: const Color(0xFF1877F2),
                          label: _fbBusy ? 'Facebook-тай холбогдож байна…' : 'Facebook-ээр нэвтрэх',
                          onTap: (_fbBusy || _googleBusy) ? () {} : _signInWithFacebook),
                      const SizedBox(height:10),
                      // Нэгдсэн имэйл/утас товч
                      _SBtn(icon:'🔑', ic:kYellow, label:'Имэйл / Утасаар нэвтрэх', onTap:()=>setState(()=>_tab=1)),
                      const SizedBox(height:28),
                      Row(children:[const Expanded(child:Divider(color:Color(0xFF1E1E1E))),
                        Padding(padding:const EdgeInsets.symmetric(horizontal:14),
                            child:Text('эсвэл', style:GoogleFonts.notoSans(color:Colors.white24, fontSize:12))),
                        const Expanded(child:Divider(color:Color(0xFF1E1E1E)))]),
                      const SizedBox(height:20),
                      GestureDetector(
                          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterScreen())),
                          child:Text('Бүртгүүлэх', style:GoogleFonts.notoSans(color:kYellow, fontWeight:FontWeight.w700, fontSize:15))),
                      const SizedBox(height:40),
                    ],
                    if(_tab==1) _EmailPhoneLogin(onBack:()=>setState(()=>_tab=0), onDone: () { _goHome(); }),
                  ])))))));
}

class _SBtn extends StatelessWidget {
  final String icon,label; final Color? ic; final bool apple; final VoidCallback onTap;
  const _SBtn({this.icon='',required this.label,required this.onTap,this.ic,this.apple=false});
  @override Widget build(BuildContext context) => GestureDetector(onTap:onTap,
      child:Container(width:double.infinity, padding:const EdgeInsets.symmetric(vertical:15),
          decoration:BoxDecoration(color:kCard, borderRadius:BorderRadius.circular(14), border:Border.all(color:kBorder)),
          child:Row(mainAxisAlignment:MainAxisAlignment.center, children:[
            if(apple) const Icon(Icons.apple, color:Colors.white, size:22)
            else Text(icon, style:TextStyle(color:ic??Colors.white, fontSize:18, fontWeight:FontWeight.w700)),
            const SizedBox(width:12),
            Text(label, style:GoogleFonts.notoSans(color:Colors.white, fontWeight:FontWeight.w600, fontSize:15)),
          ])));
}

class _PhoneLogin extends StatefulWidget {
  final VoidCallback onBack,onDone; const _PhoneLogin({required this.onBack,required this.onDone});
  @override State<_PhoneLogin> createState()=>_PhoneLoginState();
}
class _PhoneLoginState extends State<_PhoneLogin> {
  int _s=0; final _p=TextEditingController(),_o=TextEditingController();
  @override Widget build(BuildContext context)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    _back(widget.onBack),const SizedBox(height:24),
    Text(_s==0?'Утасны дугаар':'OTP код',style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w800,fontSize:22)),
    const SizedBox(height:8),
    Text(_s==0?'Монгол дугаараа оруулна уу':'+976 ${_p.text} руу код илгээлээ',
        style:GoogleFonts.notoSans(color:Colors.white38,fontSize:13)),
    const SizedBox(height:24),
    if(_s==0)...[
      Container(decoration:BoxDecoration(color:kCard,borderRadius:BorderRadius.circular(14),border:Border.all(color:kBorder)),
          child:Row(children:[
            Container(padding:const EdgeInsets.symmetric(horizontal:16,vertical:16),
                decoration:const BoxDecoration(border:Border(right:BorderSide(color:kBorder))),
                child:Text('+976',style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w700))),
            Expanded(child:TextField(controller:_p,keyboardType:TextInputType.phone,
                style:GoogleFonts.notoSans(color:Colors.white,fontSize:16),
                decoration:InputDecoration(border:InputBorder.none,contentPadding:const EdgeInsets.symmetric(horizontal:16),
                    hintText:'9900 0000',hintStyle:GoogleFonts.notoSans(color:Colors.white24))))])),
      const SizedBox(height:20),_PBtn(label:'Код авах',onTap:()=>setState(()=>_s=1)),
    ],
    if(_s==1)...[
      TextField(controller:_o,keyboardType:TextInputType.number,maxLength:6,textAlign:TextAlign.center,
          style:GoogleFonts.notoSans(color:Colors.white,fontSize:28,fontWeight:FontWeight.w700,letterSpacing:12),
          decoration:InputDecoration(counterText:'',filled:true,fillColor:kCard,
              border:OutlineInputBorder(borderRadius:BorderRadius.circular(14),borderSide:const BorderSide(color:kBorder)),
              enabledBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(14),borderSide:const BorderSide(color:kBorder)),
              focusedBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(14),borderSide:const BorderSide(color:kYellow)),
              hintText:'000000',hintStyle:GoogleFonts.notoSans(color:Colors.white12,fontSize:28,letterSpacing:12))),
      const SizedBox(height:20),_PBtn(label:'Нэвтрэх',onTap:widget.onDone),
      const SizedBox(height:12),Center(child:Text('Дахин код авах',style:GoogleFonts.notoSans(color:kYellow,fontSize:14))),
    ],const SizedBox(height:40),
  ]);
}

class _EmailLogin extends StatefulWidget {
  final VoidCallback onBack,onDone; const _EmailLogin({required this.onBack,required this.onDone});
  @override State<_EmailLogin> createState()=>_EmailLoginState();
}
class _EmailLoginState extends State<_EmailLogin> {
  final _e=TextEditingController(),_p=TextEditingController(); bool _obs=true;
  @override Widget build(BuildContext context)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    _back(widget.onBack),const SizedBox(height:24),
    Text('Имэйлээр нэвтрэх',style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w800,fontSize:22)),
    const SizedBox(height:24),
    _tf2(_e,'Имэйл хаяг',TextInputType.emailAddress,false,null),
    const SizedBox(height:12),
    TextField(controller:_p,obscureText:_obs,style:GoogleFonts.notoSans(color:Colors.white,fontSize:15),
        decoration:InputDecoration(hintText:'Нууц үг',hintStyle:GoogleFonts.notoSans(color:Colors.white24),
            filled:true,fillColor:kCard,
            border:OutlineInputBorder(borderRadius:BorderRadius.circular(12),borderSide:const BorderSide(color:kBorder)),
            enabledBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(12),borderSide:const BorderSide(color:kBorder)),
            focusedBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(12),borderSide:const BorderSide(color:kYellow)),
            suffixIcon:IconButton(icon:Icon(_obs?Icons.visibility_off:Icons.visibility,color:Colors.white38),
                onPressed:()=>setState(()=>_obs=!_obs)))),
    const SizedBox(height:8),
    Align(alignment:Alignment.centerRight,child:Text('Нууц үг мартсан?',style:GoogleFonts.notoSans(color:kYellow,fontSize:13))),
    const SizedBox(height:20),_PBtn(label:'Нэвтрэх',onTap:widget.onDone),const SizedBox(height:40),
  ]);
}

// ─── COMBINED EMAIL/PHONE LOGIN ──────────────────────────────────
class _EmailPhoneLogin extends StatefulWidget {
  final VoidCallback onBack, onDone;
  const _EmailPhoneLogin({required this.onBack, required this.onDone});
  @override State<_EmailPhoneLogin> createState() => _EmailPhoneLoginState();
}

class _EmailPhoneLoginState extends State<_EmailPhoneLogin> {
  bool _byEmail = true;
  final _eCtrl  = TextEditingController();
  final _pCtrl  = TextEditingController();
  final _phCtrl = TextEditingController();
  bool _obs     = true;
  int  _otpStep = 0;
  final _otpCtrl = TextEditingController();

  InputDecoration _dec(String hint, {IconData? icon}) => InputDecoration(
    hintText: hint, hintStyle: GoogleFonts.notoSans(color: Colors.white24, fontSize: 13),
    prefixIcon: icon != null ? Icon(icon, color: Colors.white38, size: 18) : null,
    filled: true, fillColor: kCard,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kBorder)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kBorder)),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kYellow)),
  );

  void _showForgot(BuildContext ctx) {
    showModalBottomSheet(
      context: ctx, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (_) => _ForgotPasswordSheet(),
    );
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _back(widget.onBack),
    const SizedBox(height: 20),
    Text('Нэвтрэх', style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 24)),
    const SizedBox(height: 16),

    // ── Toggle: Имэйл / Утас ──
    Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder)),
      child: Row(children: [
        _togBtn('✉  Имэйл', _byEmail, () => setState(() { _byEmail = true; _otpStep = 0; })),
        _togBtn('📱  Утас', !_byEmail, () => setState(() { _byEmail = false; _otpStep = 0; })),
      ]),
    ),
    const SizedBox(height: 20),

    if (_byEmail) ...[
      TextField(controller: _eCtrl, keyboardType: TextInputType.emailAddress,
        style: GoogleFonts.notoSans(color: Colors.white, fontSize: 14),
        decoration: _dec('Имэйл хаяг', icon: Icons.email_rounded)),
      const SizedBox(height: 12),
      TextField(controller: _pCtrl, obscureText: _obs,
        style: GoogleFonts.notoSans(color: Colors.white, fontSize: 14),
        decoration: _dec('Нууц үг', icon: Icons.lock_rounded).copyWith(
          suffixIcon: IconButton(
            icon: Icon(_obs ? Icons.visibility_off : Icons.visibility, color: Colors.white38, size: 20),
            onPressed: () => setState(() => _obs = !_obs)))),
      const SizedBox(height: 8),
      Align(alignment: Alignment.centerRight,
        child: GestureDetector(
          onTap: () => _showForgot(context),
          child: Text('Нууц үг мартсан?',
            style: GoogleFonts.notoSans(color: kYellow, fontSize: 13, fontWeight: FontWeight.w600)))),
      const SizedBox(height: 20),
      _PBtn(label: '🔑 Нэвтрэх', onTap: () async {
        UserStore.email = _eCtrl.text.trim();
        UserStore.loginType = 'email';
        await UserStore.save();
        if (!context.mounted) return;
        widget.onDone();
      }),
    ] else ...[
      if (_otpStep == 0) ...[
        Container(
          decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder)),
          child: Row(children: [
            Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              decoration: const BoxDecoration(border: Border(right: BorderSide(color: kBorder))),
              child: Text('+976', style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w700))),
            Expanded(child: TextField(controller: _phCtrl, keyboardType: TextInputType.phone,
              style: GoogleFonts.notoSans(color: Colors.white, fontSize: 15),
              decoration: InputDecoration(border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                hintText: '9900 0000', hintStyle: GoogleFonts.notoSans(color: Colors.white24)))),
          ]),
        ),
        const SizedBox(height: 20),
        _PBtn(label: '📨 OTP код авах', onTap: () => setState(() => _otpStep = 1)),
      ] else ...[
        Text('+976 ${_phCtrl.text} руу код илгээлээ',
          style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 13)),
        const SizedBox(height: 16),
        TextField(controller: _otpCtrl, keyboardType: TextInputType.number,
          maxLength: 6, textAlign: TextAlign.center,
          style: GoogleFonts.notoSans(color: Colors.white, fontSize: 28,
            fontWeight: FontWeight.w700, letterSpacing: 12),
          decoration: InputDecoration(counterText: '',
            filled: true, fillColor: kCard,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kBorder)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kBorder)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kYellow)),
            hintText: '000000', hintStyle: GoogleFonts.notoSans(color: Colors.white12, fontSize: 28, letterSpacing: 12))),
        const SizedBox(height: 20),
        _PBtn(label: '✅ Нэвтрэх', onTap: () async {
          UserStore.phoneMN = _phCtrl.text.replaceAll(RegExp(r'\D'), '');
          UserStore.loginType = 'phone';
          await UserStore.save();
          if (!context.mounted) return;
          widget.onDone();
        }),
        const SizedBox(height: 12),
        Center(child: GestureDetector(
          onTap: () => setState(() => _otpStep = 0),
          child: Text('← Дахин оруулах', style: GoogleFonts.notoSans(color: kYellow, fontSize: 13)))),
      ],
    ],
    const SizedBox(height: 40),
  ]);

  Widget _togBtn(String label, bool active, VoidCallback onTap) => Expanded(
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: active ? kYellow : Colors.transparent,
          borderRadius: BorderRadius.circular(9)),
        child: Center(child: Text(label,
          style: GoogleFonts.notoSans(
            color: active ? Colors.black : Colors.white54,
            fontWeight: FontWeight.w700, fontSize: 13))),
      ),
    ),
  );
}

// ─── FORGOT PASSWORD SHEET ───────────────────────────────────────
class _ForgotPasswordSheet extends StatefulWidget {
  @override State<_ForgotPasswordSheet> createState() => _ForgotPasswordSheetState();
}

class _ForgotPasswordSheetState extends State<_ForgotPasswordSheet> {
  final _eCtrl = TextEditingController();
  bool _sent = false;
  bool _loading = false;

  Future<void> _send() async {
    if (_eCtrl.text.trim().isEmpty || !_eCtrl.text.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Зөв имэйл оруулна уу',
          style: GoogleFonts.notoSans(color: Colors.black, fontWeight: FontWeight.w600)),
        backgroundColor: kYellow, behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
      return;
    }
    setState(() => _loading = true);
    await Future.delayed(const Duration(milliseconds: 800));
    final sub  = Uri.encodeComponent('[MoneySENT] Нууц үг сэргээх хүсэлт');
    final body = Uri.encodeComponent('Нууц үг сэргээх хүсэлт:\nИмэйл: ${_eCtrl.text.trim()}\nОгноо: ${DateTime.now()}');
    await launchUrl(Uri.parse('mailto:info@promonsolutions.de?subject=$sub&body=$body'));
    setState(() { _loading = false; _sent = true; });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(24, 16, 24, MediaQuery.of(context).viewInsets.bottom + 36),
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1C),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 40, height: 4,
          decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
        const SizedBox(height: 20),
        if (!_sent) ...[
          Text('Нууц үг сэргээх', style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 18)),
          const SizedBox(height: 8),
          Text('Бүртгэлтэй имэйл хаягаа оруулна уу.\nБид таны нууц үгийг сэргээх холбоос илгээнэ.',
            style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 13, height: 1.5)),
          const SizedBox(height: 20),
          TextField(
            controller: _eCtrl,
            keyboardType: TextInputType.emailAddress,
            style: GoogleFonts.notoSans(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'example@gmail.com',
              hintStyle: GoogleFonts.notoSans(color: Colors.white24, fontSize: 13),
              prefixIcon: const Icon(Icons.email_rounded, color: Colors.white38, size: 18),
              filled: true, fillColor: kCard,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kBorder)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kBorder)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kYellow)),
            ),
          ),
          const SizedBox(height: 20),
          _PBtn(label: _loading ? '⏳ Илгээж байна...' : '📧 Холбоос илгээх',
            onTap: _loading ? () {} : () => _send()),
        ] else ...[
          Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 64, height: 64,
              decoration: BoxDecoration(color: kYellow.withOpacity(0.12), shape: BoxShape.circle),
              child: const Icon(Icons.mark_email_read_rounded, color: kYellow, size: 32)),
            const SizedBox(height: 16),
            Text('Имэйл илгээгдлээ!', style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 17)),
            const SizedBox(height: 8),
            Text('${_eCtrl.text.trim()} хаяг руу нууц үг\nсэргээх холбоос илгээгдлээ.',
              style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 13, height: 1.5),
              textAlign: TextAlign.center),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Хаах', style: GoogleFonts.notoSans(color: kYellow, fontWeight: FontWeight.w700, fontSize: 15))),
          ])),
        ],
      ]),
    );
  }
}

// ─── LEGAL SHEET (AGB / Datenschutz / Impressum) ─────────────────
class _LegalSheet extends StatelessWidget {
  final String title;
  final List<_LegalSection> sections;
  const _LegalSheet({required this.title, required this.sections});

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
    initialChildSize: 0.88, minChildSize: 0.5, maxChildSize: 0.95,
    builder: (_, sc) => Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1C),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      child: Column(children: [
        const SizedBox(height: 12),
        Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 16),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            Expanded(child: Text(title,
              style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 18))),
            IconButton(icon: const Icon(Icons.close, color: Colors.white38),
              onPressed: () => Navigator.pop(context)),
          ])),
        const Divider(color: Color(0xFF2A2A2A)),
        Expanded(child: ListView(controller: sc, padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: sections.map((s) => Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (s.heading.isNotEmpty) ...[
                Text(s.heading, style: GoogleFonts.notoSans(color: kYellow, fontWeight: FontWeight.w800, fontSize: 13)),
                const SizedBox(height: 6),
              ],
              Text(s.body, style: GoogleFonts.notoSans(color: Colors.white70, fontSize: 12.5, height: 1.65)),
            ]),
          )).toList())),
      ]),
    ),
  );
}

class _LegalSection { final String heading, body; const _LegalSection(this.heading, this.body); }

void _showAGB(BuildContext ctx) => showModalBottomSheet(
  context: ctx, isScrollControlled: true, backgroundColor: Colors.transparent,
  builder: (_) => _LegalSheet(title: 'AGB – Allgemeine Geschäftsbedingungen', sections: const [
    _LegalSection('§1 Geltungsbereich',
      'Diese Allgemeinen Geschäftsbedingungen gelten für alle Verträge, die zwischen PROMON Solutions und den Nutzern der MoneySENT-App geschlossen werden. Abweichende Bedingungen des Nutzers werden nicht anerkannt, es sei denn, PROMON Solutions stimmt ihrer Geltung ausdrücklich schriftlich zu.'),
    _LegalSection('§2 Leistungsgegenstand',
      'PROMON Solutions stellt über die App MoneySENT einen digitalen Geldtransferservice bereit, der Überweisungen zwischen Deutschland und der Mongolei ermöglicht. Die Nutzung setzt eine vollständige Registrierung sowie die Einhaltung der AML-Richtlinien voraus.'),
    _LegalSection('§3 Registrierung und Nutzerkonto',
      'Der Nutzer ist verpflichtet, bei der Registrierung wahrheitsgemäße und vollständige Angaben zu machen. Das Nutzerkonto ist nicht übertragbar. Der Nutzer trägt die Verantwortung für die Geheimhaltung seiner Zugangsdaten.'),
    _LegalSection('§4 Gebühren und Wechselkurse',
      'Die Transaktionsgebühren werden dem Nutzer vor Abschluss der Transaktion transparent angezeigt. Der verwendete Wechselkurs wird täglich aktualisiert und kann von dem zum Zeitpunkt der Buchung angezeigten Kurs leicht abweichen.'),
    _LegalSection('§5 Haftungsbeschränkung',
      'PROMON Solutions haftet nicht für Schäden, die durch höhere Gewalt, technische Ausfälle Dritter oder fehlerhafte Angaben des Nutzers entstehen. Die Haftung ist auf den Betrag der betroffenen Transaktion beschränkt.'),
    _LegalSection('§6 Kündigung',
      'Beide Parteien können das Nutzungsverhältnis jederzeit ohne Angabe von Gründen kündigen. PROMON Solutions behält sich das Recht vor, Nutzerkonten bei Verdacht auf missbräuchliche Nutzung sofort zu sperren.'),
    _LegalSection('§7 Anwendbares Recht',
      'Es gilt das Recht der Bundesrepublik Deutschland. Gerichtsstand ist der Sitz von PROMON Solutions.'),
  ]));

void _showDatenschutz(BuildContext ctx) => showModalBottomSheet(
  context: ctx, isScrollControlled: true, backgroundColor: Colors.transparent,
  builder: (_) => _LegalSheet(title: 'Datenschutzerklärung', sections: const [
    _LegalSection('1. Verantwortlicher',
      'Verantwortlicher im Sinne der DSGVO ist PROMON Solutions, Deutschland.\nE-Mail: info@promonsolutions.de'),
    _LegalSection('2. Erhobene Daten',
      'Wir erheben bei der Registrierung folgende personenbezogene Daten: Name, E-Mail-Adresse, Telefonnummern, Anschrift, Geburtsdatum sowie Informationen zur beruflichen Tätigkeit. Diese Daten sind zur Erbringung unserer Dienstleistungen und zur Erfüllung gesetzlicher Pflichten (u.a. KYC/AML) erforderlich.'),
    _LegalSection('3. Zweck der Verarbeitung',
      'Ihre Daten werden ausschließlich zur Durchführung von Geldtransaktionen, zur Identitätsverifizierung, zur Betrugsprävention sowie zur Erfüllung gesetzlicher Meldepflichten verarbeitet.'),
    _LegalSection('4. Speicherdauer',
      'Personenbezogene Daten werden für die Dauer der Geschäftsbeziehung sowie entsprechend der gesetzlichen Aufbewahrungsfristen (bis zu 10 Jahre) gespeichert.'),
    _LegalSection('5. Weitergabe an Dritte',
      'Eine Weitergabe Ihrer Daten an Dritte erfolgt nur, soweit dies zur Vertragserfüllung notwendig ist (z.B. Partnerbanken) oder gesetzliche Pflichten dies erfordern.'),
    _LegalSection('6. Ihre Rechte',
      'Sie haben das Recht auf Auskunft, Berichtigung, Löschung, Einschränkung der Verarbeitung sowie das Recht auf Datenübertragbarkeit. Zur Ausübung Ihrer Rechte wenden Sie sich bitte an info@promonsolutions.de.'),
    _LegalSection('7. Beschwerderecht',
      'Sie haben das Recht, sich bei einer Datenschutzbehörde zu beschweren. Zuständige Aufsichtsbehörde ist der Bundesbeauftragte für den Datenschutz und die Informationsfreiheit (BfDI).'),
  ]));

void _showImpressum(BuildContext ctx) => showModalBottomSheet(
  context: ctx, isScrollControlled: true, backgroundColor: Colors.transparent,
  builder: (_) => _LegalSheet(title: 'Impressum', sections: const [
    _LegalSection('Angaben gemäß §5 TMG',
      'PROMON Solutions\nGeschäftsführer: [Name]\nAnschrift: [Straße, PLZ, Stadt], Deutschland\nE-Mail: info@promonsolutions.de\nWebseite: www.promonsolutions.de'),
    _LegalSection('Handelsregistereintrag',
      'Eingetragen im Handelsregister.\nRegistergericht: [Amtsgericht]\nRegisternummer: [HRB XXXXX]'),
    _LegalSection('Umsatzsteuer-ID',
      'Umsatzsteuer-Identifikationsnummer gemäß §27a Umsatzsteuergesetz: DE [XXXXXXXXX]'),
    _LegalSection('Aufsichtsbehörde',
      'PROMON Solutions unterliegt der Aufsicht der Bundesanstalt für Finanzdienstleistungsaufsicht (BaFin), Graurheindorfer Str. 108, 53117 Bonn.'),
    _LegalSection('Haftungshinweis',
      'Trotz sorgfältiger inhaltlicher Kontrolle übernehmen wir keine Haftung für die Inhalte externer Links. Für den Inhalt der verlinkten Seiten sind ausschließlich deren Betreiber verantwortlich.'),
    _LegalSection('Streitschlichtung',
      'Die Europäische Kommission stellt eine Plattform zur Online-Streitbeilegung (OS) bereit: https://ec.europa.eu/consumers/odr. Wir sind nicht bereit oder verpflichtet, an Streitbeilegungsverfahren vor einer Verbraucherschlichtungsstelle teilzunehmen.'),
  ]));

// ─── REGISTER SCREEN ─────────────────────────────────────────────
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override State<RegisterScreen> createState() => _RegisterState();
}

class _RegisterState extends State<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _lastNameCtrl   = TextEditingController();
  final _firstNameCtrl  = TextEditingController();
  final _emailCtrl      = TextEditingController();
  final _passCtrl       = TextEditingController();
  final _pass2Ctrl      = TextEditingController();
  final _phoneDECtrl    = TextEditingController();
  final _phoneMNCtrl    = TextEditingController();
  final _streetCtrl     = TextEditingController(); // Straße + Hausnummer
  final _plzCtrl        = TextEditingController(); // PLZ
  final _stadtCtrl      = TextEditingController(); // Stadt

  String? _gender;
  String? _sector;
  bool _obsPass    = true;
  bool _obsPass2   = true;
  bool _termsOk    = false;
  bool _loading    = false;
  bool _emailSent  = false;
  bool _genderErr  = false;

  static const _sectors = [
    'Цалинтай ажилтан','Бизнес эрхлэгч','Оюутан','Чөлөөт мэргэжилтэн',
    'Худалдаа / үйлчилгээ','Мэдээлэл технологи','Барилга / инженер',
    'Санхүү / банк','Боловсрол / шинжлэх ухаан','Эрүүл мэнд',
    'Урлаг / медиа','Засгийн газар / нийтийн үйлчилгээ','Бусад',
  ];

  InputDecoration _dec(String hint, {IconData? icon}) => InputDecoration(
    hintText: hint,
    hintStyle: GoogleFonts.notoSans(color: Colors.white24, fontSize: 13),
    prefixIcon: icon != null ? Icon(icon, color: Colors.white38, size: 18) : null,
    filled: true, fillColor: kCard,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kBorder)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kBorder)),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kYellow)),
    errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.red.shade400)),
    focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.red.shade400)),
    errorStyle: GoogleFonts.notoSans(color: Colors.red.shade300, fontSize: 11),
  );

  TextStyle get _ts => GoogleFonts.notoSans(color: Colors.white, fontSize: 14);

  Widget _label(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 6, top: 4),
    child: Text(t, style: GoogleFonts.notoSans(color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w600)),
  );

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Row(children: [
      Container(width: 3, height: 14, decoration: BoxDecoration(color: kYellow, borderRadius: BorderRadius.circular(2))),
      const SizedBox(width: 8),
      Text(title, style: GoogleFonts.notoSans(color: Colors.white70, fontWeight: FontWeight.w800, fontSize: 13, letterSpacing: 0.5)),
    ]),
  );

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    if (_gender == null) { setState(() => _genderErr = true); _toast('Хүйсээ сонгоно уу'); return; }
    setState(() => _genderErr = false);
    if (_sector == null) { _toast('Ажлын салбараа сонгоно уу'); return; }
    if (!_termsOk)       { _toast('Үйлчилгээний нөхцөлтэй танилцан зөвшөөрнө үү'); return; }

    setState(() => _loading = true);
    await Future.delayed(const Duration(milliseconds: 600));

    // UserStore-д хадгалах
    UserStore.name     = '${_lastNameCtrl.text.trim()} ${_firstNameCtrl.text.trim()}';
    UserStore.email    = _emailCtrl.text.trim();
    UserStore.phoneDE  = _phoneDECtrl.text.trim();
    UserStore.phoneMN  = _phoneMNCtrl.text.trim();
    UserStore.loginType = 'email';
    await UserStore.save();

    // Баталгаажуулах имэйл илгээх (симуляц)
    final body = Uri.encodeComponent(
      'Шинэ бүртгэл:\n'
      'Нэр: ${UserStore.name}\n'
      'Имэйл: ${UserStore.email}\n'
      'Утас (DE): ${UserStore.phoneDE}\n'
      'Утас (MN): ${UserStore.phoneMN}\n'
      'Хаяг: ${_streetCtrl.text.trim()}, ${_plzCtrl.text.trim()} ${_stadtCtrl.text.trim()}\n'
      'Хүйс: $_gender\n'
      'Салбар: $_sector\n'
      'Огноо: ${DateTime.now()}\n'
    );
    final sub = Uri.encodeComponent('[MoneySENT] Шинэ гишүүний бүртгэл');
    await launchUrl(Uri.parse('mailto:info@promonsolutions.de?subject=$sub&body=$body'));

    setState(() { _loading = false; _emailSent = true; });
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.notoSans(color: Colors.black, fontWeight: FontWeight.w600)),
      backgroundColor: kYellow, behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(16),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: kYellow, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: RichText(text: TextSpan(children: [
          TextSpan(text: 'Money', style: GoogleFonts.imperialScript(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900)),
          TextSpan(text: 'SENT', style: GoogleFonts.montserrat(color: kYellow, fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
        ])),
        centerTitle: true,
      ),
      body: _emailSent ? _successView() : _formView(),
    );
  }

  Widget _successView() => Center(child: Padding(
    padding: const EdgeInsets.all(32),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 80, height: 80,
        decoration: BoxDecoration(color: kYellow.withOpacity(0.12), shape: BoxShape.circle),
        child: const Icon(Icons.mark_email_read_rounded, color: kYellow, size: 40)),
      const SizedBox(height: 24),
      Text('Баталгаажуулалт илгээлээ', style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 20)),
      const SizedBox(height: 12),
      Text(
        '${_emailCtrl.text.trim()} хаяг руу баталгаажуулах имэйл илгээгдлээ.\n\nPROMON Solutions баг таны бүртгэлийг шалгаад удахгүй холбогдоно.',
        style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 13, height: 1.6),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 32),
      _PBtn(label: '← Нэвтрэх хуудас руу', onTap: () => Navigator.pop(context)),
    ]),
  ));

  Widget _formView() => Form(
    key: _form,
    child: ListView(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), children: [
      const SizedBox(height: 8),
      Text('Бүртгүүлэх', style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 26)),
      Text('PROMON Solutions', style: GoogleFonts.notoSans(color: kYellow, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
      const SizedBox(height: 4),
      Text('Бүх талбарыг бөглөнө үү', style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12)),

      // ── Үндсэн мэдээлэл ──
      _section('ҮНДСЭН МЭДЭЭЛЭЛ'),
      _label('Овог'),
      TextFormField(controller: _lastNameCtrl, style: _ts, decoration: _dec('Жишээ: Жамбал'),
        validator: (v) => (v == null || v.trim().isEmpty) ? 'Овог оруулна уу' : null),
      _label('Нэр'),
      TextFormField(controller: _firstNameCtrl, style: _ts, decoration: _dec('Жишээ: Мөнхбаяр'),
        validator: (v) => (v == null || v.trim().isEmpty) ? 'Нэр оруулна уу' : null),

      // ── Хүйс ──
      _label('Хүйс *'),
      Row(children: [
        _genderBtn('Эрэгтэй', Icons.male_rounded),
        const SizedBox(width: 10),
        _genderBtn('Эмэгтэй', Icons.female_rounded),
      ]),
      if (_genderErr)
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 4),
          child: Text('Хүйсээ сонгоно уу',
            style: GoogleFonts.notoSans(color: Colors.red.shade300, fontSize: 11)),
        ),

      // ── Холбоо барих ──
      _section('ХОЛБОО БАРИХ'),
      _label('Имэйл хаяг'),
      TextFormField(controller: _emailCtrl, style: _ts, keyboardType: TextInputType.emailAddress,
        decoration: _dec('example@gmail.com', icon: Icons.email_rounded),
        validator: (v) {
          if (v == null || v.trim().isEmpty) return 'Имэйл оруулна уу';
          if (!v.contains('@') || !v.contains('.')) return 'Зөв имэйл оруулна уу';
          return null;
        }),
      _label('Германы утас (+49)'),
      TextFormField(controller: _phoneDECtrl, style: _ts, keyboardType: TextInputType.phone,
        decoration: _dec('+49 152 XXXXXXXX', icon: Icons.phone_rounded),
        validator: (_) {
          if (_phoneDECtrl.text.trim().isEmpty && _phoneMNCtrl.text.trim().isEmpty) {
            return 'Дор хаяж нэг утасны дугаар оруулна уу';
          }
          return null;
        }),
      _label('Монгол утас (+976)'),
      TextFormField(controller: _phoneMNCtrl, style: _ts, keyboardType: TextInputType.phone,
        decoration: _dec('+976 99XX XXXX', icon: Icons.phone_android_rounded),
        validator: (_) {
          if (_phoneDECtrl.text.trim().isEmpty && _phoneMNCtrl.text.trim().isEmpty) {
            return 'Дор хаяж нэг утасны дугаар оруулна уу';
          }
          return null;
        }),

      // ── Нууц үг ──
      _section('НУУЦ ҮГ'),
      _label('Нууц үг'),
      TextFormField(controller: _passCtrl, style: _ts, obscureText: _obsPass,
        decoration: _dec('Дор хаяж 8 тэмдэгт', icon: Icons.lock_rounded).copyWith(
          suffixIcon: IconButton(icon: Icon(_obsPass ? Icons.visibility_off : Icons.visibility, color: Colors.white38, size: 20),
            onPressed: () => setState(() => _obsPass = !_obsPass))),
        validator: (v) {
          if (v == null || v.length < 8) return 'Дор хаяж 8 тэмдэгт оруулна уу';
          return null;
        }),
      _label('Нууц үг давтах'),
      TextFormField(controller: _pass2Ctrl, style: _ts, obscureText: _obsPass2,
        decoration: _dec('Нууц үгийг давтаж оруулна уу', icon: Icons.lock_outline_rounded).copyWith(
          suffixIcon: IconButton(icon: Icon(_obsPass2 ? Icons.visibility_off : Icons.visibility, color: Colors.white38, size: 20),
            onPressed: () => setState(() => _obsPass2 = !_obsPass2))),
        validator: (v) {
          if (v != _passCtrl.text) return 'Нууц үг таарахгүй байна';
          return null;
        }),

      // ── Хаяг ──
      _section('ГЕРМАНЫ ХАЯГ & АЖЛЫН САЛБАР'),
      _label('Гудамж, байрны дугаар (Straße, Hausnummer)'),
      TextFormField(controller: _streetCtrl, style: _ts,
        decoration: _dec('Musterstraße 12', icon: Icons.home_rounded),
        validator: (v) => (v == null || v.trim().isEmpty) ? 'Хаяг оруулна уу' : null),
      Row(children: [
        Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _label('Шуудангийн код (PLZ)'),
          TextFormField(controller: _plzCtrl, style: _ts,
            keyboardType: TextInputType.number,
            decoration: _dec('12345', icon: Icons.local_post_office_rounded),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'PLZ оруулна уу';
              if (v.trim().length != 5) return '5 орон';
              return null;
            }),
        ])),
        const SizedBox(width: 10),
        Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _label('Хот (Stadt)'),
          TextFormField(controller: _stadtCtrl, style: _ts,
            decoration: _dec('Berlin', icon: Icons.location_city_rounded),
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Хот оруулна уу' : null),
        ])),
      ]),
      _label('Ажлын салбар'),
      DropdownButtonFormField<String>(
        value: _sector,
        dropdownColor: const Color(0xFF1C1C1C),
        style: _ts,
        hint: Text('Салбар сонгох', style: GoogleFonts.notoSans(color: Colors.white24, fontSize: 13)),
        decoration: _dec('').copyWith(hintText: null, prefixIcon: const Icon(Icons.work_rounded, color: Colors.white38, size: 18)),
        items: _sectors.map((s) => DropdownMenuItem(value: s, child: Text(s, style: _ts))).toList(),
        onChanged: (v) => setState(() => _sector = v),
        validator: (v) => v == null ? 'Салбар сонгоно уу' : null,
      ),

      // ── Нөхцөл ──
      const SizedBox(height: 20),
      GestureDetector(
        onTap: () => setState(() => _termsOk = !_termsOk),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _termsOk ? kYellow.withOpacity(0.08) : kCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _termsOk ? kYellow.withOpacity(0.4) : kBorder),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            GestureDetector(
              onTap: () => setState(() => _termsOk = !_termsOk),
              child: Icon(_termsOk ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                color: _termsOk ? kYellow : Colors.white38, size: 22)),
            const SizedBox(width: 12),
            Expanded(child: Wrap(children: [
              Text('PROMON Solutions-ийн ', style: GoogleFonts.notoSans(color: Colors.white60, fontSize: 12, height: 1.6)),
              GestureDetector(
                onTap: () => _showAGB(context),
                child: Text('AGB', style: GoogleFonts.notoSans(color: kYellow, fontSize: 12, fontWeight: FontWeight.w700, decoration: TextDecoration.underline, height: 1.6))),
              Text(' болон ', style: GoogleFonts.notoSans(color: Colors.white60, fontSize: 12, height: 1.6)),
              GestureDetector(
                onTap: () => _showDatenschutz(context),
                child: Text('Datenschutzerklärung', style: GoogleFonts.notoSans(color: kYellow, fontSize: 12, fontWeight: FontWeight.w700, decoration: TextDecoration.underline, height: 1.6))),
              Text('-той танилцан зөвшөөрч байна.', style: GoogleFonts.notoSans(color: Colors.white60, fontSize: 12, height: 1.6)),
            ])),
          ]),
        ),
      ),
      const SizedBox(height: 24),
      _PBtn(
        label: _loading ? '⏳ Бүртгэж байна...' : '✅ Бүртгүүлэх',
        onTap: _loading ? () {} : () => _submit(),
      ),
      const SizedBox(height: 16),
      Center(child: GestureDetector(
        onTap: () => Navigator.pop(context),
        child: RichText(text: TextSpan(children: [
          TextSpan(text: 'Бүртгэлтэй юу? ', style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 13)),
          TextSpan(text: 'Нэвтрэх', style: GoogleFonts.notoSans(color: kYellow, fontWeight: FontWeight.w700, fontSize: 13)),
        ])),
      )),
      const SizedBox(height: 12),
      Center(child: GestureDetector(
        onTap: () => _showImpressum(context),
        child: Text('Impressum', style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12, decoration: TextDecoration.underline)),
      )),
      const SizedBox(height: 40),
    ]),
  );

  Widget _genderBtn(String label, IconData icon) => Expanded(
    child: GestureDetector(
      onTap: () => setState(() { _gender = label; _genderErr = false; }),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: _gender == label ? kYellow.withOpacity(0.12) : kCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _gender == label ? kYellow : kBorder),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: _gender == label ? kYellow : Colors.white38, size: 20),
          const SizedBox(width: 8),
          Text(label, style: GoogleFonts.notoSans(
            color: _gender == label ? kYellow : Colors.white54,
            fontWeight: FontWeight.w600, fontSize: 13)),
        ]),
      ),
    ),
  );
}

Widget _back(VoidCallback fn) => GestureDetector(onTap:fn,child:Row(children:[
  const Icon(Icons.arrow_back_ios,color:kYellow,size:16),
  Text('Буцах',style:GoogleFonts.notoSans(color:kYellow,fontSize:14))]));

Widget _tf2(TextEditingController c,String h,TextInputType t,bool obs,void Function(String)? onChange)=>TextField(
    controller:c,keyboardType:t,obscureText:obs,onChanged:onChange,
    style:GoogleFonts.notoSans(color:Colors.white,fontSize:15),
    decoration:InputDecoration(hintText:h,hintStyle:GoogleFonts.notoSans(color:Colors.white24),
        filled:true,fillColor:kCard,
        border:OutlineInputBorder(borderRadius:BorderRadius.circular(12),borderSide:const BorderSide(color:kBorder)),
        enabledBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(12),borderSide:const BorderSide(color:kBorder)),
        focusedBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(12),borderSide:const BorderSide(color:kYellow))));

/// Гүйлгээний түүх болон админын «Хүргэгдлээ» товчийг холбоно (MainShell ↔ Admin самбар).
class AdminTxBridge {
  static List<TxRecord> Function()? getHistory;
  static void Function(TxRecord)? onConfirmDelivered;

  static void bind({
    required List<TxRecord> Function() history,
    required void Function(TxRecord) onConfirmDelivered,
  }) {
    AdminTxBridge.getHistory = history;
    AdminTxBridge.onConfirmDelivered = onConfirmDelivered;
  }

  static void clear() {
    getHistory = null;
    onConfirmDelivered = null;
  }
}

// ─── MAIN SHELL ──────────────────────────────────────────────────
class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override State<MainShell> createState() => _MainShellState();
}
class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _idx = 0;
  final List<TxRecord> _history = [];
  TxRecord? _prefillTx;

  DateTime? _pausedAt;
  bool _resumeLockShowing = false;

  static const int _resumeLockAfterSeconds = 30;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AdminTxBridge.bind(
      history: () => _history,
      onConfirmDelivered: _confirmTxDelivered,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AdminTxBridge.clear();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final started = _pausedAt;
      _pausedAt = null;
      if (started == null || !appSessionLockRequired() || _resumeLockShowing) return;
      if (DateTime.now().difference(started).inSeconds < _resumeLockAfterSeconds) return;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted || !appSessionLockRequired() || _resumeLockShowing) return;
        _resumeLockShowing = true;
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => const PasscodeLockScreen(replaceHomeOnSuccess: false),
          ),
        );
        if (mounted) setState(() => _resumeLockShowing = false);
      });
    }
  }

  void _addTx(TxRecord tx) { setState(() => _history.insert(0, tx)); _simulate(tx); }

  void _confirmTxDelivered(TxRecord tx) {
    if (tx.currentStep != TxStep.awaiting_admin_confirm) return;
    setState(() {
      tx.currentStep = TxStep.delivered;
      tx.stepHistory.add(MapEntry(TxStep.delivered, DateTime.now()));
    });
    _snack(tx);
  }

  void _repeatTx(TxRecord tx) {
    setState(() { _prefillTx = tx; _idx = 1; });
  }

  void _consumePrefill() {
    if (_prefillTx != null) setState(() => _prefillTx = null);
  }

  void _goHomeAndOpenTracking(TxRecord tx) {
    setState(() => _idx = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TrackingScreen(tx: tx, onRepeat: _repeatTx),
        ),
      );
    });
  }

  void _simulate(TxRecord tx) {
    final steps = TxStep.values;
    final awaitingIdx = steps.indexOf(TxStep.awaiting_admin_confirm);
    const delays = [0, 4, 10, 16, 24, 32];
    for (int i = 1; i <= awaitingIdx; i++) {
      Future.delayed(Duration(seconds: delays[i]), () {
        if (!mounted) return;
        setState(() {
          tx.currentStep = steps[i];
          tx.stepHistory.add(MapEntry(steps[i], DateTime.now()));
        });
      });
    }
  }

  void _snack(TxRecord tx) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor:kGreen, duration:const Duration(seconds:6),
        shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(14)),
        margin:const EdgeInsets.all(16), behavior:SnackBarBehavior.floating,
        content:Row(children:[
          const Text('🎉', style:TextStyle(fontSize:24)), const SizedBox(width:12),
          Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisSize:MainAxisSize.min,children:[
            Text('Мөнгө хүрлээ!', style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w800,fontSize:15)),
            Text(txSnackSubtitle(tx),
                style:GoogleFonts.notoSans(color:Colors.white.withOpacity(0.85),fontSize:12)),
          ])),
        ])));
  }

  @override Widget build(BuildContext context) {
    final screens = [
      HomeScreen(history:_history, onNav:(i)=>setState(()=>_idx=i), onRepeat:_repeatTx),
      SendScreen(
        onTxAdded: _addTx,
        prefill: _prefillTx,
        onPrefillConsumed: _consumePrefill,
        onAfterMnDomesticDeclaredGoHomeTrack: _goHomeAndOpenTracking,
      ),
      const BillScreen(),
      const RatesScreen(),
      const ContactScreen(),
    ];
    return Scaffold(
        body: Stack(children:[
          screens[_idx],
          // Profile товч
          Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              right: 24,
              child: GestureDetector(
                  onTap: () => Navigator.push(context, MaterialPageRoute(
                      builder: (_) => ProfileScreen(history: _history))),
                  child: CircleAvatar(
                      radius: 21,
                      backgroundColor: Colors.black.withOpacity(0.12),
                      child: const Icon(Icons.person_rounded, color: Colors.black54)))),
        ]),
        bottomNavigationBar: _BottomNav(idx:_idx, onTap:(i)=>setState(()=>_idx=i)));
  }
}

class _BottomNav extends StatelessWidget {
  final int idx; final void Function(int) onTap;
  const _BottomNav({required this.idx, required this.onTap});
  @override Widget build(BuildContext context) {
    final items = [
      {'icon':Icons.home_rounded,'label':'Нүүр'},
      {'icon':Icons.send_rounded,'label':'Шилжүүлэх'},
      {'icon':Icons.apps_rounded,'label':'Боломж'},
      {'icon':Icons.trending_up_rounded,'label':'Ханш'},
      {'icon':Icons.phone_rounded,'label':'Холбоо'},
    ];
    return Container(
        decoration: BoxDecoration(
            gradient: const LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [kYellow, kYellowDeep]),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.25), blurRadius: 16, offset: const Offset(0, -4))]),
        child: SafeArea(top: false, child: Row(children: List.generate(items.length, (i) {
          final sel = i == idx;
          return Expanded(child: GestureDetector(onTap: () => onTap(i),
              child: Container(color: Colors.transparent, padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    AnimatedContainer(duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                            color: sel ? Colors.black.withOpacity(0.12) : Colors.transparent,
                            borderRadius: BorderRadius.circular(10)),
                        child: Icon(items[i]['icon'] as IconData,
                            color: sel ? Colors.black : Colors.black45, size: 22)),
                    const SizedBox(height: 2),
                    Text(items[i]['label'] as String,
                        style: GoogleFonts.notoSans(
                            color: sel ? Colors.black : Colors.black45,
                            fontSize: 10,
                            fontWeight: sel ? FontWeight.w800 : FontWeight.w500)),
                  ]))));
        }))));
  }
}

// ─── Shared ───────────────────────────────────────────────────────
class _PBtn extends StatelessWidget {
  final String label; final VoidCallback? onTap; final Color? bg; final Color? fg;
  const _PBtn({required this.label,required this.onTap,this.bg,this.fg});
  @override Widget build(BuildContext context)=>SizedBox(width:double.infinity,
      child:ElevatedButton(onPressed:onTap,
          style:ElevatedButton.styleFrom(backgroundColor:bg??kYellow, foregroundColor:fg??Colors.black,
              padding:const EdgeInsets.symmetric(vertical:16),
              shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(14)), elevation:0,
              textStyle:GoogleFonts.notoSans(fontWeight:FontWeight.w700,fontSize:16)),
          child:Text(label)));
}

class MSCard extends StatelessWidget {
  final Widget child; final EdgeInsets? padding; final Color? color;
  const MSCard({super.key,required this.child,this.padding,this.color});
  @override Widget build(BuildContext context)=>Container(
      margin:const EdgeInsets.only(bottom:10), padding:padding??const EdgeInsets.all(16),
      decoration:BoxDecoration(color:color??kCard, borderRadius:BorderRadius.circular(16), border:Border.all(color:kBorder)),
      child:child);
}

/// Лого доорх нэгдмэл уриа — бүх табын шар header-д харагдана.
Widget _headerTagline() => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        'Мөнгөн шилжүүлгийн үйлчилгээ',
        style: GoogleFonts.notoSans(
          color: Colors.black,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.15,
          height: 1.25,
        ),
      ),
    );

class AppHeader extends StatelessWidget {
  final Widget? trailing;
  const AppHeader({super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [kYellow, kYellowDeep],
          ),
        ),
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 12,
          left: 24,
          right: 24,
          bottom: 18,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text('Money',
                          style: GoogleFonts.imperialScript(
                              color: Colors.black, fontWeight: FontWeight.w700, fontSize: 26)),
                      const SizedBox(width: 3),
                      Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                              color: Colors.black, borderRadius: BorderRadius.circular(5)),
                          child: Text('SENT',
                              style: GoogleFonts.montserrat(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14,
                                  letterSpacing: 2))),
                    ],
                  ),
                  _headerTagline(),
                ],
              ),
            ),
            trailing ?? const SizedBox.shrink(),
          ],
        ),
      );
}

Widget _secTitle(String t)=>Padding(padding:const EdgeInsets.only(bottom:10),
    child:Text(t,style:GoogleFonts.notoSans(color:Colors.white38,fontSize:11,fontWeight:FontWeight.w700,letterSpacing:1.2)));

Widget _feeTableRow(String range, String value, {bool last = false}) => Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Text(range,
                style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 13)),
          ),
          Expanded(
            flex: 4,
            child: Text(value,
                textAlign: TextAlign.right,
                style: GoogleFonts.notoSans(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 13)),
          ),
        ],
      ),
    );

/// Шимтгэлийн дэлгэрэнгүй дэлгэц (нүүрний kachel-ээс нээгдэнэ).
class FeeInfoScreen extends StatelessWidget {
  final int historyLen;
  const FeeInfoScreen({super.key, required this.historyLen});

  @override
  Widget build(BuildContext context) {
    final tier = getMemberTier(historyLen);
    final pct = (tier.discount * 100).round();
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: kYellow, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Шимтгэлийн мэдээлэл',
          style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
        ),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'MoneySENT-ийн үйлчилгээний шимтгэл нь шилжүүлэгийн EUR үндсэн дүн дээр тооцогдоно. Доорх хүснэгтээр хамаарах хувь, тогтмол дүнг харна уу.',
            style: GoogleFonts.notoSans(color: Colors.white60, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 20),
          MSCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Үйлчилгээний шимтгэл (EUR)',
                  style: GoogleFonts.notoSans(
                    color: kYellow,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 14),
                _feeTableRow('0 – 100 EUR', '6 EUR (тогтмол)'),
                _feeTableRow('100 – 1 000 EUR', '6%'),
                _feeTableRow('1 000 – 5 000 EUR', '4%'),
                _feeTableRow('5 000 EUR-с дээш', '3%', last: true),
              ],
            ),
          ),
          const SizedBox(height: 14),
          MSCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text(tier.icon, style: const TextStyle(fontSize: 22)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Гишүүний зэрэглэл ба хөнгөлөлт',
                      style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13),
                    ),
                  ),
                ]),
                const SizedBox(height: 10),
                Text(
                  'Таны одоогийн зэрэглэл: ${tier.label}',
                  style: GoogleFonts.notoSans(color: tier.color, fontWeight: FontWeight.w700, fontSize: 13),
                ),
                const SizedBox(height: 8),
                Text(
                  tier == MemberTier.platinum
                      ? 'Та хамгийн дээд зэрэглэлд хүрсэн байна. Идэвхтэй гүйлгээ хийсээр байж, онцгой урамшууллаа үргэлжлүүлэн эдэлнэ үү.'
                      : 'Зэрэглэлээ дэвшүүлж илүү их урамшуулал аваарай — та олон гүйлгээ хийж, MoneySENT-ийг тогтмол ашигласнаар хөнгөлөлт, давуу эрх улам нэмэгдэнэ.${tier == MemberTier.bronze ? '' : ' Одоогийн зэрэглэлээрээ ойролцоогоор $pct% хүртэлх шимтгэлийн хөнгөлөлт тооцогдох боломжтой.'}',
                  style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 12.5, height: 1.45),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: kYellow.withOpacity(0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: kYellow.withOpacity(0.22)),
            ),
            child: Text(
              '⚠️ Банкны дотоод шимтгэл, валют хөрвүүлэлт болон гуравдагч талын хураамжаас үүдэлтэй давхар хасалтад MoneySENT хариуцлага хүлээхгүй гэдгийг анхааруулая.',
              style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 12, height: 1.5),
            ),
          ),
          const SizedBox(height: 18),
          Align(
            alignment: Alignment.centerRight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'Батлав.',
                  style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  '2026.01.08.',
                  style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Профайл → Хадгаламж: хугацаатай хадгаламжийн мэдээлэл, хүү (мэдээлэл зориулалттай).
class SavingsInfoScreen extends StatelessWidget {
  const SavingsInfoScreen({super.key});

  /// EUR хүснэгтийг саарал дэвсгэр дээр ялгаруулах (ягийн ягаанаар бараг харагдахгүй байсан).
  static const Color _eurTableAccent = Color(0xFF5AC8FA);

  static Widget _bullet(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('• ', style: GoogleFonts.notoSans(color: kGreen, fontWeight: FontWeight.w800, fontSize: 13)),
            Expanded(
              child: Text(text,
                  style: GoogleFonts.notoSans(color: Colors.white70, fontSize: 13, height: 1.45)),
            ),
          ],
        ),
      );

  static Widget _subBullet(String text) => Padding(
        padding: const EdgeInsets.only(left: 14, bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('– ',
                style: GoogleFonts.notoSans(color: Colors.white38, fontWeight: FontWeight.w700, fontSize: 12)),
            Expanded(
              child: Text(text,
                  style: GoogleFonts.notoSans(color: Colors.white60, fontSize: 12.5, height: 1.45)),
            ),
          ],
        ),
      );

  static TableRow _rateHeader({Color? rowBg}) => TableRow(
        decoration: BoxDecoration(color: rowBg ?? kYellow.withOpacity(0.08)),
        children: [
          _rateCell('Хугацаа', header: true),
          _rateCell('Дансны доод\nүлдэгдэл', header: true),
          _rateCell('Жилийн хүү', header: true),
          _rateCell('Гэрээ цуцалбал\nолгох хүү', header: true),
        ],
      );

  static Widget _rateCell(String s, {bool header = false}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Text(
          s,
          textAlign: TextAlign.center,
          style: GoogleFonts.notoSans(
            color: header ? Colors.white : Colors.white70,
            fontWeight: header ? FontWeight.w800 : FontWeight.w500,
            fontSize: header ? 11 : 12,
            height: 1.25,
          ),
        ),
      );

  static TableRow _rateData(String dur, String minBal, String annual, String early) => TableRow(
        children: [
          _rateCell(dur),
          _rateCell(minBal),
          _rateCell(annual),
          _rateCell(early),
        ],
      );

  static Widget _rateTable(
    List<(String, String, String, String)> rows, {
    Color? headerRowBg,
  }) =>
      Table(
        border: TableBorder.all(color: kBorder.withOpacity(0.6), width: 0.8),
        columnWidths: const {
          0: FlexColumnWidth(1.35),
          1: FlexColumnWidth(1.15),
          2: FlexColumnWidth(1),
          3: FlexColumnWidth(1.2),
        },
        children: [
          _rateHeader(rowBg: headerRowBg),
          ...rows.map((r) => _rateData(r.$1, r.$2, r.$3, r.$4)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: kYellow, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Хадгаламж',
          style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
        ),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: kGreen.withOpacity(0.12),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: kGreen.withOpacity(0.35)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.schedule_rounded, color: kGreen, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Уг үйлчилгээг тун удахгүй',
                    style: GoogleFonts.notoSans(color: kGreen, fontWeight: FontWeight.w800, fontSize: 14, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Text(
            'ХАДГАЛАМЖИЙН ҮЙЛЧИЛГЭЭНИЙ МЭДЭЭЛЭЛ',
            style: GoogleFonts.notoSans(color: kYellow, fontWeight: FontWeight.w900, fontSize: 13.5, height: 1.35),
          ),
          const SizedBox(height: 14),
          Text(
            'ЭНГИЙН ХУГАЦААТАЙ ХАДГАЛАМЖ',
            style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14),
          ),
          const SizedBox(height: 10),
          Text(
            'Та 1–24 сар хүртэлх хугацаагаар, хүүгээ хугацааны эцэст тооцуулан авахыг хүсвэл энгийн хугацаатай хадгаламжийн үйлчилгээг сонгоорой. Та төгрөг, еврогийн валютаас сонгон хугацаатай хадгаламж нээлгэх боломжтой.',
            style: GoogleFonts.notoSans(color: Colors.white60, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 18),
          Text(
            'ДАВУУ ТАЛ',
            style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13),
          ),
          const SizedBox(height: 8),
          _bullet('Хүссэн үедээ орлого хийх'),
          _bullet('Хадгаламжийн дансаа барьцаалан зээл авах'),
          _bullet('Завсрын хугацаанд буюу хугацаа сунгагдсанаас хойш 14 хоногт зарлагын гүйлгээ хийх'),
          _bullet('Цахим банкны үйлчилгээгээр дансаа хянах'),
          _bullet(
              'Дансаа хуримтлалын үйлчилгээнд үнэгүй холбуулан, хадгаламжийн данс руугаа автоматаар тогтмол хугацаанд, тогтмол дүнгээр, хураамжгүйгээр шилжүүлэг хийх'),
          const SizedBox(height: 14),
          Text(
            'ХЭРХЭН ХЭРЭГЛЭГЧ БОЛОХ ВЭ?',
            style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13),
          ),
          const SizedBox(height: 8),
          _bullet(
              'Та Интернетээр дамжуулан дэлхийн хаанаас ч хормын дотор, шимтгэлгүйгээр хугацаатай хадгаламжийн данс нээх боломжтой.'),
          _bullet(
              'Харин та дараах бичиг баримтуудыг бүрдүүлэн өөрт ойр салбарт хандан хадгаламжийн дансаа нээлгээрэй.'),
          const SizedBox(height: 14),
          Text(
            'БҮРДҮҮЛЭХ МАТЕРИАЛ',
            style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13),
          ),
          const SizedBox(height: 8),
          Text('Монгол Улсын иргэн',
              style: GoogleFonts.notoSans(color: kYellow, fontWeight: FontWeight.w700, fontSize: 12.5)),
          _subBullet(
              'Иргэний үнэмлэх эсвэл Улсын бүртгэлийн ерөнхий газраас олгосон иргэний үнэмлэхний дэлгэрэнгүй лавлагаа'),
          _subBullet('Гараар бичсэн өргөдөл.'),
          const SizedBox(height: 10),
          Text('Гадаадын иргэн',
              style: GoogleFonts.notoSans(color: kYellow, fontWeight: FontWeight.w700, fontSize: 12.5)),
          _subBullet('Гадаад паспорт'),
          _subBullet('Гараар бичсэн өргөдөл.'),
          const SizedBox(height: 22),
          MSCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Хүүний хүснэгт',
                  style: GoogleFonts.notoSans(color: kYellow, fontWeight: FontWeight.w800, fontSize: 13),
                ),
                const SizedBox(height: 6),
                Text(
                  'Дансны доод үлдэгдэл — тухайн валютаар. Жилийн хүү.',
                  style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11.5, height: 1.35),
                ),
                const SizedBox(height: 14),
                Text('Төгрөг (MNT)',
                    style: GoogleFonts.notoSans(color: kGreen, fontWeight: FontWeight.w800, fontSize: 12.5)),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final w = constraints.maxWidth >= 520 ? constraints.maxWidth : 520.0;
                    return SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: w,
                        child: _rateTable(const [
                          ('30 хоног', '20 000', '7.00%', '3.60%'),
                          ('60 хоног', '20 000', '7.80%', '3.60%'),
                          ('90 хоног', '20 000', '8.20%', '3.60%'),
                          ('180 хоног', '20 000', '11.20%', '3.60%'),
                          ('9 сар', '20 000', '11.50%', '3.60%'),
                          ('365 хоног', '20 000', '12.80%', '3.60%'),
                          ('18 сар', '20 000', '12.90%', '3.60%'),
                          ('24 сар', '20 000', '13.10%', '3.60%'),
                        ], headerRowBg: kGreen.withOpacity(0.14)),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 18),
                Text('Евро (EUR)',
                    style: GoogleFonts.notoSans(color: _eurTableAccent, fontWeight: FontWeight.w800, fontSize: 12.5)),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final w = constraints.maxWidth >= 520 ? constraints.maxWidth : 520.0;
                    return Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: _eurTableAccent.withOpacity(0.07),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _eurTableAccent.withOpacity(0.45), width: 1.2),
                      ),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: w - 20,
                          child: _rateTable(
                            const [
                              ('90 хоног', '50', '2.40%', '1.20%'),
                              ('180 хоног', '50', '3.00%', '1.20%'),
                              ('9 сар', '50', '4.80%', '1.20%'),
                            ],
                            headerRowBg: _eurTableAccent.withOpacity(0.22),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Нэг дор: гишүүнчлэл, хөнгөлөлт, шилжүүлэг, зээлийн урсгалын заавар.
class AppGuideScreen extends StatelessWidget {
  final int historyLen;
  const AppGuideScreen({super.key, required this.historyLen});

  Widget _h(String title) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(title,
            style: GoogleFonts.notoSans(color: kYellow, fontWeight: FontWeight.w800, fontSize: 14, height: 1.3)),
      );

  Widget _p(String body) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(body,
            style: GoogleFonts.notoSans(color: Colors.white60, fontSize: 13, height: 1.55)),
      );

  Widget _b(String line) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('• ',
                style: GoogleFonts.notoSans(color: kGreen, fontWeight: FontWeight.w800, fontSize: 13)),
            Expanded(
              child: Text(line,
                  style: GoogleFonts.notoSans(color: Colors.white70, fontSize: 13, height: 1.45)),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final tier = getMemberTier(historyLen);
    final nextName = switch (tier) {
      MemberTier.bronze => 'Silver 🥈',
      MemberTier.silver => 'Gold 👑',
      MemberTier.gold => 'Platinum 💎',
      MemberTier.platinum => '',
    };
    final remain = tier == MemberTier.platinum ? 0 : (tier.nextTarget - historyLen).clamp(0, 9999);

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: kYellow, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Апп хэрэглэх заавар',
          style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
        ),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          MSCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(tier.icon, style: const TextStyle(fontSize: 28)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Таны одоогийн зэрэглэл',
                    style: GoogleFonts.notoSans(color: Colors.white54, fontWeight: FontWeight.w600, fontSize: 12),
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              Text(
                '${tier.label} Member · шимтгэлийн хөнгөлөлт ${(tier.discount * 100).toStringAsFixed(0)}%',
                style: GoogleFonts.notoSans(color: tier.color, fontWeight: FontWeight.w800, fontSize: 15),
              ),
              if (tier != MemberTier.platinum) ...[
                const SizedBox(height: 8),
                Text(
                  '$historyLen / ${tier.nextTarget} гүйлгээ · Дараагийн зэрэглэл ($nextName) хүртэл ${remain > 0 ? 'ойролцоогоор $remain гүйлгээ' : 'бэлэн'}',
                  style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12, height: 1.4),
                ),
              ] else ...[
                const SizedBox(height: 8),
                Text(
                  '$historyLen гүйлгээ · Хамгийн дээд Platinum зэрэглэл',
                  style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12, height: 1.4),
                ),
              ],
            ]),
          ),
          _h('Гишүүнчлэл ба шимтгэлийн хөнгөлөлт'),
          _p(
              'Гүйлгээний тоо (түүхэнд хадгалагдсан гүйлгээний нийт тоо) таны зэрэглэлийг автоматаар тохируулна. Тусад нь бүртгэл өөрчлөх, хүсэлт гаргах шаардлагагүй.'),
          _b(
              '🥉 Bronze: 0–9 гүйлгээ — үндсэн үйлчилгээ; шимтгэлийн хөнгөлөлтийн хувь 0%.'),
          _b('🥈 Silver: 10+ гүйлгээ — ойролцогоор 5% шимтгэлийн хөнгөлөлт.'),
          _b('👑 Gold: 50+ гүйлгээ — ойролцогоор 10% хөнгөлөлт.'),
          _b('💎 Platinum: 100+ гүйлгээ — ойролцогоор 20% хөнгөлөлт.'),
          _p(
              'Гүйлгээ амжилттай дуусах бүрт тоо шинэчлэгдэж, дараагийн шатны шаардлагыг Профайл дээрх гишүүний карт, явцын самбараас харна.'),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: kYellow.withOpacity(0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kYellow.withOpacity(0.2)),
            ),
            child: Text(
              '💡 Зэрэглэл автоматаар дэвших бөгөөд шимтгэлийн хөнгөлөлт шилжүүлэх дүнд шууд тооцогдоно.',
              style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 12, height: 1.5),
            ),
          ),
          _h('Энгийн шилжүүлэг'),
          _b('Нүүр → «Мөнгө шилжүүлэх» — чиглэл (Европ ↔ Монгол), дүн, төлбөрийн аргыг сонгоно.'),
          _b('Дэлгэц дээр ханш, шимтгэл, нийт төлөх дүн, хүлээн авах дүн тооцогдон харагдана.'),
          _b('Төлбөр төлөөд үйл явцыг «Гүйлгээ» / түүхэн дэх картнаас дагаж болно.'),
          _h('Зээл авах ба зээлээр шилжүүлэх'),
          _p(
              '«Зээлээр шилжүүлэх» горим нь зөвхөн зээлийн эрх баталгаажсан үед ажиллана. Нэг хэрэглэгч нэг удаад нэг л идэвхтэй зээлийн үүрэгтэй байж болно — өмнөхийг бүрэн төлөөгүй бол дахин энэ горимыг ашиглах боломжгүй.'),
          _p(
              'Одоогоор шилжүүлэх үндсэн дүн (EUR) хамгийн ихдээ ${LoanStore.maxLoanPrincipalEur.toStringAsFixed(0)} EUR. Хэрэглээний судалгаагаар дээд хэмжээ өсөх эсвэл буурахыг тусад нь батална.'),
          _b(
              'Эхлээд Профайл → «Зээлийн эрх авах» / «Зээл»-ээр хүсэлт гаргана: Meldebescheinigung, гэрээ, 3 сарын цалин, Selbstauskunft, SEPA Lastschrift зэрэг баримтууд.'),
          _b(
              'Зээлийн гэрээ байгуулж гарын үсэг зурснаар идэвхтэй үүрэг үүсч, үлдэгдэл болон эрт хаах тооцооллыг Профайл → «Зээлийн эрхтэй гишүүн» дарахад харагдах «Зээлийн үлдэгдэл» дэлгэцээс үзнэ.'),
          _b(
              'Хугацаа дуусахаас өмнө бүтнээр хаах тохиолдолд гэрээний хүүний хэсэг дээр Монголын банкны жишиг жилийн хүү (${(LoanStore.mnBenchmarkAnnualRate * 100).toStringAsFixed(1)}%) — зээл эхэлсэн өдрөөс сонгосон хаах өдөр хүртэлх хоногоор пропорционал нэмэгдэл тооцогдоно (апп дээр ойролцоолол).'),
          _p(
              'Зээлийн бодолтын нарийвчилсан мөр: шилжүүлэх дэлгэцийн «Зээлийн бодолт» хэсэгт харагдана.'),
          _h('Бусад'),
          _b('Ханш: Профайл → «Ханш».'),
          _b('Шимтгэлийн хүснэгт, гишүүний дэлгэрэнгүй: Профайл → «Хөнгөлөлт» эсвэл нүүр → «Шимтгэлийн мэдээлэл».'),
          _b('Хадгаламжийн мэдээлэл (үзүүлэх гэрээ): Профайл → «Хадгаламж».'),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => FeeInfoScreen(historyLen: historyLen))),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              decoration: BoxDecoration(
                color: kBlue.withOpacity(0.12),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: kBlue.withOpacity(0.35)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.table_chart_rounded, color: kBlue.withOpacity(0.95), size: 20),
                  const SizedBox(width: 10),
                  Text(
                    'Шимтгэлийн мэдээллийг нээх →',
                    style: GoogleFonts.notoSans(
                        color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13.5),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  final List<TxRecord> history;
  final void Function(int) onNav;
  final void Function(TxRecord) onRepeat;
  const HomeScreen({super.key, required this.history, required this.onNav, required this.onRepeat});

  @override Widget build(BuildContext context) {
    final active = history.where((t) => !t.isCompleted).toList();
    return Column(children: [
      const AppHeader(),
      Expanded(child: ListView(padding: const EdgeInsets.all(20), children: [
        // ── Идэвхтэй гүйлгээ ──────────────────────────────────────
        if (active.isNotEmpty) ...[
          GestureDetector(
            onTap: () => onNav(2),
            child: Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [kYellow.withOpacity(0.15), kYellow.withOpacity(0.05)]),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: kYellow.withOpacity(0.4))),
              child: Row(children: [
                _PulseIcon(Icons.rocket_launch_rounded, kYellow),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${active.length} гүйлгээ хийгдэж байна',
                      style: GoogleFonts.notoSans(color: kYellow, fontWeight: FontWeight.w700, fontSize: 14)),
                  Text(active.first.currentStep.labelFor(txFlowDir(active.first)),
                      style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 12)),
                ])),
                const Icon(Icons.arrow_forward_ios, color: kYellow, size: 14),
              ]),
            ),
          ),
        ],

        // ── Товч товчлуурууд (шимтгэлийн kachel → тусад дэлгэц) ────────
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: AspectRatio(
                    aspectRatio: 1.4,
                    child: _QCard(
                      icon: Icons.send_rounded,
                      label: 'Мөнгө шилжүүлэх',
                      color: kYellow,
                      sub: 'Хурдан, найдвартай',
                      onTap: () => onNav(1),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: AspectRatio(
                    aspectRatio: 1.4,
                    child: _QCard(
                      icon: Icons.apps_rounded,
                      label: 'Боломж',
                      color: const Color(0xFF00C9A7),
                      sub: 'ТВ · Утас · Цахилгаан',
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BillScreen())),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: AspectRatio(
                    aspectRatio: 1.4,
                    child: _QCard(
                      icon: Icons.trending_up_rounded,
                      label: 'Ханш харах',
                      color: kGreen,
                      sub: 'Хаан Банк бэлэн',
                      onTap: () => onNav(3),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: AspectRatio(
                    aspectRatio: 1.4,
                    child: _QCard(
                      icon: Icons.payments_rounded,
                      label: 'Шимтгэлийн мэдээлэл',
                      color: kPurple,
                      sub: 'Дэлгэрэнгүй',
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => FeeInfoScreen(historyLen: history.length))),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),

        const SizedBox(height: 20),

        if (history.isNotEmpty) ...[
          _secTitle('ГҮЙЛГЭЭНИЙ ТҮҮХ'),
          ...history.map((tx) => _TxMini(tx: tx, onRepeat: onRepeat)).toList(),
        ] else ...[
          const SizedBox(height: 24),
          Center(
              child: Column(children: [
            const Icon(Icons.receipt_long_rounded, color: Colors.white12, size: 48),
            const SizedBox(height: 12),
            Text('Гүйлгээний түүх хоосон байна',
                style: GoogleFonts.notoSans(color: Colors.white24, fontSize: 13)),
          ])),
        ],
        const SizedBox(height: 16),
      ])),
    ]);
  }
}

class _QCard extends StatelessWidget {
  final IconData icon; final String label,sub; final Color color; final VoidCallback onTap;
  const _QCard({required this.icon,required this.label,required this.sub,required this.color,required this.onTap});
  @override Widget build(BuildContext context)=>GestureDetector(onTap:onTap,
      child:SizedBox.expand(
          child:Container(padding:const EdgeInsets.all(14),
          decoration:BoxDecoration(color:kCard,borderRadius:BorderRadius.circular(16),border:Border.all(color:kBorder)),
          child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Container(padding:const EdgeInsets.all(8),
                decoration:BoxDecoration(color:color.withOpacity(0.12),borderRadius:BorderRadius.circular(10)),
                child:Icon(icon,color:color,size:22)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: Text(
                        label,
                        style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  Text(
                    sub,
                    style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ]))));
}

class _AccCard extends StatelessWidget {
  final IconData icon; final String label,sub,balance; final Color color;
  const _AccCard({required this.icon,required this.label,required this.sub,required this.balance,required this.color});
  @override Widget build(BuildContext context)=>MSCard(child:Row(children:[
    Container(width:40,height:40,decoration:BoxDecoration(color:color.withOpacity(0.12),borderRadius:BorderRadius.circular(10)),child:Icon(icon,color:color,size:20)),
    const SizedBox(width:12),
    Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(label,style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w700,fontSize:14)),
      Text(sub,style:GoogleFonts.notoSans(color:Colors.white38,fontSize:11)),
    ])),
    Text(balance,style:GoogleFonts.notoSans(color:kYellow,fontWeight:FontWeight.w700,fontSize:14)),
  ]));
}

class _TxMini extends StatelessWidget {
  final TxRecord tx;
  final void Function(TxRecord) onRepeat;
  const _TxMini({required this.tx, required this.onRepeat});
  @override Widget build(BuildContext context) => GestureDetector(
    onTap: () => Navigator.push(context, MaterialPageRoute(
        builder: (_) => TrackingScreen(tx: tx, onRepeat: onRepeat))),
    child: MSCard(child: Row(children: [
      Container(width: 38, height: 38,
          decoration: BoxDecoration(
              color: tx.isCompleted ? kGreen.withOpacity(0.12) : kYellow.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10)),
          child: Icon(tx.currentStep.icon,
              color: tx.isCompleted ? kGreen : kYellow, size: 18)),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${tx.from} → ${tx.to}',
            style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
        Text(tx.currentStep.labelFor(txFlowDir(tx)),
            style: GoogleFonts.notoSans(color: tx.isCompleted ? kGreen : kYellow, fontSize: 11)),
      ])),
      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(txListPrimaryAmt(tx),
            style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
        Text(txListSecondaryAmt(tx),
            style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11)),
      ]),
    ])),
  );
}

/// EuDepositReferenceSheetScreen-ээс буцах үр дүн (баталгаа + банкны апп мэдэгдэл).
class EuDepositSheetResult {
  final bool confirmed;
  /// Хэрэглэгч «Би банкны аппаар EUR шилжүүлж дууслаа» гэж дарсан эсэх.
  final bool userDeclaredBankSepaSent;

  const EuDepositSheetResult({
    required this.confirmed,
    this.userDeclaredBankSepaSent = false,
  });
}

/// Гар аргаар банкнаас EUR шилжүүлэх мэдээлэл — шинэ бүтэн дэлгэц (IBAN хуулах гэх мэт).
class ManualBankTransferInfoScreen extends StatelessWidget {
  final String referenceCode;
  final String summaryLine;
  final String expectedAmountDisplay;

  const ManualBankTransferInfoScreen({
    super.key,
    required this.referenceCode,
    required this.summaryLine,
    required this.expectedAmountDisplay,
  });

  Future<void> _copy(BuildContext context, String label, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text('$label хуулагдлаа', style: GoogleFonts.notoSans()),
    ));
  }

  Widget _depositRow(BuildContext context, String label, String value, {String? copyText}) {
    final clip = copyText ?? value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(label,
                style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12)),
          ),
          Expanded(
            child: Text(value,
                style: GoogleFonts.notoSans(
                    color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            onPressed: () => _copy(context, label, clip),
            icon: const Icon(Icons.copy_rounded, color: Colors.white24, size: 20),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ibanCompact = PayMethod.wiseIban.replaceAll(' ', '');
    final bicCompact = PayMethod.wiseBic.replaceAll(' ', '');
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: kYellow),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Гар аргаар шилжүүлэх',
          style: GoogleFonts.notoSans(
              color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
        ),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          Text(
            summaryLine,
            style: GoogleFonts.notoSans(
                color: kYellow, fontWeight: FontWeight.w700, fontSize: 14),
          ),
          const SizedBox(height: 10),
          Text(
            'Доорх EUR данс руу SEPA/гар шилжүүлэг хийнэ. Утга / тайлбарт заавал reference кодыг оруулна.',
            style: GoogleFonts.notoSans(
                color: Colors.white60, fontSize: 13, height: 1.45),
          ),
          const SizedBox(height: 18),
          MSCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Шилжүүлэх данс',
                    style: GoogleFonts.notoSans(
                        color: kYellow, fontWeight: FontWeight.w800, fontSize: 13)),
                const SizedBox(height: 12),
                _depositRow(context, 'IBAN', PayMethod.wiseIban, copyText: ibanCompact),
                _depositRow(context, 'BIC/SWIFT', PayMethod.wiseBic, copyText: bicCompact),
                _depositRow(context, 'Байгууллага', PayMethod.sepaCompanyName),
                _depositRow(context, 'Эзэмшигч', PayMethod.sepaAccountHolder),
                _depositRow(context, 'Төлөх дүн', expectedAmountDisplay),
                _depositRow(context, 'Утга (reference)', referenceCode, copyText: referenceCode),
                const SizedBox(height: 8),
                Text(
                  '⚠️ Гүйлгээний утга / тайлбарт заавал энэ кодыг оруулна уу.',
                  style: GoogleFonts.notoSans(color: kRed, fontSize: 11, height: 1.35),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final bundle = PayMethod.sepaBankAppPasteBundle(
                        amountDisplay: expectedAmountDisplay,
                        referenceCode: referenceCode,
                      );
                      await Clipboard.setData(ClipboardData(text: bundle));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        behavior: SnackBarBehavior.floating,
                        content: Text(
                          'IBAN, дүн, reference бүхэлд нь хуулагдлаа — банкны аппныхаа талбарууд руу буулгаж наана уу.',
                          style: GoogleFonts.notoSans(fontSize: 13, height: 1.35),
                        ),
                      ));
                    },
                    icon: const Icon(Icons.content_paste_go_rounded, color: kYellow, size: 22),
                    label: Text(
                      'Банкны аппанд буулгах бүх мэдээлэл хуулах',
                      style: GoogleFonts.notoSans(
                          color: kYellow, fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1200),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kYellow.withOpacity(0.2)),
            ),
            child: Text(
              '⚠️ Сануулга: Банкны дотоод шимтгэл, валют хөрвүүлэлтээс үүдэлтэй давхар хасалтад MoneySENT хариуцлага хүлээхгүй.',
              style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 11, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// Монгол → Европ гараар: Хаан MNT дансны заавар + захиалга/админ баталгааны урсгалыг тайлбарлана.
class MnDomesticManualTransferScreen extends StatefulWidget {
  final String mntPayDisplay;
  /// Жишээ 1500000 — «Төлөх дүн» мөрийн хуулах утга (зөвхөн тоо).
  final String mntAmountPlain;
  final String eurRecvSummary;
  /// Голомтын «Reference 2» / нэмэлт утганд — MoneySENT нэг удаагийн код.
  final String depositReference;
  /// true бол app bar + Голомт горим: Хаан банкны IBAN автоматаар clipboard-д хуулна.
  final bool golomtAppGuidance;

  const MnDomesticManualTransferScreen({
    super.key,
    required this.mntPayDisplay,
    required this.mntAmountPlain,
    required this.depositReference,
    required this.eurRecvSummary,
    this.golomtAppGuidance = false,
  });

  @override
  State<MnDomesticManualTransferScreen> createState() => _MnDomesticManualTransferScreenState();
}

class _MnDomesticManualTransferScreenState extends State<MnDomesticManualTransferScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.golomtAppGuidance) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _autoCopyKhanIban());
    }
  }

  /// Зөвхөн Голомт төлбөрийн арга: зөвхөн манай Хаан банкны IBAN (зайгүй).
  Future<void> _autoCopyKhanIban() async {
    final iban = PayMethod.mnManualDepositAccount.replaceAll(' ', '');
    await Clipboard.setData(ClipboardData(text: iban));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF2C2610),
      content: Text(
        'Хаан банкны IBAN хуулагдлаа — Голомт аппын хүлээн авагчийн талбарт наана уу.\n$iban',
        style: GoogleFonts.notoSans(fontSize: 12.5, height: 1.38, color: Colors.white),
      ),
    ));
  }

  Future<void> _copy(BuildContext context, String label, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text('$label хуулагдлаа', style: GoogleFonts.notoSans()),
    ));
  }

  Widget _row(BuildContext context, String label, String value, {String? copyText}) {
    final clip = copyText ?? value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Text(label,
                style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12)),
          ),
          Expanded(
            child: Text(value,
                style: GoogleFonts.notoSans(
                    color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13.5, height: 1.3)),
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            onPressed: () => _copy(context, label, clip),
            icon: const Icon(Icons.copy_rounded, color: Colors.white24, size: 20),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final acctCompact = PayMethod.mnManualDepositAccount.replaceAll(' ', '');
    final g = widget.golomtAppGuidance;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: kYellow),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          g ? 'Голомт банк · ₮ шилжүүлэг' : 'Гараар шилжүүлэх',
          style: GoogleFonts.notoSans(
              color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
        ),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          if (g) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: kYellow.withOpacity(0.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: kYellow.withOpacity(0.38)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.content_paste_go_rounded, color: kYellow, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Төлбөрийн аргаар «Голомт» сонгогдсон тул манай Хаан банкны IBAN ($acctCompact) автоматаар хууллаа. Доорх картаас дахин хуулах боломжтой.',
                      style: GoogleFonts.notoSans(
                          color: Colors.white.withOpacity(0.9), fontSize: 12.5, height: 1.42, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ] else ...[
            Text(
              'Доорх данс, дүн, Reference-ийг банкныхаа аппад яг ижилхэн оруулж ₮ шилжүүлнэ үү.',
              style: GoogleFonts.notoSans(
                  color: Colors.white70, fontSize: 13, height: 1.45, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 14),
          ],
          MSCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Шилжүүлэх данс (Монгол · Хаан банк)',
                    style: GoogleFonts.notoSans(
                        color: kYellow, fontWeight: FontWeight.w800, fontSize: 13)),
                const SizedBox(height: 12),
                _row(context, g ? 'IBAN' : 'Дансны №', PayMethod.mnManualDepositAccount, copyText: acctCompact),
                _row(context, 'Банк', PayMethod.mnManualDepositBankName),
                _row(context, 'Эзэмшигч', PayMethod.mnManualDepositHolder),
                _row(context, 'Төлөх дүн', widget.mntPayDisplay, copyText: widget.mntAmountPlain),
                const Divider(color: kBorder, height: 22),
                Text('Reference дугаар',
                    style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 11.5, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF151515),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF00B9FF).withOpacity(0.45)),
                        ),
                        child: SelectableText(
                          widget.depositReference,
                          style: GoogleFonts.robotoMono(
                              color: const Color(0xFF81D4FA),
                              fontWeight: FontWeight.w700,
                              fontSize: 14),
                        ),
                      ),
                    ),
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                      onPressed: () => _copy(context, 'Reference дугаар', widget.depositReference),
                      icon: const Icon(Icons.copy_rounded, color: Colors.white24, size: 20),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '⚠️ Reference буруу эсвэл дутуу бол төгрөг таны захиалгатай холбогдохгүй.',
                    style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 11, height: 1.42),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text(
            '${widget.mntPayDisplay}  →  ${widget.eurRecvSummary}',
            style: GoogleFonts.notoSans(
                color: kYellow, fontWeight: FontWeight.w800, fontSize: 14, height: 1.35),
          ),
          const SizedBox(height: 10),
          Text(
            'Дараагийн алхмууд',
            style: GoogleFonts.notoSans(
              color: const Color(0xFF81C784),
              fontWeight: FontWeight.w800,
              fontSize: 12.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '• Төгрөг манай дансанд ормогц оператор шалгаад, хүлээн авагчийн EUR IBAN руу гүйлгээг баталгаажуулна.\n'
            '• Баталгаажсаны дараа мэдэгдэл ирнэ; Tracking дээр «Амжилттай хүргэгдлээ» гэсэн төлөв гарна.\n'
            '• Reference-ийг «Reference 2» болон «Гүйлгээний утга / тайлбар»-т ижилхэн оруулна (латин нэр биш).',
            style: GoogleFonts.notoSans(color: Colors.white60, fontSize: 13, height: 1.48),
          ),
          const SizedBox(height: 16),
          Text(
            '₮ шилжүүлсний дараа доорх товчийг дарана — захиалга бүртгэгдэнэ. EUR IBAN оруулсан бол админы самбарт хамт харагдана.',
            style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11.5, height: 1.42),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: kYellow,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: Text(
                '₮ - Шилжсөн. Хүсэлт илгээх.',
                style: GoogleFonts.notoSans(fontWeight: FontWeight.w800, fontSize: 15),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Send.mn / Ria-тай төстэй: манай EUR (SEPA) дансанд reference-тэй шилжүүлэг → апп дээр код баталгаа → MN данс руу урсгал.
class EuDepositReferenceSheetScreen extends StatefulWidget {
  final String referenceCode;
  final String expectedAmountDisplay;
  final String paypalAmountSegment;
  final String mntReceiveDisplay;
  final String recipientName;
  final String mnAccountDisplay;

  const EuDepositReferenceSheetScreen({
    super.key,
    required this.referenceCode,
    required this.expectedAmountDisplay,
    required this.paypalAmountSegment,
    required this.mntReceiveDisplay,
    required this.recipientName,
    required this.mnAccountDisplay,
  });

  @override
  State<EuDepositReferenceSheetScreen> createState() => _EuDepositReferenceSheetState();
}

class _EuDepositReferenceSheetState extends State<EuDepositReferenceSheetScreen> {
  late final TextEditingController _code;
  bool _confirmedDeposit = false;
  bool _declaredBankSepaSent = false;

  @override
  void initState() {
    super.initState();
    _code = TextEditingController(text: widget.referenceCode);
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  static String _norm(String s) =>
      s.toUpperCase().replaceAll(RegExp(r'[\s\-]'), '');

  bool get _codesMatch => _norm(_code.text) == _norm(widget.referenceCode);

  Future<void> _copy(BuildContext context, String label, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text('$label хуулагдлаа', style: GoogleFonts.notoSans()),
    ));
  }

  Future<void> _openPay(PayMethod p) async {
    final url = p.url;
    if (url.isEmpty) return;
    final uri = p.id == 'paypal'
        ? Uri.parse('$url/${widget.paypalAmountSegment}')
        : Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Widget _depositRow(BuildContext context, String label, String value, {String? copyText}) {
    final clip = copyText ?? value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(label,
                style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12)),
          ),
          Expanded(
            child: Text(value,
                style: GoogleFonts.notoSans(
                    color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            onPressed: () => _copy(context, label, clip),
            icon: const Icon(Icons.copy_rounded, color: Colors.white24, size: 20),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ibanCompact = PayMethod.wiseIban.replaceAll(' ', '');
    final bicCompact = PayMethod.wiseBic.replaceAll(' ', '');
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: kYellow),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'EUR дансанд шилжүүлэх',
          style: GoogleFonts.notoSans(
              color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15),
        ),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          Text(
            'Эхлээд доорх EUR (SEPA) данс руу төлбөр хийнэ. Тайлбар/reference талбарт заавал доорх кодыг оруулна. Дараа нь кодыг шалгаад баталгаажуулбал систем Хаан банкны данс руу ₮ илгээхийг эхлүүлнэ.',
            style: GoogleFonts.notoSans(
                color: Colors.white60, fontSize: 13, height: 1.45),
          ),
          const SizedBox(height: 16),
          MSCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Шилжүүлэх данс (SEPA)',
                    style: GoogleFonts.notoSans(
                        color: kYellow, fontWeight: FontWeight.w800, fontSize: 13)),
                const SizedBox(height: 12),
                _depositRow(context, 'IBAN', PayMethod.wiseIban, copyText: ibanCompact),
                _depositRow(context, 'BIC/SWIFT', PayMethod.wiseBic, copyText: bicCompact),
                _depositRow(context, 'Байгууллага', PayMethod.sepaCompanyName),
                _depositRow(context, 'Эзэмшигч', PayMethod.sepaAccountHolder),
                _depositRow(context, 'Төлөх дүн', widget.expectedAmountDisplay),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final bundle = PayMethod.sepaBankAppPasteBundle(
                        amountDisplay: widget.expectedAmountDisplay,
                        referenceCode: widget.referenceCode,
                      );
                      await Clipboard.setData(ClipboardData(text: bundle));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        behavior: SnackBarBehavior.floating,
                        content: Text(
                          'IBAN, дүн, reference бүхэлд нь хуулагдлаа — банкны аппныхаа талбарууд руу буулгаж наана уу.',
                          style: GoogleFonts.notoSans(fontSize: 13, height: 1.35),
                        ),
                      ));
                    },
                    icon: const Icon(Icons.content_paste_go_rounded, color: kYellow, size: 20),
                    label: Text(
                      'Банкны аппанд буулгах бүх мэдээлэл хуулах',
                      style: GoogleFonts.notoSans(
                          color: kYellow, fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kYellow,
                      side: const BorderSide(color: kYellow),
                      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Зарим банкны апп талбарыг автоматаар бөглөж чадахгүй; хуулагдсаныг дандаа шалгаарай.',
                  style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11, height: 1.35),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          MSCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Заавал: тайлбар / reference',
                    style: GoogleFonts.notoSans(
                        color: const Color(0xFF00B9FF),
                        fontWeight: FontWeight.w800,
                        fontSize: 13)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A1825),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: const Color(0xFF00B9FF).withOpacity(0.35)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          widget.referenceCode,
                          style: GoogleFonts.robotoMono(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 15),
                        ),
                      ),
                      IconButton(
                        onPressed: () =>
                            _copy(context, 'Reference', widget.referenceCode),
                        icon:
                            const Icon(Icons.copy_rounded, color: kYellow, size: 22),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Wise, PayPal, Revolut, Ria Money зэрэг олон улсын апп дээр ч гэсэн ижил төлөх дүнгээр шилжүүлээд, тайлбарт энэ кодыг оруулна.',
                  style: GoogleFonts.notoSans(
                      color: Colors.white38, fontSize: 11, height: 1.35),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          MSCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Монгол руу орох данс',
                    style: GoogleFonts.notoSans(
                        color: Colors.white54,
                        fontWeight: FontWeight.w700,
                        fontSize: 12)),
                const SizedBox(height: 8),
                Text(widget.recipientName,
                    style: GoogleFonts.notoSans(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 14)),
                const SizedBox(height: 4),
                Text(widget.mnAccountDisplay,
                    style: GoogleFonts.robotoMono(
                        color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 6),
                Text(widget.mntReceiveDisplay,
                    style: GoogleFonts.notoSans(
                        color: kYellow, fontWeight: FontWeight.w800, fontSize: 15)),
              ],
            ),
          ),
          const SizedBox(height: 14),
          MSCard(
            color: const Color(0xFF151A22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Банкны аппаас EUR шилжүүлсэн эсэх',
                  style: GoogleFonts.notoSans(
                      color: const Color(0xFF00B9FF),
                      fontWeight: FontWeight.w800,
                      fontSize: 13),
                ),
                const SizedBox(height: 8),
                Text(
                  'MoneySENT апп таны банкнаас гарсан EUR-ийг манай Revolut дансанд үнэхээр орсон эсэхийг автоматаар шалгахгүй (ихэвчлэн SEPA хэдэн минут–1 ажлын өдөр үргэлжилнэ). '
                  'Банкныхаа аппаар шилжүүлгээ илгээж дууссаны дараа доорх товчийг дарж мэдэгдэнэ үү.',
                  style: GoogleFonts.notoSans(
                      color: Colors.white54, fontSize: 12, height: 1.45),
                ),
                const SizedBox(height: 12),
                if (!_declaredBankSepaSent)
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        setState(() => _declaredBankSepaSent = true);
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          behavior: SnackBarBehavior.floating,
                          backgroundColor: const Color(0xFF2A2A2A),
                          content: Text(
                            'Бүртгэгдлээ. EUR манай дансанд орсон эсэхийг оператор Revolut-оор шалгана. Tracking дээр явцыг дагана уу.',
                            style: GoogleFonts.notoSans(fontSize: 13, height: 1.35),
                          ),
                        ));
                      },
                      icon: const Icon(Icons.account_balance_rounded,
                          color: kYellow, size: 20),
                      label: Text(
                        'Би банкны аппаар EUR шилжүүлж дууслаа',
                        style: GoogleFonts.notoSans(
                            color: kYellow,
                            fontWeight: FontWeight.w700,
                            fontSize: 13),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: kYellow,
                        side: const BorderSide(color: kYellow),
                        padding: const EdgeInsets.symmetric(
                            vertical: 14, horizontal: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  )
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.check_circle_rounded,
                          color: kGreen, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Банкны аппаар шилжүүлж дууссанаа мэдэгдлээ. Дараа нь reference зөв эсэхийг шалгаад «Баталгаажуулаад үргэлжлүүлэх» дарна уу.',
                          style: GoogleFonts.notoSans(
                              color: Colors.white70,
                              fontSize: 12,
                              height: 1.4),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text('Түргэн нээх',
              style: GoogleFonts.notoSans(
                  color: Colors.white38,
                  fontSize: 11,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in _euMethods)
                if (p.url.isNotEmpty)
                  ActionChip(
                    backgroundColor: const Color(0xFF1C1C1C),
                    side: BorderSide(color: p.color.withOpacity(0.45)),
                    label: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          payMethodBrandAvatar(p, size: 18),
                          const SizedBox(width: 6),
                          Text(p.name,
                              style: GoogleFonts.notoSans(fontSize: 12)),
                        ],
                      ),
                    ),
                    onPressed: () => _openPay(p),
                  ),
            ],
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _code,
            onChanged: (_) => setState(() {}),
            style: GoogleFonts.robotoMono(color: Colors.white, fontSize: 15),
            decoration: InputDecoration(
              labelText: 'Reference баталгаа (давтаж оруулна уу)',
              labelStyle: GoogleFonts.notoSans(color: Colors.white38),
              filled: true,
              fillColor: const Color(0xFF111111),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: kBorder)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: kYellow, width: 1.4)),
            ),
          ),
          if (_code.text.isNotEmpty && !_codesMatch)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Код тохирохгүй байна. Шилжүүлэг дээр оруулсан reference-тэй яг ижил байна уу шалгана уу.',
                style: GoogleFonts.notoSans(color: kRed, fontSize: 12, height: 1.35),
              ),
            ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _confirmedDeposit,
            onChanged: (v) => setState(() => _confirmedDeposit = v ?? false),
            activeColor: kYellow,
            title: Text(
              'Би дээрх дүнгээр EUR дансанд шилжүүлээд, тайлбарт энэ reference оруулсан.',
              style:
                  GoogleFonts.notoSans(color: Colors.white70, fontSize: 12, height: 1.35),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: (_confirmedDeposit && _codesMatch)
                  ? () => Navigator.pop(
                        context,
                        EuDepositSheetResult(
                          confirmed: true,
                          userDeclaredBankSepaSent: _declaredBankSepaSent,
                        ),
                      )
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: kYellow,
                foregroundColor: Colors.black,
                disabledBackgroundColor: Colors.white12,
                disabledForegroundColor: Colors.white24,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                elevation: 0,
                textStyle: GoogleFonts.notoSans(
                    fontWeight: FontWeight.w800, fontSize: 16),
              ),
              child: const Text('Баталгаажуулаад үргэлжлүүлэх'),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── SEND ────────────────────────────────────────────────────────
class SendScreen extends StatefulWidget {
  final void Function(TxRecord) onTxAdded;
  final TxRecord? prefill;
  final VoidCallback? onPrefillConsumed;
  /// MN→EU гар/Голомт: «₮ - Шилжсэн. Хүсэлт илгээх.» дарсны дараа нүүр + Tracking нээх.
  final void Function(TxRecord tx)? onAfterMnDomesticDeclaredGoHomeTrack;
  const SendScreen({
    super.key,
    required this.onTxAdded,
    this.prefill,
    this.onPrefillConsumed,
    this.onAfterMnDomesticDeclaredGoHomeTrack,
  });
  @override State<SendScreen> createState()=>_SendState();
}
class _SendState extends State<SendScreen> {
  String _dir='eu_to_mn', _cur='EUR', _payId='google_pay';
  final _aC=TextEditingController(), _dC=TextEditingController(), _nC=TextEditingController();
  bool _sent=false, _aml=false, _saveAcc=false, _threeInstall=false, _showBankInfo=false;
  /// Илгээсний дараах дэлгэцэнд холбогдсон гүйлгээ (админ баталгаа хүлээгдэж буй эсэхийг шалгана).
  TxRecord? _successLinkedTx;
  String? _amlSource; // сонгосон эх үүсвэр
  bool _reverseMode=false; // true = MNT оруулахад EUR бодно
  final _refC = TextEditingController(); // гүйлгээний утга
  /// Төлбөрийн самбар нээх үед үүсгэсэн reference — гар шилжүүлэг дэлгэц болон SEPA самбарт ижил код ашиглана.
  String? _euPaySheetReference;
  bool _lookingUpName=false;
  bool _accountFound=false;
  String? _lookedUpName;
  String? _lookupError;
  SavedAccount? _selectedSaved;
  final _euCurs=['EUR','CZK','SEK','CHF','GBP'];
  static const _curFlags={'EUR':'🇪🇺','CZK':'🇨🇿','SEK':'🇸🇪','CHF':'🇨🇭','GBP':'🇬🇧'};

  List<PayMethod> get _methods=>_dir=='eu_to_mn'?_euMethods:_mnMethods;
  PayMethod get _pay=>_methods.firstWhere((p)=>p.id==_payId,orElse:()=>_methods.first);
  /// Монгол → Европ: ₮ эхлээд манай Хаан дансанд (гар шилжүүлэх, Голомт).
  bool get _mnToEuDomesticDeposit =>
      _dir == 'mn_to_eu' && (_payId == 'mn_manuel' || _payId == 'golomt');
  double get _inputAmt => double.tryParse(_aC.text.replaceAll(',',''))??0;
  double get _rate => _dir=='eu_to_mn'?(RateService.buyRates[_cur]??4120):(RateService.sellRates['EUR']??4224);
  double get _refFee => (_dir=='eu_to_mn' && _refC.text.trim().isNotEmpty) ? 2.0 : 0.0;

  // ── Тооцооллын тайлбар ────────────────────────────────────────────
  // eu_to_mn normal : input=EUR → conv=MNT, fee on EUR
  // eu_to_mn reverse: input=MNT → conv=MNT(same), total=EUR+fee
  // mn_to_eu normal : input=MNT → conv=EUR, fee on EUR
  // mn_to_eu reverse: input=EUR (авах) → total=MNT, fee on EUR

  double get _amt {
    if (_dir=='eu_to_mn' && _reverseMode) {
      return _inputAmt / _rate; // MNT→EUR base
    }
    return _inputAmt;
  }

  double get _fee {
    if (_dir=='eu_to_mn') return calcFee(_amt) + _refFee;
    if (_reverseMode)     return calcFee(_inputAmt) + _refFee; // fee on desired EUR
    return calcFee(_amt / _rate) + _refFee;                    // fee on EUR equiv
  }

  double get _total {
    if (_dir=='mn_to_eu' && _reverseMode) {
      // MNT шаардлагатай = (EUR авах + fee) * ханш
      return (_inputAmt + calcFee(_inputAmt) + _refFee) * _rate;
    }
    if (_dir=='mn_to_eu') {
      // Хэвийн: MNT оруулсан — fee нь EUR-д тооцогдоно, MNT-д шилжүүлнэ
      return _amt + _fee * _rate; // MNT total
    }
    return _amt + _fee; // eu_to_mn: EUR total
  }

  double get _conv {
    if (_dir=='eu_to_mn') return _reverseMode ? _inputAmt : _amt * _rate;
    if (_reverseMode)     return _inputAmt;           // EUR авах тоо
    return _amt / _rate;                              // EUR normal
  }

  String get _fromUnit {
    if (_dir=='eu_to_mn') return _reverseMode ? 'MNT' : _cur;
    return _reverseMode ? 'EUR' : 'MNT';
  }

  String get _inputLabel {
    if (_dir=='eu_to_mn') return _reverseMode ? 'Хэдэн ₮ хүлээн авах вэ?' : 'Хэдэн $_cur шилжүүлэх вэ?';
    return _reverseMode ? 'Хэдэн EUR хүлээн авах вэ?' : 'Хэдэн ₮ шилжүүлэх вэ?';
  }

  String _fmtConv() {
    if (_dir=='eu_to_mn') {
      return '₮ ${fmtMnt(_reverseMode ? _inputAmt.round() : _conv.round())}';
    }
    return '€ ${(_reverseMode ? _inputAmt : _conv).toStringAsFixed(2)}';
  }

  String _fmtTotal() {
    if (_dir=='eu_to_mn') {
      return '$_sym ${_total.toStringAsFixed(2)} $_cur';
    }
    return '₮ ${fmtMnt(_total.round())}';
  }

  List<double> get _quick {
    if (_dir=='eu_to_mn') return _reverseMode ? _quickMNT : _quickEUR;
    return _reverseMode ? _quickEUR : _quickMNT;
  }

  // ── Валютын тэмдэг ──────────────────────────────────────────────
  String get _sym {
    switch (_cur) {
      case 'CZK': return 'Kč';
      case 'SEK': return 'kr';
      case 'CHF': return 'Fr';
      case 'GBP': return '£';
      default:    return '€';
    }
  }

  /// Европ → Монгол шилжүүлэг зөвхөн баталгаажсан гишүүнд.
  bool get _euToMnNeedsVerification => _dir == 'eu_to_mn' && !VerifyStore.isVerified;

  List<SavedAccount> get _savedAccounts {
    final all = AccountStore.accounts;
    if (_dir == 'eu_to_mn') {
      // Зөвхөн монголын 18 оронтой тоон данс — IBAN харуулахгүй.
      return all.where((a) => savedAccountIsMongolianLocalSlot(a.accountNo)).toList();
    }
    // MN → EU: зөвхөн гадаад IBAN хэлбэртэй хадгаламж — монгол данс бүү харуул.
    return all.where((a) => savedAccountIsEuIbanSlot(a.accountNo)).toList();
  }

  void _setAmt(double v){_aC.text=v.toStringAsFixed(0);setState((){_lookedUpName=null;_lookupError=null;_accountFound=false;});}
  void _switchDir(String d){setState((){_dir=d;_payId=_methods.first.id;_threeInstall=false;_cur='EUR';_aC.clear();_selectedSaved=null;_dC.clear();_refC.clear();_lookedUpName=null;_lookupError=null;_accountFound=false;_showBankInfo=false;_reverseMode=false;});}
  void _selectSaved(SavedAccount acc){setState((){_selectedSaved=acc;_dC.text=acc.accountNo;_nC.text=acc.name;_lookedUpName=acc.name;_lookupError=null;_accountFound=true;});}

  Future<void> _promptRemoveSaved(SavedAccount acc) async {
    final name = acc.name.isNotEmpty ? acc.name : acc.bank;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Данс устгах уу?',
            style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 18)),
        content: Text(
          '«$name» (${savedAccountDisplayNo(acc.accountNo)}) таны хадгалсан жагсаалтаас хасагдана.',
          style: GoogleFonts.notoSans(color: Colors.white70, fontSize: 14, height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Болих', style: GoogleFonts.notoSans(color: Colors.white54, fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Устгах', style: GoogleFonts.notoSans(color: kRed, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await AccountStore.remove(acc.accountNo);
    if (!mounted) return;
    final sel = _selectedSaved;
    if (sel != null &&
        (_dir == 'eu_to_mn'
            ? mnAccountDigits(sel.accountNo) == mnAccountDigits(acc.accountNo)
            : _normalizeIban(sel.accountNo) == _normalizeIban(acc.accountNo))) {
      setState(() => _selectedSaved = null);
    } else {
      setState(() {});
    }
  }

  /// Талбарт өөр данс бичихэд хадгалсан картны сонгогдсон төлөвийг тасална.
  void _clearSelectedSavedIfAccountNoMismatch() {
    final sel = _selectedSaved;
    if (sel == null) return;
    if (_dir == 'eu_to_mn') {
      if (mnAccountDigits(_dC.text) != mnAccountDigits(sel.accountNo)) {
        _selectedSaved = null;
      }
    } else {
      if (_normalizeIban(_dC.text) != _normalizeIban(sel.accountNo)) {
        _selectedSaved = null;
      }
    }
  }

  bool _savedChipSelected(SavedAccount acc) {
    final sel = _selectedSaved;
    if (sel == null) return false;
    if (_dir == 'eu_to_mn') {
      return mnAccountDigits(sel.accountNo) == mnAccountDigits(acc.accountNo);
    }
    return _normalizeIban(sel.accountNo) == _normalizeIban(acc.accountNo);
  }

  // ─── Хаан Банк API тохиргоо ──────────────────────────────────────
  // developer.khanbank.com дээр бүртгүүлж авна
  static const _kbConsumerKey    = 'YOUR_CONSUMER_KEY';
  static const _kbConsumerSecret = 'YOUR_CONSUMER_SECRET';
  static const _kbBaseUrl        = 'https://api.khanbank.com/v1';

  Future<String?> _kbGetToken() async {
    try {
      final credentials = base64Encode(
          utf8.encode('$_kbConsumerKey:$_kbConsumerSecret'));
      final res = await http.post(
        Uri.parse('$_kbBaseUrl/token'),
        headers: {
          'Authorization': 'Basic $credentials',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: 'grant_type=client_credentials',
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        return data['access_token'] as String?;
      }
    } catch (e) {
      debugPrint('KhanBank token error: $e');
    }
    return null;
  }

  Future<void> _lookupAccountName() async {
    final acc = mnAccountDigits(_dC.text);
    if (!RegExp(r'^\d{18}$').hasMatch(acc)) return;

    setState((){_lookingUpName=true;_lookedUpName=null;_lookupError=null;_accountFound=false;});

    // API credential тохируулаагүй үед
    if (_kbConsumerKey == 'YOUR_CONSUMER_KEY') {
      await Future.delayed(const Duration(milliseconds: 400));
      if (mounted) setState((){_lookingUpName=false;});
      return;
    }

    try {
      final token = await _kbGetToken();
      if (token == null) {
        if (mounted) setState((){_lookingUpName=false;_lookupError='Токен авахад алдаа гарлаа';});
        return;
      }
      final res = await http.get(
        Uri.parse('$_kbBaseUrl/accounts/$acc/info'),
        headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));

      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        // Хаан Банкны API-с нэр ирэх талбар (баталгаажсаны дараа тохируулна)
        final name = data['accountName'] ?? data['name'] ?? data['customerName'] ?? '';
        setState((){
          _lookingUpName=false;
          _accountFound=true;
          _lookedUpName=name.toString().isNotEmpty ? name.toString() : null;
          if (_lookedUpName != null) _nC.text = _lookedUpName!;
        });
      } else if (res.statusCode == 404) {
        setState((){_lookingUpName=false;_lookupError='Данс олдсонгүй';});
      } else {
        setState((){_lookingUpName=false;_lookupError='Алдаа гарлаа (${res.statusCode})';});
      }
    } catch (e) {
      if (mounted) setState((){_lookingUpName=false;_lookupError='Сүлжээний алдаа';});
      debugPrint('KhanBank lookup error: $e');
    }
  }

  Future<void> _launch() async {
    if (_payId == 'stripe_wallet' ||
        _payId == 'google_pay' ||
        _payId == 'apple_pay' ||
        _payId == 'klarna') return;
    if (_mnToEuDomesticDeposit) return;
    final url=_pay.url;
    if(url.isEmpty) return;
    Uri uri=_payId=='paypal'?Uri.parse('$url/${_total.toStringAsFixed(2)}EUR'):Uri.parse(url);
    if(await canLaunchUrl(uri)) await launchUrl(uri,mode:LaunchMode.externalApplication);
  }

  String _generateMoneySentReference() {
    final t = DateTime.now().millisecondsSinceEpoch;
    final r = Random().nextInt(900000) + 100000;
    return 'MS-${t % 100000000}-$r';
  }

  /// Хаан дансанд ₮ орлого — EUR IBAN-тай холбогдох reference. Бүртгэх/задлахад хялбар биш, зөвхөн системд.
  /// 11 тэмдэгт (0,O,1,I-г хассан — шилжүүлэг оруулахад төвөггүй).
  String _generateKhanDepositReference() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    return String.fromCharCodes(
      Iterable.generate(
        11,
        (_) => alphabet.codeUnitAt(rnd.nextInt(alphabet.length)),
      ),
    );
  }

  String? _validateForOutboundMn() {
    if (_amt <= 0) return 'Дүн оруулна уу';
    if (!_aml || _amlSource == null) return 'Мөнгөний эх үүсвэр сонгоно уу';
    if (_nC.text.trim().isEmpty) return 'Хүлээн авагчийн овог нэрийг оруулна уу';
    final acc = mnAccountDigits(_dC.text);
    if (!RegExp(r'^\d{18}$').hasMatch(acc)) {
      return 'Монгол дансны дугаар 18 оронтой байна';
    }
    return null;
  }

  /// Монгол → Европ: самбар нээхээс өмнө — төлбөрийн аргыг сонгоогүй тул IBAN энд шалгахгүй.
  String? _validateForOutboundEu() {
    if (_amt <= 0) return 'Дүн оруулна уу';
    if (!_aml || _amlSource == null) return 'Мөнгөний эх үүсвэр сонгоно уу';
    if (_nC.text.trim().isEmpty) return 'Хүлээн авагчийн овог нэрийг оруулна уу';
    if (recipientNameHasNonLatinScript(_nC.text.trim())) {
      return 'Овог нэрийг латин үсгээр (галлигацаар) бичнэ үү — монгол кирилл биш';
    }
    return null;
  }

  Future<void> _completeEuToMnWithReference(
    String referenceCode, {
    bool userDeclaredBankSepaSent = false,
  }) async {
    if (_dir != 'eu_to_mn' || !VerifyStore.isVerified) return;
    if (_saveAcc && _dC.text.isNotEmpty) {
      await AccountStore.save(SavedAccount(
          bank: 'reference_sepa', accountNo: _dC.text, name: _nC.text));
    }
    final tx = TxRecord(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      date: DateFormat('yyyy-MM-dd').format(DateTime.now()),
      from: 'Европ',
      to: 'Хаан Банк',
      currency: _cur,
      amount: _amt,
      fee: _fee,
      mnt: _conv.round(),
      dir: _dir,
      payId: 'reference_sepa',
      accountNo: _dC.text,
      destName: _nC.text,
      referenceCode: referenceCode,
      reverseMode: _reverseMode,
      destAccount: _dC.text.isNotEmpty
          ? SavedAccount(
              bank: 'reference_sepa', accountNo: _dC.text, name: _nC.text)
          : null,
      userDeclaredBankSepaSent: userDeclaredBankSepaSent,
    );
    widget.onTxAdded(tx);
    _successLinkedTx = tx;
    setState(() => _sent = true);
  }

  /// EUR reference / SEPA самбар нээж баталгаажуулвал гүйлгээг бүртгэнэ (Stripe ашиглахгүй).
  Future<void> _presentEuDepositReferenceFlow() async {
    final ref = _euPaySheetReference ?? _generateMoneySentReference();
    if (!mounted) return;
    final result = await Navigator.push<EuDepositSheetResult>(
      context,
      MaterialPageRoute(
        builder: (_) => EuDepositReferenceSheetScreen(
          referenceCode: ref,
          expectedAmountDisplay:
              '${_sym} ${_total.toStringAsFixed(2)} $_cur',
          paypalAmountSegment: '${_total.toStringAsFixed(2)} EUR',
          mntReceiveDisplay: '₮ ${fmtMnt(_conv.round())}',
          recipientName: _nC.text.trim(),
          mnAccountDisplay: _dC.text.trim(),
        ),
      ),
    );
    if (result == null || !result.confirmed) return;
    await _completeEuToMnWithReference(
      ref,
      userDeclaredBankSepaSent: result.userDeclaredBankSepaSent,
    );
  }

  Future<void> _handleSendTap() async {
    if (_dir == 'eu_to_mn' && !VerifyStore.isVerified) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: kRed,
        content: Text(
          'Монгол руу шилжүүлэхийн өмнө баталгаажуулалт шаардлагатай. Доорх картнаас «Баталгаажуулалт» руу орно уу.',
          style: GoogleFonts.notoSans(fontSize: 13, height: 1.35),
        ),
      ));
      return;
    }
    // Шилжүүлгийн өгөгдөл шалгах → дараа нь төлбөрийн самбарт бүх аргууд.
    if (_dir == 'eu_to_mn') {
      final err = _validateForOutboundMn();
      if (err != null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: kRed,
          content: Text(err, style: GoogleFonts.notoSans(fontSize: 13)),
        ));
        return;
      }
    }
    if (_dir == 'mn_to_eu') {
      final err = _validateForOutboundEu();
      if (err != null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: kRed,
          content: Text(err, style: GoogleFonts.notoSans(fontSize: 13)),
        ));
        return;
      }
    }
    _showPaySheet();
  }

  /// Төлбөрийн самбар хаагдсаны дараа: зээлийн горим бол шалгалт + гэрээ, эцэст нь төлбөр (`_submit`).
  Future<void> _continuePaymentAfterPaySheet({
    bool mntDeclaredFromManual = false,
  }) async {
    if (_threeInstall) {
      if (LoanStore.hasOpenLoan) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF2A2A2A),
          content: Text(
            'Өмнөх зээл бүрэн төлөгдөөгүй байна. Профайл → «Зээлийн эрхтэй гишүүн» дээр дарж үлдэгдлээ харна уу.',
            style: GoogleFonts.notoSans(color: Colors.white, fontSize: 13, height: 1.35),
          ),
        ));
        return;
      }
      if (_installBase > LoanStore.maxLoanPrincipalEur + 1e-9) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            'Зээлээр шилжүүлэх үндсэн дүн одоогоор хамгийн ихдээ ${LoanStore.maxLoanPrincipalEur.toStringAsFixed(0)} EUR.',
            style: GoogleFonts.notoSans(color: Colors.white),
          ),
        ));
        return;
      }
      if (!LoanStore.isApproved) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => LoanCornerScreen(
              initialAmt: _installGrandTotal.toStringAsFixed(2),
            ),
          ),
        );
        if (mounted) setState(() {});
        return;
      }
      final sym = _dir == 'eu_to_mn' ? _sym : '€';
      final cur = _dir == 'eu_to_mn' ? _cur : 'EUR';
      final signed = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => LoanContractScreen(
            name: UserStore.name,
            email: UserStore.email,
            amtEur: _installBase.toStringAsFixed(2),
            installAmt: '${sym}${_installPrincipalPerPart.toStringAsFixed(2)} $cur',
            loanPerPart: '${sym}${_installLoanPerPart.toStringAsFixed(2)} $cur',
            grandTotal: _installGrandTotal.toStringAsFixed(2),
            interestPortionEur: _loanInterestPortionEur.toStringAsFixed(2),
            date1: _installDate(0),
            date2: _installDate(1),
            date3: _installDate(2),
          ),
        ),
      );
      if (signed != true) return;
    }
    await _submit(mntDeclaredFromManual: mntDeclaredFromManual);
  }

  void _showPaySheet() {
    setState(() {
      if (_dir == 'mn_to_eu' && (_payId == 'mn_manuel' || _payId == 'golomt')) {
        _euPaySheetReference = _generateKhanDepositReference();
      } else {
        _euPaySheetReference = _generateMoneySentReference();
      }
    });
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(builder: (ctx, setS) {
        PayMethod curPay = _methods.firstWhere((p)=>p.id==_payId, orElse:()=>_methods.first);
        final bottomInset = MediaQuery.viewInsetsOf(ctx).bottom;
        final maxH = MediaQuery.sizeOf(ctx).height * 0.92;
        return Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: SizedBox(
            height: maxH,
            child: Container(
              decoration: const BoxDecoration(
                color: Color(0xFF1C1C1C),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(_dir=='eu_to_mn'?'Европоос хэрхэн илгээх?':'Монголоос хэрхэн илгээх?',
                      style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(
                      '${_fmtTotal()}  ·  ${_fmtConv()}',
                      style: GoogleFonts.notoSans(color: kYellow, fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 16),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _lbl('Төлбөрийн арга'),
                          const SizedBox(height: 8),
                          ..._methods.map((p) => GestureDetector(
                            onTap: () {
                              if (p.id == 'loan_install' && LoanStore.hasOpenLoan) {
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                  behavior: SnackBarBehavior.floating,
                                  content: Text(
                                    'Идэвхтэй зээл байна. Бүрэн төлж дуусгасны дараа дахин «Зээлээр шилжүүлэх» сонгоно.',
                                    style: GoogleFonts.notoSans(fontSize: 13),
                                  ),
                                ));
                                return;
                              }
                              setS(() => curPay = p);
                              setState(() {
                                _payId = p.id;
                                _threeInstall = (p.id == 'loan_install');
                                if (_dir == 'mn_to_eu' &&
                                    (_payId == 'mn_manuel' || _payId == 'golomt')) {
                                  _euPaySheetReference = _generateKhanDepositReference();
                                } else if (_dir == 'eu_to_mn') {
                                  _euPaySheetReference = _generateMoneySentReference();
                                }
                              });
                            },
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: curPay.id==p.id ? p.color.withOpacity(0.13) : const Color(0xFF111111),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: curPay.id==p.id ? p.color : const Color(0xFF2A2A2A),
                                    width: curPay.id==p.id ? 1.8 : 1)),
                              child: Row(children: [
                                SizedBox(
                                  width: 32,
                                  height: 32,
                                  child: Center(
                                    child: payMethodBrandAvatar(p, size: 30),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(p.name, style: GoogleFonts.notoSans(
                                      color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
                                  Text(_paySub(p), style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11)),
                                ])),
                                if (curPay.id==p.id)
                                  Container(width: 22, height: 22,
                                      decoration: BoxDecoration(color: p.color, shape: BoxShape.circle),
                                      child: const Icon(Icons.check_rounded, color: Colors.white, size: 14))
                                else
                                  const Icon(Icons.arrow_forward_ios_rounded, color: Color(0xFF444444), size: 13),
                              ]),
                            ),
                          )),
                          if (curPay.id == 'loan_install') ...[
                            const SizedBox(height: 4),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: kYellow.withOpacity(0.06),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: kYellow.withOpacity(0.22)),
                              ),
                              child: Text(
                                'Зээлээр шилжүүлэг нэг идэвхтэй үүрэг дээр нэг л удаа ашиглана; өмнөхийг бүрэн төлөөгүй бол дахин боломжгүй. '
                                'Одоогоор шилжүүлэх үндсэн дүн хамгийн ихдээ ${LoanStore.maxLoanPrincipalEur.toStringAsFixed(0)} EUR.',
                                style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 11.5, height: 1.45),
                              ),
                            ),
                            const SizedBox(height: 12),
                            GestureDetector(
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => LoanCornerScreen(
                                    initialAmt: _amt > 0 ? _installGrandTotal.toStringAsFixed(2) : '',
                                  ),
                                ),
                              ),
                              child: Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(colors: [kYellow.withOpacity(0.12), kYellow.withOpacity(0.04)]),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: kYellow.withOpacity(0.45)),
                                ),
                                child: Row(children: [
                                  Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(color: kYellow.withOpacity(0.18), borderRadius: BorderRadius.circular(10)),
                                    child: const Icon(Icons.savings_rounded, color: kYellow, size: 20),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Зээлийн булан',
                                          style: GoogleFonts.notoSans(color: kYellow, fontWeight: FontWeight.w800, fontSize: 13),
                                        ),
                                        Text(
                                          '3 хэсэгт хуваан зээлийн нөхцөлөөр шилжүүлэх хүсэлт',
                                          style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 11),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Icon(Icons.arrow_forward_ios_rounded, color: kYellow, size: 14),
                                ]),
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                          if ((curPay.id == 'manuel' || curPay.id == 'eu_transfer_reference') && _dir == 'eu_to_mn') ...[
                            const SizedBox(height: 6),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0A1825),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: const Color(0xFF00B9FF).withOpacity(0.35)),
                              ),
                              child: Text(
                                '«Гүйлгээ хийх» дарвал шинэ дэлгэцэнд IBAN, дүн, утга (reference) бүхий шилжүүлэх мэдээлэл гарна.',
                                style: GoogleFonts.notoSans(color: Colors.white60, fontSize: 12, height: 1.45),
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                          if ((curPay.id == 'mn_manuel' || curPay.id == 'golomt') &&
                              _dir == 'mn_to_eu') ...[
                            const SizedBox(height: 6),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0A2518),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: const Color(0xFF00C853).withOpacity(0.35)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Яаж ажиллах вэ?',
                                    style: GoogleFonts.notoSans(
                                      color: const Color(0xFF81C784),
                                      fontWeight: FontWeight.w800,
                                      fontSize: 12.5,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '• Европын IBAN талбарыг заавал бөглөх шаардлагагүй (хүсвэл өмнө нь оруулж болно).\n'
                                    '• Эхлээд ₮-өө банкны аппаараа манай Хаан банкны дансанд шилжүүлнэ — захиалга бүртгэгдэж, админд мэдэгдэнэ.\n'
                                    '• Монгол төгрөг манай дансанд орж ирсэн эсэх, мөн Европын IBAN-ыг манай оператор шалгаж гүйлгээ баталгаажуулсны дараа танд мэдэгдэл ирнэ; гүйлгээний Tracking хэсэгт «Амжилттай хүргэгдлээ» гэсэн төлөв харагдана.\n'
                                    '• Шилжүүлгээ хийсний дараа апп дээр «₮ - Шилжсэн. Хүсэлт илгээх.» гэж дарж болно.',
                                    style: GoogleFonts.notoSans(
                                      color: Colors.white.withOpacity(0.88),
                                      fontSize: 12,
                                      height: 1.48,
                                    ),
                                  ),
                                  if (curPay.id == 'golomt') ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      'Голомт горим: дараагийн дэлгэц нээгдэхэд зөвхөн Хаан банкны IBAN автоматаар хуулна; дүн, Reference-ийг картнаас оруулна.',
                                      style: GoogleFonts.notoSans(
                                        color: const Color(0xFFFFCDD2),
                                        fontSize: 11.5,
                                        height: 1.42,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 10),
                                    child: Divider(color: Colors.white.withOpacity(0.08), height: 1),
                                  ),
                                  Text(
                                    '«Гүйлгээ хийх» дарна уу',
                                    style: GoogleFonts.notoSans(
                                      color: Colors.white.withOpacity(0.55),
                                      fontWeight: FontWeight.w700,
                                      fontSize: 11,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    curPay.id == 'golomt'
                                        ? 'Дараагийн дэлгэц нээгдэхэд Хаан банкны IBAN автоматаар хуулна; дүн, Reference-ийг картнаас Голомт аппдаа оруулна.'
                                        : 'Дараагийн дэлгэцэд данс, дүн, Reference нэг дор харагдана — банкныхаа аппад яг ижилхэн оруулна.',
                                    style: GoogleFonts.notoSans(
                                      color: Colors.white.withOpacity(0.62),
                                      fontSize: 11.5,
                                      height: 1.42,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () async {
                        final manualEu = _dir == 'eu_to_mn' &&
                            (_payId == 'manuel' || _payId == 'eu_transfer_reference');
                        final mnManual = _dir == 'mn_to_eu' &&
                            (_payId == 'mn_manuel' || _payId == 'golomt');
                        var mntDeclaredFromManual = false;
                        final ref = _euPaySheetReference ??
                            (mnManual
                                ? _generateKhanDepositReference()
                                : _generateMoneySentReference());
                        final summary = '${_fmtTotal()} · ${_fmtConv()}';
                        final expectedAmt =
                            '${_sym} ${_total.toStringAsFixed(2)} $_cur';
                        Navigator.pop(ctx);
                        if (_payId == 'golomt' &&
                            _dir == 'mn_to_eu' &&
                            mnManual &&
                            mounted) {
                          await launchGolomtBankMobileApp();
                        }
                        if (manualEu && mounted) {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ManualBankTransferInfoScreen(
                                referenceCode: ref,
                                summaryLine: summary,
                                expectedAmountDisplay: expectedAmt,
                              ),
                            ),
                          );
                        }
                        if (mnManual && mounted) {
                          final declared = await Navigator.push<bool>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => MnDomesticManualTransferScreen(
                                mntPayDisplay:
                                    '₮ ${fmtMnt(_total.round())}',
                                mntAmountPlain: '${_total.round()}',
                                depositReference: ref,
                                eurRecvSummary: _fmtConv(),
                                golomtAppGuidance: _payId == 'golomt',
                              ),
                            ),
                          );
                          mntDeclaredFromManual = declared == true;
                        }
                        if (!mounted) return;
                        await _continuePaymentAfterPaySheet(
                          mntDeclaredFromManual: mntDeclaredFromManual,
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kYellow, foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        elevation: 0,
                        textStyle: GoogleFonts.notoSans(fontWeight: FontWeight.w800, fontSize: 16),
                      ),
                      child: Text(
                        (_dir == 'mn_to_eu' && _payId == 'golomt')
                            ? 'Голомтын апп нээх · үргэлжлүүлэх'
                            : 'Гүйлгээ хийх',
                        style: GoogleFonts.notoSans(fontWeight: FontWeight.w800, fontSize: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }

  Future<void> _submit({bool mntDeclaredFromManual = false}) async {
    if (_dir == 'eu_to_mn' && !VerifyStore.isVerified) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: kRed,
        content: Text('Монгол руу шилжүүлэхэд баталгаажсан гишүүн байх ёстой.', style: GoogleFonts.notoSans()),
      ));
      return;
    }
    // Овог нэр заавал
    if (_nC.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor:kRed,
          content:Text('Хүлээн авагчийн овог нэрийг оруулна уу', style:GoogleFonts.notoSans())));
      return;
    }
    if (_dir == 'mn_to_eu' && recipientNameHasNonLatinScript(_nC.text.trim())) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: kRed,
        content: Text(
          'Овог нэрийг латин үсгээр (галлигацаар) бичнэ үү — монгол кирилл / монгол бичиг хүлээгдэхгүй.',
          style: GoogleFonts.notoSans(fontSize: 13, height: 1.35),
        ),
      ));
      return;
    }
    // IBAN зөвхөн «Гараар / Голомт ₮ данс» урсгал биш бусад MN→EU аргуудад шаардлагатай.
    if (_dir == 'mn_to_eu' && !_mnToEuDomesticDeposit) {
      final iban = _dC.text.trim();
      if (iban.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            backgroundColor: kRed,
            content: Text('Хүлээн авах IBAN оруулна уу', style: GoogleFonts.notoSans())));
        return;
      }
      if (!looksLikeIban(iban)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor:kRed,
            content:Text('IBAN буруу формат (жишээ: DE89…, FR76…)', style:GoogleFonts.notoSans())));
        return;
      }
      if (!isValidIban(iban)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor:kRed,
            content:Text('IBAN checksum буруу. Дахин шалгана уу.', style:GoogleFonts.notoSans())));
        return;
      }
    }
    // Гар/Голомт ₮ урсгал: EUR IBAN заавал биш; оруулсан бол админд хадгалж checksum шалгана.
    if (_dir == 'mn_to_eu' && _mnToEuDomesticDeposit) {
      final iban = _dC.text.trim();
      if (iban.isNotEmpty) {
        if (!looksLikeIban(iban)) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            backgroundColor: kRed,
            content: Text(
              'Хүлээн авах IBAN буруу формат (жишээ: DE89…). Хоосон үлдээгээд чатаар дамжуулж болно.',
              style: GoogleFonts.notoSans(fontSize: 12.5, height: 1.35),
            ),
          ));
          return;
        }
        if (!isValidIban(iban)) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            backgroundColor: kRed,
            content: Text(
              'IBAN checksum буруу. Дахин шалгана уу эсвэл талбарыг хоосон орхино.',
              style: GoogleFonts.notoSans(fontSize: 12.5, height: 1.35),
            ),
          ));
          return;
        }
      }
    }

    final pm = _pay;
    // SEPA болон гар аргаар шилжүүлэг: reference самбар → EUR дансанд шилжүүлэх заавар.
    if ((pm.id == 'sepa' || pm.id == 'manuel' || pm.id == 'eu_transfer_reference') && _dir == 'eu_to_mn') {
      await _presentEuDepositReferenceFlow();
      return;
    }
    if (pm.id == 'stripe_wallet' ||
        pm.id == 'google_pay' ||
        pm.id == 'apple_pay' ||
        pm.id == 'klarna') {
      if (kStripePublishableKey.trim().isEmpty ||
          kStripePaymentIntentUrl.trim().isEmpty) {
        await _presentEuDepositReferenceFlow();
        return;
      }
      if (mounted &&
          kStripePublishableKey.startsWith('pk_test') &&
          defaultTargetPlatform == TargetPlatform.android) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
          backgroundColor: const Color(0xFF2A2A2A),
          content: Text(
            'pk_test горим: Google Pay ихэвчлэн зөвхөн Stripe-ийн тестийн картлаар. Жинхэнэ картлаар pk_live.',
            style: GoogleFonts.notoSans(fontSize: 11.5, height: 1.35),
          ),
        ));
      }
      final meta = <String, String>{
        'dir': _dir,
        'pay_id': _payId,
        'mn_account': mnAccountDigits(_dC.text),
        'recipient_name': _nC.text.trim(),
        'mnt_receive': '${_conv.round()}',
        'currency_send': _cur,
        'amount_send': _amt.toStringAsFixed(2),
        'fee': _fee.toStringAsFixed(2),
        'total_charge': _total.toStringAsFixed(2),
        if (_refC.text.trim().isNotEmpty) 'note': _refC.text.trim(),
      };
      final outcome = await presentRemittanceStripePaymentSheet(
        amountMajor: _total,
        currencyLower: _cur.toLowerCase(),
        customerEmail: UserStore.email,
        customerName: UserStore.name,
        metadata: meta,
      );
      switch (outcome) {
        case StripeSheetOutcome.canceled:
          return;
        case StripeSheetOutcome.success:
          break;
        default:
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: kRed,
            content: Text(
              outcome == StripeSheetOutcome.needsWebCheckout
                  ? 'Stripe publishable key байхгүй.'
                  : 'Төлбөр амжилтгүй.\n${stripePaymentIntentLastError ?? 'Сервер / Stripe шалгана уу.'}',
              style: GoogleFonts.notoSans(fontSize: 12.5, height: 1.35),
            ),
          ));
          return;
      }
    }

    if (_saveAcc && _dC.text.isNotEmpty) {
      if (_mnToEuDomesticDeposit) {
        final ib = _dC.text.trim();
        if (looksLikeIban(ib) && isValidIban(ib)) {
          await AccountStore.save(
              SavedAccount(bank: _payId, accountNo: ib, name: _nC.text));
        }
      } else {
        await AccountStore.save(
            SavedAccount(bank: _payId, accountNo: _dC.text, name: _nC.text));
      }
    }
    final destAcctNo = _dC.text.trim();
    final tx=TxRecord(
      id:DateTime.now().millisecondsSinceEpoch.toString(),
      date:DateFormat('yyyy-MM-dd').format(DateTime.now()),
      from:_dir=='eu_to_mn'?'Европ':'Монгол',
      to:_dir=='eu_to_mn'?'Хаан Банк':'Европ',
      currency:_dir=='eu_to_mn'?_cur:'EUR',
      amount:_dir=='eu_to_mn'?_amt:_conv,
      fee:_fee,
      mnt:_dir=='eu_to_mn'?_conv.round():_total.round(),
      dir:_dir, payId:_payId,
      accountNo:destAcctNo, destName:_nC.text,
      referenceCode: _mnToEuDomesticDeposit
          ? (_euPaySheetReference ?? _generateKhanDepositReference())
          : '',
      reverseMode:_reverseMode,
      destAccount:destAcctNo.isNotEmpty
          ? SavedAccount(bank:_payId,accountNo:destAcctNo,name:_nC.text)
          : null,
      userDeclaredMntBankSent:
          _mnToEuDomesticDeposit && mntDeclaredFromManual,
    );
    final goHomeTrack = mntDeclaredFromManual && _mnToEuDomesticDeposit;
    widget.onTxAdded(tx);
    await _launch();
    _successLinkedTx = tx;
    setState(()=>_sent=true);
    if (goHomeTrack) {
      widget.onAfterMnDomesticDeclaredGoHomeTrack?.call(tx);
    }
  }

  void _applyPrefill(TxRecord p) {
    _dir    = txFlowDir(p);
    _payId  = p.payId;
    _cur    = p.currency;
    _reverseMode = false;
    _sent   = false;
    _successLinkedTx = null;
    if (txFlowDir(p) == 'mn_to_eu' && legacyMnToEuMisstored(p)) {
      _aC.text = p.mnt.toString();
    } else if (txFlowDir(p) == 'mn_to_eu') {
      _aC.text = (p.amount % 1 == 0)
          ? p.amount.toStringAsFixed(0)
          : p.amount.toStringAsFixed(2);
    } else {
      _aC.text = p.amount.toStringAsFixed(0);
    }
    _dC.text = p.accountNo;
    _nC.text = p.destName;
    _aml = false; _amlSource = null;
    _selectedSaved = null;
    _threeInstall = (p.payId == 'loan_install');
    if (p.accountNo.isNotEmpty) {
      _lookedUpName = p.destName.isNotEmpty ? p.destName : null;
      _accountFound = true;
    }
    widget.onPrefillConsumed?.call();
  }

  @override void initState(){
    super.initState();
    VerifyStore.load().then((_) { if (mounted) setState(() {}); });
    RateService.fetch().then((_){if(mounted)setState((){});});
    GermanBankLookup.load().then((_) { if (mounted) setState(() {}); });
    if (widget.prefill != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _applyPrefill(widget.prefill!));
      });
    }
  }

  @override void didUpdateWidget(SendScreen old) {
    super.didUpdateWidget(old);
    if (widget.prefill != null && widget.prefill != old.prefill) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _applyPrefill(widget.prefill!));
      });
    }
  }

  @override Widget build(BuildContext context)=>Column(children:[
    const AppHeader(),
    Expanded(child:_sent?_buildSuccess():_buildMain()),
  ]);

  Widget _euToMnVerificationGate() {
    final pending = VerifyStore.isPending;
    final rate = RateService.buyRates['EUR'] ?? 4120.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xFF1877F2).withOpacity(0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF1877F2).withOpacity(0.35)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.verified_user_rounded, color: pending ? Colors.orange : kYellow, size: 28),
              const SizedBox(width: 12),
              Expanded(
                  child: Text('Монгол руу шилжүүлэх',
                      style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16))),
            ]),
            const SizedBox(height: 12),
            Text(
              pending
                  ? 'Баталгаажуулалтын хүсэлт хүлээгдэж байна. Зөвшөөрөгдсөний дараа Европ → Монгол шилжүүлэг идэвхжинэ.'
                  : 'Европоос Монгол руу мөнгө илгээхийн өмнө бүртгэлээ баталгаажуулах шаардлагатай.',
              style: GoogleFonts.notoSans(color: Colors.white60, fontSize: 13, height: 1.45),
            ),
            const SizedBox(height: 14),
            Text('Ойролцоо ханш: 1 EUR ≈ ₮ ${fmtMnt(rate.round())}',
                style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11.5)),
            const SizedBox(height: 18),
            GestureDetector(
              onTap: () async {
                await Navigator.push(
                    context, MaterialPageRoute(builder: (_) => const VerificationScreen()));
                await VerifyStore.load();
                if (mounted) setState(() {});
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 15),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [Color(0xFF1877F2), Color(0xFF4267B2)]),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Center(
                  child: Text(
                    pending ? 'Баталгаажуулалт руу орох' : 'Баталгаажуулалт эхлүүлэх',
                    style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Туршилт: Профайл → Админ самбар → «Баталгаажуулах» эсвэл энд баримт илгээж баталгаажуулна.',
              style: GoogleFonts.notoSans(color: Colors.white24, fontSize: 10.5, height: 1.35),
            ),
          ]),
        ),
        const SizedBox(height: 20),
        Text(
          '💡 Монгол → Европ чиглэлийг сонгож баталгаажуулалтгүй тохируулга хийж болно.',
          style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12, height: 1.4),
        ),
      ],
    );
  }

  Widget _buildMain()=>ListView(padding:const EdgeInsets.all(20),children:[
    Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: _buildDirectionSwitcher(),
    ),

    if (_euToMnNeedsVerification) ...[
      _euToMnVerificationGate(),
    ] else ...[
    if(_dir=='eu_to_mn')...[
      _lbl('Валют'),
      Row(children: _euCurs.map((c) {
        final sel = _cur == c;
        final flag = _curFlags[c] ?? '';
        return Expanded(child: GestureDetector(
          onTap: () => setState(() => _cur = c),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            margin: const EdgeInsets.only(right: 6, bottom: 12),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: sel ? kYellow : kCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: sel ? kYellow : kBorder, width: sel ? 2 : 1),
              boxShadow: sel ? [BoxShadow(color: kYellow.withOpacity(0.35), blurRadius: 10, offset: const Offset(0, 3))] : [],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(flag, style: const TextStyle(fontSize: 22)),
              const SizedBox(height: 4),
              Text(c, style: GoogleFonts.notoSans(
                  color: sel ? Colors.black : Colors.white,
                  fontWeight: FontWeight.w800, fontSize: 12)),
            ]),
          ),
        ));
      }).toList()),
    ],

    // Горим сонгогч (eu_to_mn болон mn_to_eu хоёулаа)
    _reverseModeToggle(),
    const SizedBox(height: 12),
    _lbl(_inputLabel),
    GridView.count(crossAxisCount:3,shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),
        crossAxisSpacing:10,mainAxisSpacing:10,childAspectRatio:1.9,
        children:_quick.map((a){
          final sel=_inputAmt==a;
          String top, sub;
          if (_dir=='eu_to_mn' && _reverseMode) {
            // EU→MN буцаан: MNT авах → cur төлнө
            final base = a / _rate;
            final fee = calcFee(base) + _refFee;
            top = '₮${fmtMnt(a.round())}';
            sub = '≈ $_sym${(base+fee).toStringAsFixed(0)} төлнө';
          } else if (_dir=='eu_to_mn') {
            // EU→MN хэвийн: cur оруулах → MNT авах
            top = '$_sym${a.toStringAsFixed(0)}';
            sub = '₮${fmtMnt((a*_rate).round())}';
          } else if (_reverseMode) {
            // MN→EU буцаан: EUR авах → MNT төлнө
            final mntNeeded = (a + calcFee(a) + _refFee) * _rate;
            top = '€${a.toStringAsFixed(0)}';
            sub = '₮${fmtMnt(mntNeeded.round())} төлнө';
          } else {
            // MN→EU хэвийн: MNT оруулах → EUR авах
            top = '₮${fmtMnt(a.round())}';
            sub = '€${(a/_rate).toStringAsFixed(0)}';
          }
          return GestureDetector(onTap:()=>_setAmt(a),
              child:Container(decoration:BoxDecoration(
                  color:sel?kYellow:kCard,borderRadius:BorderRadius.circular(12),border:Border.all(color:sel?kYellow:kBorder)),
                  child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[
                    Text(top, style:GoogleFonts.notoSans(color:sel?Colors.black:Colors.white,fontWeight:FontWeight.w800,fontSize:13)),
                    Text(sub, style:GoogleFonts.notoSans(color:sel?Colors.black54:Colors.white38,fontSize:10)),
                  ])));
        }).toList()),
    const SizedBox(height:16),

    _lbl('Эсвэл дүн бичих'),
    ClipRRect(borderRadius:BorderRadius.circular(12),child:Row(children:[
      Container(padding:const EdgeInsets.symmetric(horizontal:14,vertical:16),color:const Color(0xFF1E1E1E),
          child:Text(_reverseMode && _dir=='eu_to_mn' ? '₮' : _dir=='eu_to_mn' ? _cur : '₮',
              style:GoogleFonts.notoSans(color:kYellow,fontWeight:FontWeight.w800,fontSize:16))),
      Expanded(child:TextField(controller:_aC,keyboardType:TextInputType.number,onChanged:(_)=>setState((){}),
          style:GoogleFonts.notoSans(color:Colors.white,fontSize:20,fontWeight:FontWeight.w700),
          decoration:InputDecoration(hintText:'0',hintStyle:GoogleFonts.notoSans(color:Colors.white12,fontSize:20),
              filled:true,fillColor:kCard,border:InputBorder.none,contentPadding:const EdgeInsets.symmetric(horizontal:16,vertical:16)))),
    ])),

    if(_amt>0)...[const SizedBox(height:12),_calcBox()],
    const SizedBox(height:20),

    _lbl('Дансны мэдээлэл'),
    if (_savedAccounts.isNotEmpty) ...[
      const SizedBox(height: 8),
      _lbl2(_dir == 'eu_to_mn'
          ? 'Хадгалсан Монгол дансаас сонгох'
          : 'Хадгалсан IBAN (гадаад данс) сонгох'),
      SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
              children: _savedAccounts
                  .map((acc) => GestureDetector(
                        onTap: () => _selectSaved(acc),
                        onLongPress: () => _promptRemoveSaved(acc),
                        child: Container(
                          margin: const EdgeInsets.only(right: 10, bottom: 12),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: _savedChipSelected(acc)
                                ? kYellow.withOpacity(0.12)
                                : kCard,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: _savedChipSelected(acc)
                                  ? kYellow
                                  : kBorder,
                            ),
                          ),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  acc.name.isNotEmpty ? acc.name : acc.bank,
                                  style: GoogleFonts.notoSans(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13),
                                ),
                                Text(
                                  savedAccountDisplayNo(acc.accountNo),
                                  style: GoogleFonts.notoSans(
                                      color: Colors.white38, fontSize: 11),
                                ),
                              ]),
                        ),
                      ))
                  .toList())),
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          'Удаан дарвал хадгалсан дансыг устгана',
          style: GoogleFonts.notoSans(color: Colors.white24, fontSize: 10.5),
        ),
      ),
      const SizedBox(height: 4),
    ],

    _lbl(_dir=='eu_to_mn'
        ? 'Хүлээн авах данс (Монгол)'
        : (_mnToEuDomesticDeposit
            ? 'Хүлээн авах IBAN (Европ) — заавал биш; оруулбал админд шууд харагдана'
            : 'Хүлээн авах IBAN (Европ)')),
    _ibanField(),
    const SizedBox(height:8),
    _lbl(_dir == 'eu_to_mn' ? 'Овог, нэр (кирилл)' : 'Овог, нэр (латин)'),
    const SizedBox(height:6),
    _tf2(_nC,_dir == 'mn_to_eu'
        ? 'Жишээ: Batbayar Dorj'
        : 'Жишээ: Батбаярын Дорж',TextInputType.text,false,(_)=>setState((){})),
    if (_dir == 'mn_to_eu' &&
        _nC.text.trim().isNotEmpty &&
        recipientNameHasNonLatinScript(_nC.text)) ...[
      const SizedBox(height: 6),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: kYellow, size: 15),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Европ руу илгээхэд овог нэрийг зөвхөн латин үсгээр (галлигацаар) бичнэ үү. Монгол кирилл эсвэл монгол бичгээр бичих боломжгүй.',
              style: GoogleFonts.notoSans(color: kYellow, fontSize: 11.5, height: 1.35),
            ),
          ),
        ],
      ),
    ],
    if(_nC.text.trim().isEmpty && _dC.text.trim().isNotEmpty)...[
      const SizedBox(height:4),
      Row(children:[
        const Icon(Icons.warning_amber_rounded,color:kRed,size:13),
        const SizedBox(width:4),
        Text('Овог нэрийг заавал оруулна уу',style:GoogleFonts.notoSans(color:kRed,fontSize:11,fontWeight:FontWeight.w600)),
      ]),
    ],
    const SizedBox(height:10),

    if (_selectedSaved == null)
      GestureDetector(onTap:()=>setState(()=>_saveAcc=!_saveAcc),
          child:Row(children:[_check(_saveAcc),const SizedBox(width:10),
            Text('Энэ дансыг хадгалах',style:GoogleFonts.notoSans(color:Colors.white60,fontSize:13))])),
    const SizedBox(height:14),

    const SizedBox(height: 12),
    Row(children:[
      Expanded(child:_lbl2('Гүйлгээний утга')),
      Container(padding:const EdgeInsets.symmetric(horizontal:8,vertical:3),
          decoration:BoxDecoration(color:kGreen.withOpacity(0.12),borderRadius:BorderRadius.circular(8)),
          child:Text('+2 EUR',style:GoogleFonts.notoSans(color:kGreen,fontWeight:FontWeight.w700,fontSize:11))),
    ]),
    const SizedBox(height:6),
    TextField(controller:_refC, onChanged:(_)=>setState((){}),
        style:GoogleFonts.notoSans(color:Colors.white,fontSize:14),
        decoration:InputDecoration(
            hintText:'Жишээ: Төрсөн өдрийн мэнд, Цалин, нэр...',
            hintStyle:GoogleFonts.notoSans(color:Colors.white24,fontSize:13),
            filled:true, fillColor:kCard,
            border:OutlineInputBorder(borderRadius:BorderRadius.circular(12),borderSide:const BorderSide(color:kBorder)),
            enabledBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(12),borderSide:const BorderSide(color:kBorder)),
            focusedBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(12),borderSide:const BorderSide(color:kYellow)),
            suffixIcon:_refC.text.isNotEmpty?IconButton(
                icon:const Icon(Icons.close_rounded,color:Colors.white38,size:18),
                onPressed:()=>setState(()=>_refC.clear())):null)),
    const SizedBox(height:12),

    _amlSourcePicker(),
    const SizedBox(height:12),

    GestureDetector(
        onTap: (_amt>0 && _aml && _amlSource!=null) ? () => _handleSendTap() : null,
        child:Container(width:double.infinity,padding:const EdgeInsets.symmetric(vertical:18),
            decoration:BoxDecoration(
                gradient:(_amt>0&&_aml&&_amlSource!=null)?const LinearGradient(colors:[kYellow, kYellowDeep]):null,
                color:(_amt>0&&_aml&&_amlSource!=null)?null:kBorder,
                borderRadius:BorderRadius.circular(16),
                boxShadow:(_amt>0&&_aml&&_amlSource!=null)?[BoxShadow(color:kYellow.withOpacity(0.3),blurRadius:20,offset:const Offset(0,6))]:null),
            child:Center(child:Text(_btnLabel(),style:GoogleFonts.notoSans(
                color:(_amt>0&&_aml&&_amlSource!=null)?Colors.black:Colors.white24,fontWeight:FontWeight.w800,fontSize:16))))),
    const SizedBox(height:30),
    ],
  ]);

  /// Орчин үеийн EU ↔ MN чиглэл сонгогч (анимаци + градиент).
  Widget _buildDirectionSwitcher() {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        const pillPad = 4.0;
        final pillWidth = (w - pillPad * 2) / 2;
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF242424),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withOpacity(0.06)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.35),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(17),
            child: SizedBox(
              height: 92,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                    left: _dir == 'eu_to_mn' ? pillPad : pillPad + pillWidth,
                    top: pillPad,
                    width: pillWidth,
                    bottom: pillPad,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [kYellow, kYellowDeep],
                        ),
                        borderRadius: BorderRadius.circular(13),
                        boxShadow: [
                          BoxShadow(
                            color: kYellow.withOpacity(0.28),
                            blurRadius: 12,
                            spreadRadius: -2,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => _switchDir('eu_to_mn'),
                            splashColor: kYellow.withOpacity(0.15),
                            highlightColor: Colors.white.withOpacity(0.04),
                            borderRadius: BorderRadius.circular(14),
                            child: Center(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.center,
                                child: _dirSegmentContent(
                                  selected: _dir == 'eu_to_mn',
                                  fromFlag: '🇪🇺',
                                  toFlag: '🇲🇳',
                                  title: 'Европ → Монгол',
                                  subtitle: 'EUR · MNT',
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => _switchDir('mn_to_eu'),
                            splashColor: kYellow.withOpacity(0.15),
                            highlightColor: Colors.white.withOpacity(0.04),
                            borderRadius: BorderRadius.circular(14),
                            child: Center(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.center,
                                child: _dirSegmentContent(
                                  selected: _dir == 'mn_to_eu',
                                  fromFlag: '🇲🇳',
                                  toFlag: '🇪🇺',
                                  title: 'Монгол → Европ',
                                  subtitle: 'MNT · EUR',
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _dirSegmentContent({
    required bool selected,
    required String fromFlag,
    required String toFlag,
    required String title,
    required String subtitle,
  }) {
    final fg = selected ? Colors.black87 : Colors.white.withOpacity(0.88);
    final subFg = selected ? Colors.black.withOpacity(0.48) : Colors.white.withOpacity(0.42);
    final arrowCol =
        selected ? Colors.black.withOpacity(0.38) : Colors.white.withOpacity(0.28);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(fromFlag, style: const TextStyle(fontSize: 20)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.arrow_forward_rounded, size: 16, color: arrowCol),
              ),
              Text(toFlag, style: const TextStyle(fontSize: 20)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.notoSans(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              height: 1.15,
              letterSpacing: -0.2,
              color: fg,
            ),
          ),
          Text(
            subtitle,
            style: GoogleFonts.notoSans(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              height: 1.15,
              letterSpacing: 0.2,
              color: subFg,
            ),
          ),
        ],
      ),
    );
  }

  String _paySub(PayMethod p){switch(p.id){
    case 'google_pay': return 'Stripe · Google Pay';
    case 'apple_pay': return 'Stripe · Apple Pay';
    case 'stripe_wallet': return 'Stripe · төлбөр (хуучин)';
    case 'paypal': return 'paypal.me/munkhmandal';
    case 'klarna': return 'Stripe · Klarna (Pay later, Ratenzahlung…)';
    case 'sepa': return 'Европын банкнаас SEPA';
    case 'manuel':
    case 'eu_transfer_reference': return 'Гараар банкнаас шилжүүлнэ · Reference самбар';
    case 'mn_manuel':
      return '₮ шилжүүлэг → админ шалгаад DE IBAN-р гүйлгээ · самбар баталгаа';
    case 'golomt':
      return 'Голомт апп → манай Хаан ₮ дансанд төлөлт → EUR IBAN хүргэлт (админ)';
    case 'loan_install': return 'Зээлийн эрх, гэрээ — дараа нь гүйлгээ баталгаажина';
    default: return p.url.isNotEmpty ? p.url : '${p.name}';
  }}

  String _btnLabel(){
    if(_amt<=0) return 'Дүн оруулна уу';
    if(!_aml || _amlSource==null) return 'Мөнгөний эх үүсвэр сонгоно уу';
    if(_threeInstall) return '💳  Зээлээр шилжүүлэх  →';
    return '💸  Шилжүүлэх';
  }

  Widget _calcBox() {
    final isEuToMn    = _dir == 'eu_to_mn';
    final isMnToEuRev = !isEuToMn && _reverseMode;
    final isEuToMnRev = isEuToMn && _reverseMode;
    final curLabel    = isEuToMn ? _cur : 'EUR';
    final sym         = isEuToMn ? _sym : '€';
    final baseFee     = calcFee(isEuToMn ? _amt : (_reverseMode ? _inputAmt : _amt/_rate));

    // ── Зээлийн горим ──────────────────────────────────────────────
    if (_threeInstall) {
      final svcFee   = _installServiceFee;
      final grandTot = _installGrandTotal;
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: kYellow.withOpacity(0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kYellow.withOpacity(0.3))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Толгой — шилжүүлэх дүн + нэг удаагийн шимтгэл
          Row(children: [
            const Icon(Icons.info_outline_rounded, color: Colors.white38, size: 14),
            const SizedBox(width: 6),
            Expanded(child: Text(
              'Зээлийн бодолт · Хүлээн авагч бүтэн дүн авна',
              style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11))),
          ]),
          if (_loanPrincipalOverCap) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: kRed.withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kRed.withOpacity(0.35)),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.warning_amber_rounded, color: kRed.withOpacity(0.95), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Үндсэн дүн ${LoanStore.maxLoanPrincipalEur.toStringAsFixed(0)} EUR-аас их байна. Илүү хэсгийг бууруулна уу.',
                    style: GoogleFonts.notoSans(color: Colors.white70, fontSize: 11.5, height: 1.4),
                  ),
                ),
              ]),
            ),
          ],
          const SizedBox(height: 12),
          // ① үндсэн дүн + шимтгэл = нийт зээл
          _cr('Шилжүүлэх дүн',
              '$sym${_installBase.toStringAsFixed(2)} $curLabel', Colors.white),
          const SizedBox(height: 4),
          _cr('+ Нэг удаагийн шимтгэл',
              '+$sym${svcFee.toStringAsFixed(2)} $curLabel', kRed),
          if (_refFee > 0) ...[
            const SizedBox(height: 4),
            _cr('+ Гүйлгээний утга', '+$sym${_refFee.toStringAsFixed(2)} $curLabel', kGreen),
          ],
          const SizedBox(height: 6),
          // нийт зээлийн хэмжээ
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.04),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kBorder)),
            child: Row(children: [
              Text('= Нийт зээлийн хэмжээ',
                  style: GoogleFonts.notoSans(color: Colors.white60,
                      fontWeight: FontWeight.w700, fontSize: 12)),
              const Spacer(),
              Text('$sym${_installTotalLoan.toStringAsFixed(2)} $curLabel',
                  style: GoogleFonts.notoSans(color: Colors.white,
                      fontWeight: FontWeight.w800, fontSize: 13)),
            ]),
          ),
          const SizedBox(height: 6),
          _cr('+ Зээл олгох шимтгэл',
              '+$sym${_installOriginFee.toStringAsFixed(2)} $curLabel', Colors.orange),
          const Divider(color: kBorder, height: 18),
          // ② 3 ангилалын мөрүүд
          ..._installmentRows(sym, curLabel),
          const SizedBox(height: 4),
          // ③ нийт гранд тотал
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [kYellow.withOpacity(0.15), kYellow.withOpacity(0.06)]),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kYellow.withOpacity(0.45))),
            child: Row(children: [
              const Icon(Icons.account_balance_wallet_rounded, color: kYellow, size: 18),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Нийт төлөх (зээл + хүү + шимтгэл)',
                    style: GoogleFonts.notoSans(color: Colors.white54,
                        fontWeight: FontWeight.w600, fontSize: 11)),
                const SizedBox(height: 2),
                Text('$sym${grandTot.toStringAsFixed(2)} $curLabel',
                    style: GoogleFonts.notoSans(color: kYellow,
                        fontWeight: FontWeight.w900, fontSize: 20)),
              ])),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('Хүлээн авах',
                    style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 10)),
                Text(_fmtConv(),
                    style: GoogleFonts.notoSans(color: kGreen,
                        fontWeight: FontWeight.w800, fontSize: 14)),
              ]),
            ]),
          ),
          const SizedBox(height: 6),
          _cr('Ханш', '1 $curLabel = ₮ ${fmtMnt(_rate)}', Colors.white24),
        ]),
      );
    }

    // ── Ердийн горим ───────────────────────────────────────────────
    return Container(padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: kYellow.withOpacity(0.06),
          borderRadius: BorderRadius.circular(14), border: Border.all(color: kYellow.withOpacity(0.25))),
      child: Column(children: [
        if (isMnToEuRev) ...[
          _cr('Авах дүн','€ ${_inputAmt.toStringAsFixed(2)} EUR',Colors.white),
          const SizedBox(height:4),
          _cr('+ Шимтгэл','+${baseFee.toStringAsFixed(2)} EUR',kRed),
          if (_refFee > 0)
            _cr('+ Гүйлгээний утга','+${_refFee.toStringAsFixed(2)} EUR',kGreen),
          const Divider(color:kBorder,height:16),
          _cr('Нийт EUR шаардлагатай','${(_inputAmt+_fee).toStringAsFixed(2)} EUR',Colors.white60),
          const SizedBox(height:4),
          _cr('× Ханш','× ₮ ${fmtMnt(_rate)}',Colors.white38),
        ] else if (isEuToMn && !isEuToMnRev) ...[
          Text(
            'Европоос төлөх нийт ($_cur)',
            style: GoogleFonts.notoSans(
                color: Colors.white54, fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  'Stripe / Google Pay / Wise',
                  style: GoogleFonts.notoSans(
                      color: Colors.white38, fontSize: 11, height: 1.25),
                ),
              ),
              Text(
                _fmtTotal(),
                style: GoogleFonts.notoSans(
                    color: kYellow, fontWeight: FontWeight.w900, fontSize: 22),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Задлах',
            style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11),
          ),
          const SizedBox(height: 6),
          _cr('Үндсэн шилжүүлэх', '$sym ${_amt.toStringAsFixed(2)} $_cur', Colors.white70),
          _cr('+ Шимтгэл', '+$sym${baseFee.toStringAsFixed(2)} $curLabel', kRed),
          if (_refFee > 0)
            _cr('+ Гүйлгээний утга', '+$sym${_refFee.toStringAsFixed(2)} $curLabel', kGreen),
          const SizedBox(height: 12),
          _cr('Ханш', '1 $curLabel = ₮ ${fmtMnt(_rate)}', Colors.white38),
          const Divider(color: kBorder, height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  '🇲🇳 Монгол дансанд очих',
                  style: GoogleFonts.notoSans(
                      color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                ),
              ),
              Text(
                _fmtConv(),
                style: GoogleFonts.notoSans(
                    color: kGreen, fontWeight: FontWeight.w900, fontSize: 22),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              'Бүтэн дүн хүрнэ · 5–30 мин',
              style: GoogleFonts.notoSans(color: Colors.white24, fontSize: 10),
            ),
          ),
        ] else if (isEuToMnRev) ...[
          _cr('Авах дүн','₮ ${fmtMnt(_inputAmt.round())}',Colors.white),
          const SizedBox(height:4),
          _cr('$_cur хэмжээ','$sym ${_amt.toStringAsFixed(2)} $_cur',Colors.white60),
          _cr('+ Шимтгэл','+$sym${baseFee.toStringAsFixed(2)} $_cur',kRed),
          if (_refFee > 0)
            _cr('+ Гүйлгээний утга','+$sym${_refFee.toStringAsFixed(2)} $_cur',kGreen),
        ] else ...[
          _cr('Шилжүүлэх дүн',
              '₮ ${fmtMnt(_amt.round())}',
              Colors.white),
          const SizedBox(height:4),
          _cr('+ Шимтгэл','+$sym${baseFee.toStringAsFixed(2)} $curLabel',kRed),
          if (_refFee > 0)
            _cr('+ Гүйлгээний утга','+$sym${_refFee.toStringAsFixed(2)} $curLabel',kGreen),
        ],
        if (!isEuToMn || isEuToMnRev) ...[
        const Divider(color:kBorder,height:20),
        Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,
            crossAxisAlignment:CrossAxisAlignment.end,
            children:[
          Text('💳 Та нийт төлнө',
              style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w700,fontSize:13)),
          Text(_fmtTotal(),
              style:GoogleFonts.notoSans(color:kYellow,fontWeight:FontWeight.w900,fontSize:20),
              maxLines:1,overflow:TextOverflow.ellipsis,textAlign:TextAlign.right),
        ]),
        const SizedBox(height:6),
        _cr('Ханш','1 $curLabel = ₮ ${fmtMnt(_rate)}',Colors.white38),
        const Divider(color:kBorder,height:20),
        Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,
            crossAxisAlignment:CrossAxisAlignment.end,
            children:[
          Text(isEuToMn ? '🇲🇳 Хүлээн авах' : '🇪🇺 Хүлээн авах',
              style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w700,fontSize:13)),
          Text(_fmtConv(),
              style:GoogleFonts.notoSans(color:kGreen,fontWeight:FontWeight.w900,fontSize:20),
              maxLines:1,overflow:TextOverflow.ellipsis,textAlign:TextAlign.right),
        ]),
        const SizedBox(height:4),
        Align(alignment:Alignment.centerRight,
            child:Text('Бүтэн дүн хүрнэ · 5–30 мин',
                style:GoogleFonts.notoSans(color:Colors.white24,fontSize:10))),
        ],
      ]));
  }

  int get _threeInstall_parts => _threeInstall ? 3 : 1;

  // ── 3 хувааж / Зээл — тооцооллын хэсэг ───────────────────────────
  // Жишээ: 100 EUR шилжүүлэх үед
  //   shimtgel    = calcFee(100)          = 6 EUR  (нэг удаа)
  //   principal/3 = (100 + 6) / 3         = 35.33 EUR
  //   loanInterest= calcFee(100)           = 6 EUR  (тус бүр ижил)
  //   installment = 35.33 + 6             = 41.33 EUR
  //   grand total = 41.33 × 3             = 123.99 EUR

  // EUR дүн (mn_to_eu: _inputAmt+_fee, eu_to_mn: _amt)
  double get _installBase {
    if (_dir == 'mn_to_eu' && _reverseMode) return _inputAmt + _fee;
    if (_dir == 'mn_to_eu')                 return _amt / _rate;
    return _amt; // eu_to_mn
  }

  // Нэг удаагийн үйлчилгээний шимтгэл
  double get _installServiceFee => calcFee(_installBase);

  // Нийт зээлийн хэмжээ = үндсэн + шимтгэл (жишээ: 100 + 6 = 106 EUR)
  double get _installTotalLoan => _installBase + _installServiceFee;

  // Нэг ангилалын үндсэн дүн (нийт зээлийг 3-т хувааж)
  double get _installPrincipalPerPart => _installTotalLoan / 3;

  // Нэг ангилалын зээлийн хүү (нийт зээлээс сарын 3%)
  double get _installLoanPerPart => _installTotalLoan * 0.03;

  // Нэг удаагийн зээл олгох шимтгэл
  double get _installOriginFee => 2.0;

  // Нэг ангилалын нийт = үндсэн + хүү
  double get _installAmt => _installPrincipalPerPart + _installLoanPerPart;

  // Нийт гранд тотал = (ангилал × 3) + зээл олгох шимтгэл
  double get _installGrandTotal => _installAmt * 3 + _installOriginFee;

  /// Гэрээний хүүний нийлбэр (эрт хаах жишиг хүүний суурь)
  double get _loanInterestPortionEur => _installLoanPerPart * 3 + _installOriginFee;

  bool get _loanPrincipalOverCap =>
      _threeInstall && _installBase > LoanStore.maxLoanPrincipalEur + 1e-9;

  String _installDate(int monthOffset) {
    final d = DateTime.now();
    final m = d.month + monthOffset;
    final y = d.year + (m - 1) ~/ 12;
    final nm = ((m - 1) % 12) + 1;
    final day = d.day;
    return '${y}.${nm.toString().padLeft(2,'0')}.${day.toString().padLeft(2,'0')}';
  }

  List<Widget> _installmentRows(String sym, String curLabel) {
    final dates   = [_installDate(0), _installDate(1), _installDate(2)];
    final dateLabels = ['өнөөдөр', '1 сарын дараа', '2 сарын дараа'];
    final principal = _installPrincipalPerPart;
    final loanFee   = _installLoanPerPart;

    return List.generate(3, (i) {
      final isFirst = i == 0;
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isFirst ? kYellow.withOpacity(0.08) : kCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isFirst ? kYellow.withOpacity(0.45) : kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 24, height: 24,
              decoration: BoxDecoration(
                color: isFirst ? kYellow : kBorder,
                shape: BoxShape.circle),
              child: Center(child: Text('${i+1}',
                  style: GoogleFonts.notoSans(
                      color: isFirst ? Colors.black : Colors.white,
                      fontWeight: FontWeight.w900, fontSize: 11)))),
            const SizedBox(width: 8),
            Expanded(child: Text('${i+1}-р төлөлт  ·  ${dateLabels[i]}',
                style: GoogleFonts.notoSans(
                    color: isFirst ? kYellow : Colors.white54,
                    fontWeight: FontWeight.w700, fontSize: 12))),
            Text(dates[i],
                style: GoogleFonts.notoSans(color: Colors.white24, fontSize: 11)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _installCell(
                'Үндсэн дүн', '$sym${principal.toStringAsFixed(2)} $curLabel',
                Colors.white70, isFirst)),
            const SizedBox(width: 8),
            Expanded(child:           _installCell(
                'Хүү (3%)', '+$sym${loanFee.toStringAsFixed(2)} $curLabel',
                kRed, isFirst)),
            const SizedBox(width: 8),
            Expanded(child: _installCell(
                'Нийт', '$sym${_installAmt.toStringAsFixed(2)} $curLabel',
                isFirst ? kYellow : Colors.white, isFirst)),
          ]),
        ]),
      );
    });
  }

  Widget _installCell(String label, String value, Color valueColor, bool highlight) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: highlight ? kYellow.withOpacity(0.06) : kBg.withOpacity(0.6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: highlight ? kYellow.withOpacity(0.2) : kBorder.withOpacity(0.5))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: GoogleFonts.notoSans(color: Colors.white24, fontSize: 9)),
          const SizedBox(height: 2),
          Text(value, style: GoogleFonts.notoSans(
              color: valueColor, fontWeight: FontWeight.w700, fontSize: 11),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
      );

  Widget _cr(String l, String v, Color c) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(l,
            style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 12),
        Text(v,
          style: GoogleFonts.notoSans(
              color: c, fontWeight: FontWeight.w600, fontSize: 12),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.right),
      ],
    ),
  );

  Widget _ibanField() {
    final raw = _dC.text.trim();
    final hasInput = raw.isNotEmpty;

    Color borderColor = kBorder;
    Color statusColor = Colors.transparent;
    String statusMsg = '';
    IconData statusIcon = Icons.info_outline;
    String subLabel = '';

    if (_dir == 'eu_to_mn') {
      final valid = isMongolianAccountValid(raw);
      final bankGuess = hasInput ? guessMongoBank(raw) : '';
      if (hasInput) {
          if (valid) {
          if (_lookingUpName) {
            borderColor = kYellow; statusColor = kYellow;
            statusMsg = 'Банкны системд шалгаж байна…';
            statusIcon = Icons.hourglass_top_rounded;
          } else if (_accountFound) {
            borderColor = kGreen; statusColor = kGreen;
            statusMsg = '✓ Дансны дугаар баталгаажлаа';
            statusIcon = Icons.check_circle_rounded;
          } else if (_lookupError != null) {
            borderColor = kRed; statusColor = kRed;
            statusMsg = '✗ $_lookupError'; statusIcon = Icons.cancel_rounded;
          } else {
            // Credential тохируулаагүй — формат зөв гэдгийг л харуулна
            borderColor = kGreen; statusColor = kGreen;
            statusMsg = '✓ Форматын шалгалт зөв';
            statusIcon = Icons.check_circle_outline_rounded;
          }
        } else {
          final digits = mnAccountDigits(raw);
          borderColor = kRed; statusColor = kRed;
          if (digits.length < 18) {
            statusMsg = '${digits.length}/18 орон — ${18 - digits.length} орон дутуу';
          } else if (digits.length > 18) {
            statusMsg = 'Хэт урт (${digits.length} орон) — яг 18 орон шаардлагатай';
          } else {
            statusMsg = 'Зөвхөн тоо оруулна уу';
          }
          statusIcon = Icons.cancel_rounded;
        }
        if (bankGuess.isNotEmpty && valid) subLabel = bankGuess;
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          decoration: BoxDecoration(
            color: kCard, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor, width: hasInput ? 1.8 : 1)),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
              decoration: const BoxDecoration(
                border: Border(right: BorderSide(color: kBorder))),
              child: Text('MN', style: GoogleFonts.notoSans(
                  color: kYellow, fontWeight: FontWeight.w800, fontSize: 16, letterSpacing: 1)),
            ),
            Expanded(child: TextField(
              controller: _dC,
              keyboardType: TextInputType.number,
              maxLength: 18,
              onChanged: (v) {
                final digits = v.replaceAll(RegExp(r'\D'), '');
                if (digits != v) {
                  _dC.value = TextEditingValue(
                    text: digits,
                    selection: TextSelection.collapsed(offset: digits.length));
                }
                setState(() {
                  _accountFound = false;
                  _lookedUpName = null;
                  _lookupError = null;
                  _clearSelectedSavedIfAccountNoMismatch();
                });
                if (isMongolianAccountValid(digits)) _lookupAccountName();
              },
              style: GoogleFonts.notoSans(color: Colors.white, fontSize: 15, letterSpacing: 2),
              decoration: InputDecoration(
                counterText: '',
                hintText: '850005005003685858',
                hintStyle: GoogleFonts.notoSans(color: Colors.white24, letterSpacing: 1),
                filled: true, fillColor: Colors.transparent,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                suffixIcon: hasInput
                    ? Icon(statusIcon, color: statusColor, size: 22)
                    : const Icon(Icons.credit_card_rounded, color: Colors.white24, size: 20)),
            )),
          ]),
        ),
        if (hasInput) ...[
          const SizedBox(height: 8),
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: statusColor.withOpacity(0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: statusColor.withOpacity(0.3))),
            child: Row(children: [
              _lookingUpName
                  ? SizedBox(width:14,height:14,child:CircularProgressIndicator(strokeWidth:2,color:kYellow))
                  : Icon(statusIcon, color: statusColor, size: 15),
              const SizedBox(width: 8),
              Expanded(child: Text(statusMsg,
                  style: GoogleFonts.notoSans(color: statusColor, fontSize: 12, fontWeight: FontWeight.w600))),
              if (subLabel.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: kGreen.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: kGreen.withOpacity(0.42)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.account_balance_rounded,
                          color: kGreen.withOpacity(0.95), size: 14),
                      const SizedBox(width: 6),
                      Text(
                        subLabel,
                        style: GoogleFonts.notoSans(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ]),
          ),
        ],
      ]);
    }

    // EU IBAN шалгалт
    final locationLine = hasInput ? ibanRecipientBankCityCountryLine(raw) : '';
    final looks = hasInput && looksLikeIban(raw);
    final valid = looks && isValidIban(raw);
    if (hasInput) {
      if (valid) {
        borderColor = kGreen;
        statusColor = kGreen;
        statusMsg = '✓ IBAN зөв (MOD-97 баталгаажсан)';
        statusIcon = Icons.check_circle_rounded;
      } else if (looks) {
        borderColor = kRed;
        statusColor = kRed;
        statusMsg = '✗ IBAN checksum буруу. Дахин нягтална уу.';
        statusIcon = Icons.cancel_rounded;
      } else {
        borderColor = kRed;
        statusColor = kRed;
        statusMsg = '✗ IBAN формат буруу (жишээ: DE89…, FR76…, ES91…)';
        statusIcon = Icons.cancel_rounded;
      }
    }
    return _accountField(
      hint: 'DE89… / FR76… / ES91… / NL…',
      keyboard: TextInputType.text,
      capitalize: TextCapitalization.characters,
      borderColor: borderColor,
      statusColor: statusColor,
      statusMsg: statusMsg,
      statusIcon: statusIcon,
      subLabel: subLabel,
      locationLine: locationLine,
      hasInput: hasInput,
      onChanged: (_) => setState(() => _clearSelectedSavedIfAccountNoMismatch()),
    );
  }

  Widget _accountField({
    required String hint,
    required TextInputType keyboard,
    required TextCapitalization capitalize,
    required Color borderColor,
    required Color statusColor,
    required String statusMsg,
    required IconData statusIcon,
    required String subLabel,
    String locationLine = '',
    required bool hasInput,
    void Function(String)? onChanged,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        decoration: BoxDecoration(
          color: kCard, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor, width: hasInput ? 1.8 : 1)),
        child: TextField(
          controller: _dC,
          keyboardType: keyboard,
          textCapitalization: capitalize,
          onChanged: onChanged ?? (_) => setState(() {}),
          style: GoogleFonts.notoSans(color: Colors.white, fontSize: 15, letterSpacing: 1),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: GoogleFonts.notoSans(color: Colors.white24, letterSpacing: 0.5),
            filled: true, fillColor: Colors.transparent,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            suffixIcon: hasInput
                ? Icon(statusIcon, color: statusColor, size: 22)
                : const Icon(Icons.credit_card_rounded, color: Colors.white24, size: 20)),
        )),
      if (locationLine.isNotEmpty) ...[
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Text(
            locationLine,
            style: GoogleFonts.notoSans(
              color: Colors.white54,
              fontSize: 11,
              height: 1.28,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
      if (hasInput) ...[
        const SizedBox(height: 6),
        Row(children: [
          Icon(statusIcon, color: statusColor, size: 14),
          const SizedBox(width: 6),
          Expanded(child: Text(statusMsg,
              style: GoogleFonts.notoSans(color: statusColor, fontSize: 12, fontWeight: FontWeight.w600))),
        ]),
        if (subLabel.isNotEmpty) ...[
          const SizedBox(height: 3),
          Row(children: [
            const SizedBox(width: 20),
            const Icon(Icons.account_balance_rounded, color: Colors.white38, size: 12),
            const SizedBox(width: 4),
            Text(subLabel, style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11)),
          ]),
        ],
      ],
    ]);
  }

  static const _amlOptions = [
    ('💼', 'Цалин / Хөлс'),
    ('🏪', 'Бизнесийн орлого'),
    ('💰', 'Хуримтлал / Хадгаламж'),
    ('🏠', 'Үл хөдлөх хөрөнгийн борлуулалт'),
    ('🎁', 'Бэлэг / Тусламж'),
    ('🏦', 'Зээл'),
    ('📈', 'Хөрөнгө оруулалтын орлого'),
    ('🔄', 'Бусад'),
  ];

  void _openAmlSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(builder: (ctx, setS) =>
        Container(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24),
          decoration: const BoxDecoration(
            color: Color(0xFF1A1A1A),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('Мөнгөний эх үүсвэр',
                  style: GoogleFonts.notoSans(color: Colors.white,
                      fontWeight: FontWeight.w800, fontSize: 17)),
              const Spacer(),
              IconButton(icon: const Icon(Icons.close_rounded, color: Colors.white38),
                  onPressed: () => Navigator.pop(ctx)),
            ]),
            const SizedBox(height: 4),
            Text('Шилжүүлэх мөнгөний хууль ёсны эх үүсвэрийг сонгоно уу',
                style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12)),
            const SizedBox(height: 16),
            Wrap(spacing: 10, runSpacing: 10, children: _amlOptions.map((opt) {
              final sel = _amlSource == opt.$2;
              return GestureDetector(
                onTap: () {
                  setState(() { _aml = true; _amlSource = opt.$2; });
                  Navigator.pop(ctx);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: sel ? kYellow.withOpacity(0.14) : kCard,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: sel ? kYellow : kBorder, width: sel ? 1.8 : 1)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(opt.$1, style: const TextStyle(fontSize: 18)),
                    const SizedBox(width: 8),
                    Text(opt.$2, style: GoogleFonts.notoSans(
                        color: sel ? kYellow : Colors.white70,
                        fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                        fontSize: 13)),
                    if (sel) ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.check_circle_rounded, color: kYellow, size: 16),
                    ],
                  ]),
                ),
              );
            }).toList()),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
  }

  Widget _amlSourcePicker() {
    final selected = _aml && _amlSource != null;
    return GestureDetector(
      onTap: _openAmlSheet,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? kYellow.withOpacity(0.08) : kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? kYellow.withOpacity(0.6) : kRed.withOpacity(0.5),
            width: selected ? 1.5 : 1.5)),
        child: Row(children: [
          Container(width: 36, height: 36,
            decoration: BoxDecoration(
              color: selected ? kYellow.withOpacity(0.15) : kRed.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10)),
            child: Icon(
              selected ? Icons.check_circle_rounded : Icons.account_balance_rounded,
              color: selected ? kYellow : kRed, size: 18)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Мөнгөний эх үүсвэр',
                style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11)),
            const SizedBox(height: 2),
            Text(selected ? _amlSource! : 'Сонгоно уу  →',
                style: GoogleFonts.notoSans(
                    color: selected ? kYellow : Colors.white,
                    fontWeight: FontWeight.w700, fontSize: 14)),
          ])),
          if (selected)
            GestureDetector(
              onTap: () => setState(() { _aml = false; _amlSource = null; }),
              child: const Icon(Icons.close_rounded, color: Colors.white24, size: 18))
          else
            const Icon(Icons.chevron_right_rounded, color: Colors.white38, size: 20),
        ]),
      ),
    );
  }

  Widget _reverseModeToggle() {
    final isEuMn = _dir == 'eu_to_mn';
    final normalLabel  = isEuMn ? '$_sym $_cur оруулах' : '₮ оруулах';
    final normalSub    = isEuMn ? '→ ₮ авах'           : '→ € авах';
    final reverseLabel = isEuMn ? '₮ оруулах'          : '€ оруулах';
    final reverseSub   = isEuMn ? '← $_sym буцаан бодно' : '← ₮ буцаан бодно';
    return Row(children: [
      _rmBtn(normalLabel, normalSub,  !_reverseMode, () => setState((){_reverseMode=false;_aC.clear();})),
      const SizedBox(width: 10),
      _rmBtn(reverseLabel, reverseSub, _reverseMode, () => setState((){_reverseMode=true;_aC.clear();})),
    ]);
  }

  Widget _rmBtn(String label, String sub, bool sel, VoidCallback onTap) =>
    Expanded(child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: sel ? kYellow : kCard,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: sel ? kYellow : kBorder)),
        child: Column(children: [
          Text(label, style: GoogleFonts.notoSans(
              color: sel ? Colors.black : Colors.white54,
              fontWeight: FontWeight.w700, fontSize: 12)),
          Text(sub, style: GoogleFonts.notoSans(
              color: sel ? Colors.black54 : Colors.white24, fontSize: 10)),
        ]),
      ),
    ));

  Widget _lbl(String t)=>Padding(padding:const EdgeInsets.only(bottom:8,top:4),
      child:Text(t,style:GoogleFonts.notoSans(color:Colors.white38,fontSize:12,fontWeight:FontWeight.w600)));
  Widget _lbl2(String t)=>Text(t,style:GoogleFonts.notoSans(color:Colors.white38,fontSize:12,fontWeight:FontWeight.w600));

  Widget _check(bool v)=>Container(width:22,height:22,
      decoration:BoxDecoration(color:v?kYellow:kCard,borderRadius:BorderRadius.circular(6),border:Border.all(color:v?kYellow:kBorder)),
      child:v?const Icon(Icons.check,color:Colors.black,size:14):null);

  Widget _buildSuccess() {
    final awaitingAdmin =
        _successLinkedTx != null && !_successLinkedTx!.isCompleted;
    final accent = awaitingAdmin ? kYellow : kGreen;
    final iconBg = awaitingAdmin
        ? kYellow.withOpacity(0.12)
        : kGreen.withOpacity(0.15);
    final iconData =
        awaitingAdmin ? Icons.pending_actions_rounded : Icons.check_circle_rounded;
    final title = awaitingAdmin ? 'Захиалга бүртгэгдлээ' : 'Амжилттай!';
    final subtitle = awaitingAdmin
        ? 'Оператор таны гүйлгээг шалгаад баталгаажуултал та түр хүлээнэ үү. Явцыг доорх «Явцыг харах» эсвэл «Түүх» табаас дагана уу.'
        : null;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 40),
        Center(
          child: Container(
            width: 80,
            height: 80,
            decoration:
                BoxDecoration(color: iconBg, shape: BoxShape.circle),
            child: Icon(iconData, color: accent, size: 48),
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: Text(
            title,
            style: GoogleFonts.montserrat(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 26,
            ),
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              subtitle,
              textAlign: TextAlign.center,
              style: GoogleFonts.notoSans(
                color: Colors.white60,
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ),
        ] else ...[
          const SizedBox(height: 8),
          Center(
            child: Text(
              '${_fmtTotal()} → ${_fmtConv()}',
              textAlign: TextAlign.center,
              style:
                  GoogleFonts.notoSans(color: Colors.white38, fontSize: 14),
            ),
          ),
        ],
        const SizedBox(height: 32),
        MSCard(
          child: Column(
            children: _dir == 'eu_to_mn'
                ? [
                    _sr('Нийт төлсөн ($_cur)', _fmtTotal()),
                    _sr('Монгол дансанд очих', _fmtConv()),
                    _sr('+ Шимтгэл',
                        '$_sym${_fee.toStringAsFixed(2)} $_cur'),
                    _sr(
                        'Ханш',
                        '1 $_cur = ₮ ${fmtMnt(_rate)}',
                        last: true),
                  ]
                : [
                    _sr('Хүлээн авах дүн', _fmtConv()),
                    _sr('+ Шимтгэл',
                        '$_sym${_fee.toStringAsFixed(2)} EUR'),
                    _sr(
                        'Ханш',
                        '1 EUR = ₮ ${fmtMnt(_rate)}'),
                    _sr('Та нийт төлсөн', _fmtTotal(), last: true),
                  ],
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: awaitingAdmin
                ? kYellow.withOpacity(0.07)
                : kYellow.withOpacity(0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: awaitingAdmin
                  ? kYellow.withOpacity(0.45)
                  : kYellow.withOpacity(0.3),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                awaitingAdmin ? Icons.info_outline_rounded : Icons.track_changes_rounded,
                color: kYellow,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  awaitingAdmin
                      ? 'Оператор таны гүйлгээг шалгаад баталгаажуултал та түр хүлээнэ үү.'
                      : 'Гүйлгээний явцыг «Түүх» хэсгээс харна уу.',
                  style: GoogleFonts.notoSans(color: kYellow, fontSize: 13, height: 1.35),
                ),
              ),
            ],
          ),
        ),
        if (awaitingAdmin &&
            _successLinkedTx != null &&
            _successLinkedTx!.referenceCode.isNotEmpty &&
            !_successLinkedTx!.userDeclaredBankSepaSent) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange.withOpacity(0.35)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.account_balance_rounded,
                    color: Colors.orange, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Банкны аппаас EUR шилжүүлсэн бол «Явцыг харах (Tracking)» дээр орж «Би банкны аппаар EUR шилжүүлж дууслаа» гэж дарна уу. '
                    'Энэ нь манай Revolut дансанд EUR орсон гэдгийг батлахгүй — зөвхөн танд сануулах тэмдэглэл.',
                    style: GoogleFonts.notoSans(
                        color: Colors.white70, fontSize: 12, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (awaitingAdmin &&
            _successLinkedTx != null &&
            txFlowDir(_successLinkedTx!) == 'mn_to_eu' &&
            (_successLinkedTx!.payId == 'mn_manuel' ||
                _successLinkedTx!.payId == 'golomt') &&
            !_successLinkedTx!.userDeclaredMntBankSent) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1B3D2A).withOpacity(0.45),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF81C784).withOpacity(0.35)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.payments_rounded,
                    color: Color(0xFF81C784), size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Манай Хаан банкны данс руу ₮ шилжүүлж дууссан бол «Явцыг харах (Tracking)» дээр орж «₮ - Шилжсэн. Хүсэлт илгээх.» гэж дарна уу. '
                    'Энэ нь ₮ орлого орсон гэдгийг батлахгүй — оператор банкны баримтаар шалгана.',
                    style: GoogleFonts.notoSans(
                        color: Colors.white70, fontSize: 12, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (_successLinkedTx != null) ...[
          const SizedBox(height: 16),
          _PBtn(
            label: 'Явцыг харах (Tracking)',
            onTap: () {
              final tx = _successLinkedTx!;
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => TrackingScreen(tx: tx, onRepeat: null),
                ),
              );
            },
          ),
        ],
        const SizedBox(height: 20),
        _PBtn(
          label: 'Дахин шилжүүлэх',
          onTap: () => setState(() {
            _sent = false;
            _successLinkedTx = null;
            _aC.clear();
            _dC.clear();
            _nC.clear();
            _refC.clear();
            _aml = false;
            _amlSource = null;
            _saveAcc = false;
            _threeInstall = false;
            _selectedSaved = null;
            _lookedUpName = null;
            _lookupError = null;
            _accountFound = false;
            _showBankInfo = false;
            _reverseMode = false;
          }),
        ),
      ],
    );
  }

  Widget _sr(String l,String v,{bool last=false})=>Column(children:[
    Padding(padding:const EdgeInsets.symmetric(vertical:10),child:Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
      Text(l,style:GoogleFonts.notoSans(color:Colors.white38,fontSize:13)),
      Text(v,style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w600,fontSize:13)),
    ])),
    if(!last) const Divider(color:kBorder,height:1),
  ]);
}

// ─── HISTORY ─────────────────────────────────────────────────────
class HistoryScreen extends StatelessWidget {
  final List<TxRecord> history;
  final void Function(TxRecord) onRepeat;
  const HistoryScreen({super.key,required this.history,required this.onRepeat});
  @override Widget build(BuildContext context)=>Column(children:[
    const AppHeader(),
    Expanded(child:ListView(padding:const EdgeInsets.all(20),children:[
      Text('Гүйлгээний түүх',style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w800,fontSize:20)),
      const SizedBox(height:16),
      if(history.isEmpty) Center(child:Padding(padding:const EdgeInsets.all(40),child:Column(children:[
        const Text('📭',style:TextStyle(fontSize:48)),const SizedBox(height:16),
        Text('Гүйлгээ байхгүй байна',style:GoogleFonts.notoSans(color:Colors.white24,fontSize:14)),
      ]))),
      ...history.map((tx)=>_TxHistCard(tx:tx,onRepeat:onRepeat)).toList(),
    ])),
  ]);
}

class _TxHistCard extends StatelessWidget {
  final TxRecord tx;
  final void Function(TxRecord) onRepeat;
  const _TxHistCard({required this.tx, required this.onRepeat});
  @override Widget build(BuildContext context)=>GestureDetector(
      onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>TrackingScreen(tx:tx,onRepeat:onRepeat))),
      child:Container(margin:const EdgeInsets.only(bottom:12),padding:const EdgeInsets.all(16),
          decoration:BoxDecoration(color:kCard,borderRadius:BorderRadius.circular(16),
              border:Border.all(color:tx.isCompleted?kBorder:kYellow.withOpacity(0.4))),
          child:Column(children:[
            Row(children:[
              Container(width:44,height:44,decoration:BoxDecoration(
                  color:tx.isCompleted?kGreen.withOpacity(0.1):kYellow.withOpacity(0.1),borderRadius:BorderRadius.circular(12)),
                  child:Icon(tx.currentStep.icon,color:tx.isCompleted?kGreen:kYellow,size:22)),
              const SizedBox(width:12),
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text('${tx.from} → ${tx.to}',style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w700,fontSize:14)),
                Text(tx.date,style:GoogleFonts.notoSans(color:Colors.white38,fontSize:11)),
              ])),
              Column(crossAxisAlignment:CrossAxisAlignment.end,children:[
                Text(txListPrimaryAmt(tx),style:GoogleFonts.notoSans(color:kYellow,fontWeight:FontWeight.w800,fontSize:14)),
                Text(txListSecondaryAmt(tx),style:GoogleFonts.notoSans(color:Colors.white38,fontSize:11)),
              ]),
            ]),
            const SizedBox(height:12),
            Row(children:List.generate(TxStep.values.length,(i){
              final done=i<=tx.stepIndex;
              return Expanded(child:Container(height:3,
                  margin:EdgeInsets.only(right:i<TxStep.values.length-1?3:0),
                  decoration:BoxDecoration(color:done?(tx.isCompleted?kGreen:kYellow):kBorder,borderRadius:BorderRadius.circular(2))));
            })),
            const SizedBox(height:8),
            Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
              Row(children:[
                Container(width:8,height:8,decoration:BoxDecoration(color:tx.isCompleted?kGreen:kYellow,shape:BoxShape.circle)),
                const SizedBox(width:6),
                Text(tx.currentStep.labelFor(txFlowDir(tx)),style:GoogleFonts.notoSans(color:tx.isCompleted?kGreen:kYellow,fontWeight:FontWeight.w600,fontSize:12)),
              ]),
              GestureDetector(
                onTap:() { Navigator.pop(context); onRepeat(tx); },
                child:Container(
                  padding:const EdgeInsets.symmetric(horizontal:12,vertical:5),
                  decoration:BoxDecoration(color:kYellow.withOpacity(0.12),borderRadius:BorderRadius.circular(8),border:Border.all(color:kYellow.withOpacity(0.4))),
                  child:Row(mainAxisSize:MainAxisSize.min,children:[
                    const Icon(Icons.repeat_rounded,color:kYellow,size:13),
                    const SizedBox(width:5),
                    Text('Дахин шилжүүлэх',style:GoogleFonts.notoSans(color:kYellow,fontWeight:FontWeight.w700,fontSize:11)),
                  ])),
              ),
            ]),
          ])));
}

// ─── TRACKING ────────────────────────────────────────────────────
class TrackingScreen extends StatefulWidget {
  final TxRecord tx;
  final void Function(TxRecord)? onRepeat;
  const TrackingScreen({super.key,required this.tx,this.onRepeat});
  @override State<TrackingScreen> createState()=>_TrackState();
}
class _TrackState extends State<TrackingScreen> {
  @override void initState(){super.initState();_poll();}
  void _poll(){Future.doWhile(()async{
    await Future.delayed(const Duration(seconds:2));
    if(!mounted) return false;
    setState((){});
    return !widget.tx.isCompleted;
  });}

  @override Widget build(BuildContext context)=>Scaffold(
      backgroundColor:kBg,
      appBar:AppBar(backgroundColor:kBg,elevation:0,
          leading:IconButton(icon:const Icon(Icons.arrow_back_ios,color:kYellow),onPressed:()=>Navigator.pop(context)),
          title:RichText(text:TextSpan(children:[
            TextSpan(text:'Money',style:GoogleFonts.imperialScript(color:Colors.white,fontWeight:FontWeight.w700,fontSize:22)),
            TextSpan(text:'SENT',style:GoogleFonts.montserrat(color:Colors.white,fontWeight:FontWeight.w900,fontSize:16,letterSpacing:1)),
          ])),
          centerTitle:true,
          actions:[
            if(widget.onRepeat!=null)
              Padding(padding:const EdgeInsets.only(right:16),
                  child:GestureDetector(
                      onTap:(){
                        Navigator.of(context).popUntil((r)=>r.isFirst);
                        widget.onRepeat!(widget.tx);
                      },
                      child:Container(padding:const EdgeInsets.symmetric(horizontal:12,vertical:6),
                          decoration:BoxDecoration(color:kYellow.withOpacity(0.1),borderRadius:BorderRadius.circular(8),border:Border.all(color:kYellow.withOpacity(0.4))),
                          child:Row(mainAxisSize:MainAxisSize.min,children:[
                            const Icon(Icons.repeat_rounded,color:kYellow,size:14),
                            const SizedBox(width:5),
                            Text('Дахин',style:GoogleFonts.notoSans(color:kYellow,fontWeight:FontWeight.w700,fontSize:12)),
                          ])))),
          ]),
      body:ListView(padding:const EdgeInsets.all(20),children:[
        Container(padding:const EdgeInsets.all(24),
            decoration:BoxDecoration(
                gradient:LinearGradient(begin:Alignment.topLeft,end:Alignment.bottomRight,
                    colors:[kYellow.withOpacity(0.12),kYellow.withOpacity(0.04)]),
                borderRadius:BorderRadius.circular(20),border:Border.all(color:kYellow.withOpacity(0.25))),
            child:Column(children:[
              Text(widget.tx.isCompleted?'✅':'⏳',style:const TextStyle(fontSize:44)),
              const SizedBox(height:12),
              Text(txHeroPrimary(widget.tx),
                  style:GoogleFonts.montserrat(color:Colors.white,fontWeight:FontWeight.w900,fontSize:32)),
              const SizedBox(height:4),
              Text(txHeroSecondary(widget.tx),style:GoogleFonts.notoSans(color:kYellow,fontWeight:FontWeight.w700,fontSize:18)),
              const SizedBox(height:12),
              Container(padding:const EdgeInsets.symmetric(horizontal:16,vertical:6),
                  decoration:BoxDecoration(color:widget.tx.isCompleted?kGreen.withOpacity(0.15):kYellow.withOpacity(0.1),borderRadius:BorderRadius.circular(20)),
                  child:Text(widget.tx.currentStep.labelFor(txFlowDir(widget.tx)),style:GoogleFonts.notoSans(
                      color:widget.tx.isCompleted?kGreen:kYellow,fontWeight:FontWeight.w700,fontSize:13))),
            ])),
        const SizedBox(height:20),
        MSCard(child:Column(children:[
          _ir('Гүйлгээний ID','#${widget.tx.id.substring(widget.tx.id.length-6)}'),
          _ir('Огноо',widget.tx.date),
          if (widget.tx.referenceCode.isNotEmpty) ...[
            _ir('Reference код', widget.tx.referenceCode),
            _ir(
                'Төлбөрийн горим',
                txFlowDir(widget.tx) == 'eu_to_mn'
                    ? 'EUR reference (SEPA → MN)'
                    : '₮ Хаан данс / MoneySENT'),
          ],
          _ir('Шимтгэл','${widget.tx.fee.toStringAsFixed(2)} ${widget.tx.currency}'),
          if(widget.tx.destAccount!=null)
            _ir('Хүлээн авах данс',savedAccountDisplayNo(widget.tx.destAccount!.accountNo),last:true)
          else _ir('Хүлээн авах', txReceiveSummaryLine(widget.tx), last:true),
        ])),
        if (!widget.tx.isCompleted &&
            txFlowDir(widget.tx) == 'eu_to_mn' &&
            widget.tx.referenceCode.isNotEmpty) ...[
          const SizedBox(height: 20),
          MSCard(
            color: const Color(0xFF151A22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'EUR манай дансанд орсон эсэх',
                  style: GoogleFonts.notoSans(
                      color: const Color(0xFF00B9FF),
                      fontWeight: FontWeight.w800,
                      fontSize: 13),
                ),
                const SizedBox(height: 8),
                Text(
                  'Апп автоматаар Revolut дээр EUR орсон эсэхийг шалгахгүй. Банкныхаа аппаар SEPA шилжүүлгээ хийж дууссаны дараа доорх товчийг дарж мэдэгдэнэ үү.',
                  style: GoogleFonts.notoSans(
                      color: Colors.white54, fontSize: 12, height: 1.45),
                ),
                const SizedBox(height: 12),
                if (!widget.tx.userDeclaredBankSepaSent)
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        setState(() => widget.tx.userDeclaredBankSepaSent = true);
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          behavior: SnackBarBehavior.floating,
                          backgroundColor: const Color(0xFF2A2A2A),
                          content: Text(
                            'Бүртгэгдлээ. EUR орсон эсэхийг оператор шалгана.',
                            style:
                                GoogleFonts.notoSans(fontSize: 13, height: 1.35),
                          ),
                        ));
                      },
                      icon: const Icon(Icons.account_balance_rounded,
                          color: kYellow, size: 20),
                      label: Text(
                        'Би банкны аппаар EUR шилжүүлж дууслаа',
                        style: GoogleFonts.notoSans(
                            color: kYellow,
                            fontWeight: FontWeight.w700,
                            fontSize: 13),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: kYellow,
                        side: const BorderSide(color: kYellow),
                        padding: const EdgeInsets.symmetric(
                            vertical: 14, horizontal: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  )
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.check_circle_rounded,
                          color: kGreen, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Банкны аппаар шилжүүлж дууссанаа мэдэгдсэн. Энэ нь EUR манай дансанд орсон гэдгийг батлахгүй.',
                          style: GoogleFonts.notoSans(
                              color: Colors.white70,
                              fontSize: 12,
                              height: 1.4),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
        if (!widget.tx.isCompleted &&
            txFlowDir(widget.tx) == 'mn_to_eu' &&
            (widget.tx.payId == 'mn_manuel' ||
                widget.tx.payId == 'golomt')) ...[
          const SizedBox(height: 20),
          MSCard(
            color: const Color(0xFF151A18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '₮ манай Хаан дансанд шилжүүлсэн эсэх',
                  style: GoogleFonts.notoSans(
                      color: const Color(0xFF81C784),
                      fontWeight: FontWeight.w800,
                      fontSize: 13),
                ),
                const SizedBox(height: 8),
                Text(
                  'Банкны аппаараа (жишээ нь Голомт) шилжүүлэг хийж дууссаны дараа доорх товчоор мэдэгдэнэ үү. Оператор бодит ₮ орлогыг батална.',
                  style: GoogleFonts.notoSans(
                      color: Colors.white54, fontSize: 12, height: 1.45),
                ),
                const SizedBox(height: 12),
                if (!widget.tx.userDeclaredMntBankSent)
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        setState(() => widget.tx.userDeclaredMntBankSent = true);
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          behavior: SnackBarBehavior.floating,
                          backgroundColor: const Color(0xFF2A2A2A),
                          content: Text(
                            'Бүртгэгдлээ. ₮ орлогыг оператор шалгана.',
                            style:
                                GoogleFonts.notoSans(fontSize: 13, height: 1.35),
                          ),
                        ));
                      },
                      icon: const Icon(Icons.payments_rounded,
                          color: kYellow, size: 20),
                      label: Text(
                        '₮ - Шилжсэн. Хүсэлт илгээх.',
                        style: GoogleFonts.notoSans(
                            color: kYellow,
                            fontWeight: FontWeight.w700,
                            fontSize: 13),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: kYellow,
                        side: const BorderSide(color: kYellow),
                        padding: const EdgeInsets.symmetric(
                            vertical: 14, horizontal: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  )
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.check_circle_rounded,
                          color: kGreen, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Хүсэлт илгээгдлээ. Энэ нь манай дансанд ₮ орсон гэдгийг батлахгүй.',
                          style: GoogleFonts.notoSans(
                              color: Colors.white70,
                              fontSize: 12,
                              height: 1.4),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height:20),
        Text('Мөнгөний явц',style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w800,fontSize:18)),
        const SizedBox(height:16),
        ...List.generate(TxStep.values.length,(i){
          final step=TxStep.values[i];
          final done=i<widget.tx.stepIndex;
          final active=i==widget.tx.stepIndex;
          final pend=i>widget.tx.stepIndex;
          final last=i==TxStep.values.length-1;
          final stepTime=widget.tx.stepHistory.where((e)=>e.key==step).isNotEmpty
              ?DateFormat('HH:mm').format(widget.tx.stepHistory.firstWhere((e)=>e.key==step).value)
              :null;
          return Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Column(children:[
              Container(width:46,height:46,decoration:BoxDecoration(
                  color:done?kGreen.withOpacity(0.12):active?kYellow.withOpacity(0.12):const Color(0xFF111111),
                  shape:BoxShape.circle,
                  border:Border.all(color:done?kGreen:active?kYellow:kBorder,width:active?2:1)),
                  child:active&&!widget.tx.isCompleted?_PulseIcon(step.icon,kYellow):Icon(step.icon,
                      color:done?kGreen:active?kYellow:const Color(0xFF333333),size:20)),
              if(!last) Container(width:2,height:42,color:done?kGreen.withOpacity(0.3):kBorder),
            ]),
            const SizedBox(width:16),
            Expanded(child:Padding(padding:EdgeInsets.only(bottom:last?0:28,top:10),
                child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                  Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
                    Text(step.labelFor(txFlowDir(widget.tx)),style:GoogleFonts.notoSans(
                        color:done?kGreen:active?Colors.white:const Color(0xFF333333),
                        fontWeight:active?FontWeight.w800:FontWeight.w600,fontSize:14)),
                    stepTime!=null?Text(stepTime,style:GoogleFonts.notoSans(color:done?kGreen:kYellow,fontSize:12,fontWeight:FontWeight.w600)):
                    pend?Text(step.eta,style:GoogleFonts.notoSans(color:const Color(0xFF333333),fontSize:11)):const SizedBox(),
                  ]),
                  const SizedBox(height:3),
                  Text(step.descFor(txFlowDir(widget.tx)),style:GoogleFonts.notoSans(color:pend?const Color(0xFF333333):Colors.white38,fontSize:12)),
                  if(active&&!widget.tx.isCompleted&&step!=TxStep.awaiting_admin_confirm)...[const SizedBox(height:8),_LoadingDots()],
                ]))),
          ]);
        }),
        const SizedBox(height:20),
        if(widget.tx.isCompleted) Container(padding:const EdgeInsets.all(16),
            decoration:BoxDecoration(color:kGreen.withOpacity(0.08),borderRadius:BorderRadius.circular(14),border:Border.all(color:kGreen.withOpacity(0.25))),
            child:Row(children:[
              const Text('🎉',style:TextStyle(fontSize:28)),const SizedBox(width:12),
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text('Амжилттай хүргэгдлээ!',style:GoogleFonts.notoSans(color:kGreen,fontWeight:FontWeight.w800,fontSize:15)),
                Text(txCompletedBanner(widget.tx),style:GoogleFonts.notoSans(color:Colors.white38,fontSize:13)),
              ])),
            ])),
      ]));

  Widget _ir(String l,String v,{bool last=false})=>Column(children:[
    Padding(padding:const EdgeInsets.symmetric(vertical:10),child:Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
      Text(l,style:GoogleFonts.notoSans(color:Colors.white38,fontSize:13)),
      Text(v,style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w600,fontSize:13)),
    ])),
    if(!last) const Divider(color:kBorder,height:1),
  ]);
}

// ─── RATES ───────────────────────────────────────────────────────
class RatesScreen extends StatefulWidget {
  const RatesScreen({super.key});
  @override State<RatesScreen> createState()=>_RatesState();
}
class _RatesState extends State<RatesScreen> {
  bool _load=false;

  @override
  void initState() {
    super.initState();
    RateService.onRatesUpdated = () { if (mounted) setState(() {}); };
  }

  @override
  void dispose() {
    if (RateService.onRatesUpdated != null) RateService.onRatesUpdated = null;
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(()=>_load=true);
    await RateService.fetch();
    if(mounted) setState(()=>_load=false);
  }

  @override
  Widget build(BuildContext context) {
    final curs = ['USD','EUR','JPY','CHF','GBP','HKD','CNY','KRW','CAD','AUD','CZK'];
    final flags = {'USD':'🇺🇸','EUR':'🇪🇺','JPY':'🇯🇵','CHF':'🇨🇭','GBP':'🇬🇧',
      'HKD':'🇭🇰','CNY':'🇨🇳','KRW':'🇰🇷','CAD':'🇨🇦','AUD':'🇦🇺','CZK':'🇨🇿'};
    return Column(children:[
      const AppHeader(),
      Expanded(child:RefreshIndicator(color:kYellow, onRefresh:_refresh,
          child:ListView(padding:const EdgeInsets.all(20), children:[
            Row(mainAxisAlignment:MainAxisAlignment.spaceBetween, children:[
              Text('Валютын ханш',style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w800,fontSize:20)),
              GestureDetector(onTap:_refresh,child:Container(padding:const EdgeInsets.all(8),
                  decoration:BoxDecoration(color:kCard,borderRadius:BorderRadius.circular(10),border:Border.all(color:kBorder)),
                  child:Icon(_load?Icons.hourglass_top_rounded:Icons.refresh_rounded,color:kYellow,size:18))),
            ]),
            const SizedBox(height:4),
            Row(children:[
              Expanded(child:Text('Хаан Банк бэлэн ханш · 5 минут тутам автомат',
                  style:GoogleFonts.notoSans(color:Colors.white24,fontSize:11))),
              Text('Шинэчлэгдсэн: ${RateService.lastUpdated}',
                  style:GoogleFonts.notoSans(color:Colors.white38,fontSize:11,fontWeight:FontWeight.w600)),
            ]),
            const SizedBox(height:16),
            Container(padding:const EdgeInsets.symmetric(horizontal:16,vertical:10),
                decoration:BoxDecoration(color:kYellow.withOpacity(0.08),borderRadius:BorderRadius.circular(10)),
                child:Row(children:[
                  const Expanded(flex:2,child:SizedBox()),
                  Expanded(child:Text('Авах ₮',style:GoogleFonts.notoSans(color:kGreen,fontWeight:FontWeight.w700,fontSize:12),textAlign:TextAlign.center)),
                  Expanded(child:Text('Зарах ₮',style:GoogleFonts.notoSans(color:kRed,fontWeight:FontWeight.w700,fontSize:12),textAlign:TextAlign.center)),
                ])),
            const SizedBox(height:8),
            for(final c in curs)
              MSCard(child:Row(children:[
                Text(flags[c]??'',style:const TextStyle(fontSize:26)),
                const SizedBox(width:12),
                Expanded(flex:2,child:Text(c,style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w700,fontSize:16))),
                Expanded(child:Text(
                    RateService.buyRates[c] != null ? fmtMnt(RateService.buyRates[c]!) : '—',
                    style:GoogleFonts.notoSans(color:kGreen,fontWeight:FontWeight.w700,fontSize:13),textAlign:TextAlign.center)),
                Expanded(child:Text(
                    RateService.sellRates[c] != null ? fmtMnt(RateService.sellRates[c]!) : '—',
                    style:GoogleFonts.notoSans(color:kRed,fontWeight:FontWeight.w700,fontSize:13),textAlign:TextAlign.center)),
              ])),
            const SizedBox(height:8),
            Text('* Хаан Банк api.khanbank.com — бэлэн: cashBuyRate / cashSellRate. Сүлжээ байхгүй үед fallback.',style:GoogleFonts.notoSans(color:Colors.white24,fontSize:11)),
            const SizedBox(height:16),
            // Ханшийн хүсэлт
            GestureDetector(
                onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const RateRequestScreen())),
                child:MSCard(color:kCard2,child:Row(children:[
                  Container(padding:const EdgeInsets.all(10),
                      decoration:BoxDecoration(color:kGreen.withOpacity(0.12),borderRadius:BorderRadius.circular(12)),
                      child:const Icon(Icons.mail_outline_rounded,color:kGreen,size:22)),
                  const SizedBox(width:12),
                  Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                    Text('Ханшийн хүсэлт / хэлцэл',style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w700,fontSize:14)),
                    Text('Тусдаа дэлгэцэд имэйл илгээнэ',style:GoogleFonts.notoSans(color:Colors.white38,fontSize:11)),
                  ])),
                  const Icon(Icons.arrow_forward_ios,color:Color(0xFF444444),size:14),
                ]))),
          ]))),
    ]);
  }
}

// ─── CONTACT ─────────────────────────────────────────────────────
class ContactScreen extends StatelessWidget {
  const ContactScreen({super.key});
  Future<void> _wa() async{final u=Uri.parse('https://wa.me/97694963509');if(await canLaunchUrl(u))await launchUrl(u,mode:LaunchMode.externalApplication);}
  Future<void> _email() async{final u=Uri.parse('mailto:topfiles999@gmail.com?subject=MoneySENT%20-%20Хүсэлт');if(await canLaunchUrl(u))await launchUrl(u);}
  Future<void> _call() async{final u=Uri.parse('tel:+97694963509');if(await canLaunchUrl(u))await launchUrl(u);}

  @override Widget build(BuildContext context)=>Column(children:[const AppHeader(),
    Expanded(child:ListView(padding:const EdgeInsets.all(20),children:[
      Text('Холбоо барих',style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w800,fontSize:20)),
      const SizedBox(height:16),
      _cc(Icons.phone_rounded,'Утас','+976 9496 3509',kGreen,_call,false),
      _cc(Icons.chat_rounded,'WhatsApp','Шууд холбогдох',const Color(0xFF25D366),_wa,true),
      _cc(Icons.email_rounded,'Имэйл','topfiles999@gmail.com',kPurple,_email,false),
      _cc(Icons.facebook_rounded,'Facebook','MoneySENT',const Color(0xFF1877F2),(){},false),
      const SizedBox(height:16),
      Container(padding:const EdgeInsets.all(16),
          decoration:BoxDecoration(color:kYellow.withOpacity(0.06),borderRadius:BorderRadius.circular(14),border:Border.all(color:kYellow.withOpacity(0.25))),
          child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text('⚡ Ажлын цаг',style:GoogleFonts.notoSans(color:kYellow,fontWeight:FontWeight.w700,fontSize:14)),
            const SizedBox(height:10),
            _hr('Даваа – Баасан','09:00 – 18:00'),
            _hr('Бямба','10:00 – 14:00'),
            _hr('Ням','Амарна'),
          ])),
      const SizedBox(height:16),
      const _FeedbackForm(),
      const SizedBox(height:16),
      MSCard(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        RichText(text:TextSpan(children:[
          TextSpan(text:'Money',style:GoogleFonts.imperialScript(color:kYellow,fontWeight:FontWeight.w700,fontSize:22)),
          TextSpan(text:'SENT',style:GoogleFonts.montserrat(color:kYellow,fontWeight:FontWeight.w900,fontSize:16,letterSpacing:1)),
        ])),
        const SizedBox(height:6),
        Text('PROMON Solution · topfiles999@gmail.com',style:GoogleFonts.notoSans(color:Colors.white38,fontSize:12)),
        Text('2017 оноос · 100% итгэлтэй үйлчилгээ',style:GoogleFonts.notoSans(color:Colors.white24,fontSize:11)),
      ])),
    ])),
  ]);

  Widget _cc(IconData icon,String lbl,String val,Color color,VoidCallback onTap,bool isWa)=>
      GestureDetector(onTap:onTap,child:Container(margin:const EdgeInsets.only(bottom:10),padding:const EdgeInsets.all(16),
          decoration:BoxDecoration(color:kCard,borderRadius:BorderRadius.circular(16),border:Border.all(color:kBorder)),
          child:Row(children:[
            Container(width:42,height:42,decoration:BoxDecoration(color:color.withOpacity(0.12),borderRadius:BorderRadius.circular(12)),child:Icon(icon,color:color,size:22)),
            const SizedBox(width:12),
            Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
              Text(lbl,style:GoogleFonts.notoSans(color:Colors.white38,fontSize:11)),
              Text(val,style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w600,fontSize:14)),
            ])),
            isWa?Container(padding:const EdgeInsets.symmetric(horizontal:12,vertical:6),
                decoration:BoxDecoration(color:const Color(0xFF25D366),borderRadius:BorderRadius.circular(8)),
                child:Text('Нээх',style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w700,fontSize:12))):
            const Icon(Icons.arrow_forward_ios,color:Color(0xFF444444),size:14),
          ])));

  Widget _hr(String d,String t)=>Padding(padding:const EdgeInsets.only(bottom:6),child:Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
    Text(d,style:GoogleFonts.notoSans(color:Colors.white38,fontSize:13)),
    Text(t,style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w600,fontSize:13)),
  ]));
}

class _FeedbackForm extends StatefulWidget {
  const _FeedbackForm();
  @override State<_FeedbackForm> createState()=>_FeedbackFormState();
}
class _FeedbackFormState extends State<_FeedbackForm> {
  final _n=TextEditingController(),_m=TextEditingController(); bool _sent=false;
  Future<void> _send()async{
    if(_n.text.isEmpty||_m.text.isEmpty)return;
    final u=Uri.parse('mailto:topfiles999@gmail.com?subject=MoneySENT%20-%20${Uri.encodeComponent(_n.text)}&body=${Uri.encodeComponent(_m.text)}');
    if(await canLaunchUrl(u)){await launchUrl(u);setState(()=>_sent=true);}
  }
  Widget _f(TextEditingController c,String h,int lines)=>TextField(controller:c,maxLines:lines,
      style:GoogleFonts.notoSans(color:Colors.white,fontSize:14),
      decoration:InputDecoration(hintText:h,hintStyle:GoogleFonts.notoSans(color:Colors.white24),
          filled:true,fillColor:const Color(0xFF111111),
          border:OutlineInputBorder(borderRadius:BorderRadius.circular(10),borderSide:const BorderSide(color:kBorder)),
          enabledBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(10),borderSide:const BorderSide(color:kBorder)),
          focusedBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(10),borderSide:const BorderSide(color:kYellow))));
  @override Widget build(BuildContext context){
    if(_sent)return MSCard(child:Column(children:[const Text('✅',style:TextStyle(fontSize:36)),const SizedBox(height:8),
      Text('Санал хүсэлт илгээгдлээ!',style:GoogleFonts.notoSans(color:kGreen,fontWeight:FontWeight.w700))]));
    return MSCard(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text('Санал хүсэлт',style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w700,fontSize:16)),
      const SizedBox(height:14),_f(_n,'Таны нэр',1),const SizedBox(height:10),_f(_m,'Санал хүсэлт...',4),
      const SizedBox(height:14),_PBtn(label:'Илгээх',onTap:_send),
    ]));
  }
}

// ─── PROFILE SCREEN ───────────────────────────────────────────────
class ProfileScreen extends StatefulWidget {
  final List<TxRecord> history;
  const ProfileScreen({super.key, required this.history});
  @override State<ProfileScreen> createState() => _ProfileState();
}

class _ProfileState extends State<ProfileScreen> {
  late final _nameCtrl   = TextEditingController(text: UserStore.name);
  late final _emailCtrl  = TextEditingController(text: UserStore.email);
  late final _phoneDECtrl = TextEditingController(text: UserStore.phoneDE);
  late final _phoneMNCtrl = TextEditingController(text: UserStore.phoneMN);
  late final _streetCtrl = TextEditingController(text: UserStore.addressStreet);
  late final _plzCtrl = TextEditingController(text: UserStore.addressZip);
  late final _cityCtrl = TextEditingController(text: UserStore.addressCity);
  bool _bioAvailable = false;

  bool get _googleDisplayNameLocked => UserStore.loginType == 'google';

  @override
  void initState() {
    super.initState();
    UserStore.load().then((_) async {
      if (!mounted) return;
      _nameCtrl.text = UserStore.name;
      _emailCtrl.text = UserStore.email;
      _phoneDECtrl.text = UserStore.phoneDE;
      _phoneMNCtrl.text = UserStore.phoneMN;
      _streetCtrl.text = UserStore.addressStreet;
      _plzCtrl.text = UserStore.addressZip;
      _cityCtrl.text = UserStore.addressCity;
      await RateRequestQueueStore.load();
      if (_wantsGooglePhotoRefresh()) {
        await _fetchGooglePhotoIfNeeded();
      }
      if (mounted) setState(() {});
    });
    VerifyStore.load().then((_) { if (mounted) setState(() {}); });
    AdminStore.load().then((_) { if (mounted) setState(() {}); });
    NotificationPrefsStore.load().then((_) { if (mounted) setState(() {}); });
    BiometricStore.isAvailable().then((v) { if (mounted) setState(() => _bioAvailable = v); });
  }

  /// Жинхэнэ Google profile зураг байхгүй үед зургуй үлдэхийг сэргээнэ.
  bool _wantsGooglePhotoRefresh() {
    if (UserStore.loginType != 'google') return false;
    final u = UserStore.avatarUrl.trim().toLowerCase();
    if (u.isEmpty) return true;
    return !u.contains('googleusercontent.com') && !u.contains('ggpht.com');
  }

  Future<void> _fetchGooglePhotoIfNeeded() async {
    if (!_googleLoginSupportedPlatform()) return;
    try {
      final webClientId = _resolvedGoogleWebClientId();
      final gsi = GoogleSignIn(
        scopes: const ['email', 'profile'],
        serverClientId: webClientId.isEmpty ? null : webClientId,
      );
      await gsi.signInSilently();
      final photo = gsi.currentUser?.photoUrl?.trim() ?? '';
      if (photo.isEmpty || !mounted) return;
      UserStore.avatarUrl = photo;
      await UserStore.save();
      if (!mounted) return;
      setState(() {});
    } catch (_) {}
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneDECtrl.dispose();
    _phoneMNCtrl.dispose();
    _streetCtrl.dispose();
    _plzCtrl.dispose();
    _cityCtrl.dispose();
    super.dispose();
  }

  Future<void> _promptContactOtp(
    BuildContext sheetContext,
    ContactVerifyChannel channel,
    TextEditingController valueCtrl,
    VoidCallback onVerified,
  ) async {
    final otpCtrl = TextEditingController();
    await showModalBottomSheet<void>(
      context: sheetContext,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: StatefulBuilder(
          builder: (ctx2, setS) => Container(
            decoration: const BoxDecoration(
              color: Color(0xFF1C1C1C),
              borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
            ),
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  channel == ContactVerifyChannel.email ? 'Имэйл баталгаа' : 'Утасны баталгаа',
                  style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
                ),
                const SizedBox(height: 6),
                Text(
                  valueCtrl.text.trim().isEmpty ? '(Хаяг оруулна уу)' : valueCtrl.text.trim(),
                  style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12),
                ),
                const SizedBox(height: 14),
                OutlinedButton(
                  onPressed: () async {
                    final r = await ContactVerificationStore.sendOtp(channel, valueCtrl.text);
                    if (!sheetContext.mounted) return;
                    if (r.error != null) {
                      ScaffoldMessenger.of(sheetContext).showSnackBar(
                        SnackBar(behavior: SnackBarBehavior.floating, content: Text(r.error!)),
                      );
                      return;
                    }
                    if (r.fallbackDevCode != null) {
                      await showDialog<void>(
                        context: sheetContext,
                        builder: (dCtx) => AlertDialog(
                          backgroundColor: const Color(0xFF2A2A2A),
                          title: Text('Туршилтын код',
                              style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w700)),
                          content: Text(
                            'Backend (`VERIFY_API_BASE`) тохируулаагүй тул код зөвхөн энэ дэлгэцэд харагдана. Жинхэнэ SMS/имэйл илгээх сервер холбоно уу.\n\nКод: ${r.fallbackDevCode}',
                            style: GoogleFonts.notoSans(color: Colors.white70, fontSize: 13, height: 1.4),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dCtx),
                              child: Text('Ойлголоо', style: GoogleFonts.notoSans(color: kYellow)),
                            ),
                          ],
                        ),
                      );
                    } else {
                      ScaffoldMessenger.of(sheetContext).showSnackBar(
                        SnackBar(
                          behavior: SnackBarBehavior.floating,
                          content: Text(
                            'Код илгээгдлээ. Имэйл эсвэл SMS шалгана уу.',
                            style: GoogleFonts.notoSans(),
                          ),
                        ),
                      );
                    }
                    setS(() {});
                  },
                  style: OutlinedButton.styleFrom(
                      foregroundColor: kYellow,
                      side: const BorderSide(color: kYellow)),
                  child: Text('Код авах', style: GoogleFonts.notoSans(fontWeight: FontWeight.w700)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: otpCtrl,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  style: GoogleFonts.notoSans(color: Colors.white, fontSize: 18, letterSpacing: 4),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: '6 оронтой код',
                    hintStyle: GoogleFonts.notoSans(color: Colors.white24),
                    filled: true,
                    fillColor: const Color(0xFF111111),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 14),
                _PBtn(
                  label: 'Баталгаажуулах',
                  onTap: () async {
                    final err = await ContactVerificationStore.verifyOtp(
                      channel,
                      otpCtrl.text,
                      destinationSnapshot: valueCtrl.text,
                    );
                    if (!sheetContext.mounted) return;
                    if (err != null) {
                      ScaffoldMessenger.of(sheetContext).showSnackBar(
                        SnackBar(behavior: SnackBarBehavior.floating, content: Text(err)),
                      );
                      return;
                    }
                    onVerified();
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    otpCtrl.dispose();
  }

  Widget _accountContactRow({
    required IconData icon,
    required String label,
    required TextEditingController ctrl,
    String hint = '',
    TextInputType? keyboardType,
    bool readOnly = false,
    String readOnlyHint = '',
    ContactVerifyChannel? verifyChannel,
    required VoidCallback onRefresh,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.white38, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(label, style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11)),
                    ),
                    if (verifyChannel != null && !readOnly)
                      ContactVerificationStore.isChannelVerified(verifyChannel)
                          ? Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: kGreen.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: kGreen.withOpacity(0.5)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.verified_rounded, color: kGreen, size: 13),
                                  const SizedBox(width: 4),
                                  Text('Баталгаатай',
                                      style: GoogleFonts.notoSans(
                                          color: kGreen, fontWeight: FontWeight.w800, fontSize: 10)),
                                ],
                              ),
                            )
                          : TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () => _promptContactOtp(context, verifyChannel, ctrl, onRefresh),
                              child: Text('Кодоор баталгаах',
                                  style: GoogleFonts.notoSans(
                                      color: kYellow, fontWeight: FontWeight.w700, fontSize: 11)),
                            ),
                  ],
                ),
                TextField(
                  controller: ctrl,
                  readOnly: readOnly,
                  keyboardType: keyboardType,
                  style: GoogleFonts.notoSans(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    hintText: hint,
                    hintStyle: GoogleFonts.notoSans(color: Colors.white24, fontSize: 13),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                ),
                if (readOnly && readOnlyHint.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      readOnlyHint,
                      style: GoogleFonts.notoSans(color: Colors.white24, fontSize: 10, height: 1.25),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Бүртгэл/баталгааны selfie (локал) эсвэл сүлжээний аватар.
  /// Google-ээр нэвтэрсэн бол шар толгойд Google-ийн зургийг эхлээд харуулна.
  Widget _profileHeaderAvatar() {
    Widget fallback() => Container(
          color: kYellow.withOpacity(0.2),
          child: Center(
            child: Text(
              UserStore.name.split(' ').map((w) => w.isNotEmpty ? w[0] : '').take(2).join(),
              style: GoogleFonts.notoSans(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 26),
            ),
          ),
        );

    Widget networkAvatar(String url) => Image.network(
          url,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) {
            if (!kIsWeb && UserStore.localAvatarPath.isNotEmpty) {
              final f = File(UserStore.localAvatarPath);
              if (f.existsSync()) {
                return Image.file(
                  f,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => fallback(),
                );
              }
            }
            return Image.network(
              UserStore.displayAvatar,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => fallback(),
            );
          },
        );

    final googleUrl = UserStore.loginType == 'google' ? UserStore.avatarUrl.trim() : '';
    if (googleUrl.isNotEmpty) {
      return networkAvatar(googleUrl);
    }

    if (!kIsWeb && UserStore.localAvatarPath.isNotEmpty) {
      final f = File(UserStore.localAvatarPath);
      if (f.existsSync()) {
        return Image.file(
          f,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => fallback(),
        );
      }
    }
    return Image.network(
      UserStore.displayAvatar,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => fallback(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final txCount   = widget.history.length;
    final tier      = getMemberTier(txCount);
    final totalMnt  = widget.history.fold<int>(0, (s, t) => s + t.mnt);
    final totalEur  = widget.history.fold<double>(0, (s, t) => s + t.amount);
    final progress  = tier == MemberTier.platinum ? 1.0
        : (txCount - tier.minTx) / (tier.nextTarget - tier.minTx);
    final hideMembershipUi = AdminStore.hasPanelAccess();

    return Scaffold(
      backgroundColor: kBg,
      body: CustomScrollView(slivers: [
        SliverAppBar(
          expandedHeight: 220,
          backgroundColor: kBg,
          pinned: true,
          leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios, color: kYellow),
              onPressed: () => Navigator.pop(context)),
          flexibleSpace: FlexibleSpaceBar(
            background: Container(
              decoration: const BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                      colors: [kYellow, kYellowDeep])),
              child: SafeArea(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const SizedBox(height: 16),
                Stack(alignment: Alignment.bottomRight, children: [
                  Container(width: 76, height: 76,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: VerifyStore.isVerified
                                  ? kGreen
                                  : hideMembershipUi
                                      ? Colors.white.withOpacity(0.65)
                                      : tier.color,
                              width: 3)),
                      child: ClipOval(
                        child: _profileHeaderAvatar(),
                      )),
                  if (VerifyStore.isVerified)
                    Container(width: 26, height: 26,
                        decoration: const BoxDecoration(color: kGreen, shape: BoxShape.circle),
                        child: const Icon(Icons.verified_rounded, color: Colors.white, size: 16))
                  else if (hideMembershipUi)
                    Container(width: 26, height: 26,
                        decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle,
                            border: Border.all(color: Colors.black26, width: 1.2)),
                        child: const Icon(Icons.person_rounded, color: Colors.black45, size: 15))
                  else
                    Container(width: 26, height: 26,
                        decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle,
                            border: Border.all(color: tier.color, width: 1.5)),
                        child: Center(child: Text(tier.icon, style: const TextStyle(fontSize: 14)))),
                ]),
                const SizedBox(height: 8),
                Text(_nameCtrl.text,
                    style: GoogleFonts.notoSans(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 17)),
                const SizedBox(height: 4),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  if (!hideMembershipUi)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(color: tier.color, borderRadius: BorderRadius.circular(20)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(tier.icon, style: const TextStyle(fontSize: 13)),
                        const SizedBox(width: 5),
                        Text('${tier.label} member',
                            style: GoogleFonts.notoSans(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 12)),
                      ]),
                    ),
                  if (VerifyStore.isVerified) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(color: kGreen.withOpacity(0.2), borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: kGreen, width: 1)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.verified_rounded, color: kGreen, size: 13),
                        const SizedBox(width: 4),
                        Text('Verified', style: GoogleFonts.notoSans(color: kGreen, fontWeight: FontWeight.w800, fontSize: 11)),
                      ]),
                    ),
                  ] else if (VerifyStore.isPending) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(color: Colors.orange.withOpacity(0.15), borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.orange, width: 1)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.hourglass_empty_rounded, color: Colors.orange, size: 13),
                        const SizedBox(width: 4),
                        Text('Хүлээгдэж байна', style: GoogleFonts.notoSans(color: Colors.orange, fontWeight: FontWeight.w800, fontSize: 10)),
                      ]),
                    ),
                  ],
                  if (AdminStore.isFullAdmin) ...[
                    if (!hideMembershipUi || VerifyStore.isVerified || VerifyStore.isPending) const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF7C4DFF).withOpacity(0.22),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFF7C4DFF), width: 1)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.admin_panel_settings_rounded, color: Color(0xFF4A148C), size: 13),
                        const SizedBox(width: 4),
                        Text('Admin', style: GoogleFonts.notoSans(color: const Color(0xFF4A148C), fontWeight: FontWeight.w800, fontSize: 11)),
                      ]),
                    ),
                  ] else if (AdminStore.isModeratorOnly) ...[
                    if (!hideMembershipUi || VerifyStore.isVerified || VerifyStore.isPending) const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00BCD4).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFF00838F), width: 1)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.visibility_rounded, color: Color(0xFF006064), size: 13),
                        const SizedBox(width: 4),
                        Text('Модератор', style: GoogleFonts.notoSans(color: const Color(0xFF006064), fontWeight: FontWeight.w800, fontSize: 10)),
                      ]),
                    ),
                  ],
                ]),
                const SizedBox(height: 10),
                Text(
                  'Мөнгөн шилжүүлгийн үйлчилгээ',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.notoSans(
                    color: Colors.black,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.15,
                  ),
                ),
              ])),
            ),
          ),
        ),

        SliverToBoxAdapter(child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

            // ── Member карт (энгийн хэрэглэгчид л) ──
            if (!hideMembershipUi) ...[
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                    gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                        colors: [tier.color.withOpacity(0.18), tier.color.withOpacity(0.05)]),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: tier.color.withOpacity(0.5))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text('${tier.icon} ${tier.label} Member',
                        style: GoogleFonts.notoSans(color: tier.color, fontWeight: FontWeight.w800, fontSize: 15)),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder:(_)=> MemberBenefitScreen(tier: tier, txCount: txCount))),
                      child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: tier.color.withOpacity(0.2), borderRadius: BorderRadius.circular(10)),
                          child: Text('Дэлгэрэнгүй →',
                              style: GoogleFonts.notoSans(color: tier.color, fontWeight: FontWeight.w700, fontSize: 11))),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  Text(tier.benefit, style: GoogleFonts.notoSans(color: Colors.white60, fontSize: 12, height: 1.4)),
                  if (tier != MemberTier.platinum) ...[
                    const SizedBox(height: 12),
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text('$txCount / ${tier.nextTarget} гүйлгээ',
                          style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11)),
                      Text('Дараагийн: ${_nextTierName(tier)}',
                          style: GoogleFonts.notoSans(color: tier.color, fontSize: 11, fontWeight: FontWeight.w700)),
                    ]),
                    const SizedBox(height: 6),
                    ClipRRect(borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                            value: progress.clamp(0.0, 1.0),
                            minHeight: 7,
                            backgroundColor: Colors.white12,
                            valueColor: AlwaysStoppedAnimation(tier.color))),
                  ] else
                    Padding(padding: const EdgeInsets.only(top: 8),
                        child: Text('🏆 Та хамгийн дээд зэрэглэлд хүрлээ!',
                            style: GoogleFonts.notoSans(color: tier.color, fontWeight: FontWeight.w700, fontSize: 12))),
                ]),
              ),
              const SizedBox(height: 16),
            ],

            // ── Тойм ──
            _profileSectionTitle('Тойм', topPad: 0),
            Row(children: [
              _statCard('Гүйлгээ', '$txCount', Icons.send_rounded, kYellow),
              const SizedBox(width: 10),
              _statCard('₮ Нийт', fmtMnt(totalMnt), Icons.account_balance_wallet_rounded, kGreen),
              const SizedBox(width: 10),
              _statCard('€ Нийт', totalEur.toStringAsFixed(0), Icons.euro_rounded, kPurple),
              const SizedBox(width: 10),
              _statCard(
                  'Ханшийн хүсэлт',
                  RateRequestQueueStore.isPending ? '1' : '0',
                  Icons.trending_up_rounded,
                  kBlue),
            ]),
            const SizedBox(height: 8),

            _profileSectionTitle('Бүртгэл'),
            _profileMenuTile(
              icon: Icons.person_rounded,
              title: 'Миний мэдээлэл',
              subtitle: 'Баталгаажуулалт · зээлийн эрхтэй гишүүн',
              color: kYellow,
              onTap: () => _showMyInfo(context).then((_) => setState(() {})),
            ),
            _profileMenuTile(
              icon: Icons.manage_accounts_rounded,
              title: 'Бүртгэл ба тохиргоо',
              subtitle: 'Нэр, утас · түгжээ, мэдэгдэл',
              color: const Color(0xFFFFB347),
              onTap: () => _showAccountSettingsSheet(context).then((_) => setState(() {})),
            ),

            _profileSectionTitle('Нууцлал'),
            if (AdminStore.hasPanelAccess())
              _profileMenuTile(
                icon: Icons.admin_panel_settings_rounded,
                title: 'Админ самбар',
                subtitle: AdminStore.isModeratorOnly
                    ? 'Модератор — баталгаа, хүлээгдэж буй гүйлгээ'
                    : 'Бүрэн админ — whitelist, тохиргоо',
                color: const Color(0xFF7C4DFF),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminGateScreen()))
                    .then((_) async {
                  await AdminStore.load();
                  if (mounted) setState(() {});
                }),
              ),

            _profileSectionTitle('Тусламж ба үйлчилгээ'),
            _profileMenuTile(
              icon: Icons.savings_rounded,
              title: 'Хадгаламж',
              subtitle: 'Хадгаламжийн үйлчилгээний мэдээлэл',
              color: kGreen,
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SavingsInfoScreen())),
            ),
            _profileMenuTile(
              icon: Icons.credit_score_rounded,
              title: 'Зээл',
              subtitle: 'Нөхцөл, зээлийн булан',
              color: kPurple,
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LoanCornerScreen())),
            ),
            if (!hideMembershipUi)
              _profileMenuTile(
                icon: Icons.percent_rounded,
                title: 'Хөнгөлөлт',
                subtitle: 'Зэрэглэлээс хамаарсан хөнгөлөлт',
                color: kBlue,
                onTap: () => _showFeeInfo(context, tier),
              ),
            _profileMenuTile(
              icon: Icons.receipt_long_rounded,
              title: 'Гүйлгээний түүх',
              subtitle: 'Идэвхтэй болон дууссан гүйлгээ',
              color: const Color(0xFFFF9500),
              onTap: () => _showTxHistory(context),
            ),
            _profileMenuTile(
              icon: Icons.trending_up_rounded,
              title: 'Ханш ба хүсэлт',
              subtitle: 'Ханшийн мэдээ, санал хүсэлт илгээх',
              color: kGreen,
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RateRequestScreen()))
                  .then((_) async {
                await RateRequestQueueStore.load();
                if (mounted) setState(() {});
              }),
            ),

            _profileSectionTitle('Гарах'),
            _profileMenuTile(
              icon: Icons.menu_book_rounded,
              title: 'Апп хэрэглэх заавар',
              subtitle: hideMembershipUi ? 'Функцууд' : 'Функцууд, зэрэглэл, аюулгүй байдал',
              color: const Color(0xFF5AC8FA),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AppGuideScreen(historyLen: txCount))),
            ),
            OutlinedButton.icon(
                onPressed: () async {
                  try {
                    await FacebookAuth.instance.logOut();
                  } catch (_) {}
                  await UserStore.clearSession();
                  await AccountStore.load();
                  if (!context.mounted) return;
                  Navigator.of(context).pushAndRemoveUntil(
                    PageRouteBuilder(pageBuilder:(_,a,__)=>const LoginScreen(),
                        transitionsBuilder:(_,a,__,c)=>FadeTransition(opacity:a,child:c)), (_)=>false);
                },
                icon: const Icon(Icons.logout_rounded, color: kRed),
                label: Text('Гарах', style: GoogleFonts.notoSans(color: kRed, fontWeight: FontWeight.w700)),
                style: OutlinedButton.styleFrom(side: const BorderSide(color: kRed),
                    minimumSize: const Size(double.infinity, 50),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)))),
            const SizedBox(height: 30),
          ]),
        )),
      ]),
    );
  }

  Future<void> _openPasscodeMenu() async {
    await PasscodeStore.load();
    if (!mounted) return;
    if (!PasscodeStore.isLockActive) {
      await Navigator.push(
          context,
          MaterialPageRoute<void>(
              builder: (_) => const PasscodeManageScreen(kind: PasscodeManageKind.enable)));
      if (mounted) setState(() {});
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF2C2C2C),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_rounded, color: kYellow),
              title: Text('Passcode солих', style: GoogleFonts.notoSans(color: Colors.white)),
              onTap: () async {
                Navigator.pop(ctx);
                await Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                        builder: (_) => const PasscodeManageScreen(kind: PasscodeManageKind.changePin)));
                if (mounted) setState(() {});
              },
            ),
            ListTile(
              leading: Icon(Icons.lock_open_rounded, color: kRed.withOpacity(0.95)),
              title: Text('Passcode унтраах', style: GoogleFonts.notoSans(color: Colors.white)),
              onTap: () async {
                Navigator.pop(ctx);
                await Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                        builder: (_) => const PasscodeManageScreen(kind: PasscodeManageKind.disable)));
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Face ID нь зөвхөн Passcode түгжээтэй хамт ажиллана (passcodeгүй «зөвхөн биометр» үлдээхгүй).
  Future<void> _setBiometricEnabled(bool newVal) async {
    if (newVal) {
      await PasscodeStore.load();
      if (!mounted) return;
      if (!PasscodeStore.isLockActive) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: kRed,
          content: Text(
            'Face ID ашиглахын өмнө доорх «Passcode»-оор 4 оронтын түгжээ идэвхжүүлнэ үү (энэ хуудаснаас).',
            style: GoogleFonts.notoSans(fontSize: 12.5, height: 1.35),
          ),
        ));
        return;
      }
      final ok = await BiometricStore.authenticate();
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: kRed,
          content: Text('Биометрик шалгалт амжилтгүй', style: GoogleFonts.notoSans()),
        ));
        return;
      }
    }
    await BiometricStore.setEnabled(newVal);
    if (mounted) setState(() {});
  }

  /// «Миний мэдээлэл» доод хуудасны баталгааны мөр (профайлын жагсаалтаас салгасан).
  Widget _myInfoVerifyTile(BuildContext navCtx, VoidCallback refreshSheet) {
    Color col; String label; IconData icon;
    if (VerifyStore.isVerified) {
      col = kGreen; label = 'Баталгаажуулалт ✓'; icon = Icons.verified_rounded;
    } else if (VerifyStore.isPending) {
      col = Colors.orange; label = 'Баталгаажуулалт (хүлээгдэж байна)'; icon = Icons.hourglass_empty_rounded;
    } else {
      col = kYellow; label = 'Баталгаажуулалт'; icon = Icons.verified_user_rounded;
    }
    return GestureDetector(
      onTap: () => Navigator.push(navCtx, MaterialPageRoute(builder: (_) => const VerificationScreen()))
          .then((_) async {
        await VerifyStore.load();
        if (mounted) setState(() {});
        refreshSheet();
      }),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(14),
            border: Border.all(color: VerifyStore.isVerified ? kGreen.withOpacity(0.5) : kBorder)),
        child: Row(children: [
          Container(width: 36, height: 36,
              decoration: BoxDecoration(color: col.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: col, size: 18)),
          const SizedBox(width: 14),
          Expanded(child: Text(label, style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14))),
          const Icon(Icons.arrow_forward_ios_rounded, color: Color(0xFF555555), size: 14),
        ]),
      ),
    );
  }

  /// «Миний мэдээлэл» доод хуудасны зээлийн мөр.
  Widget _myInfoLoanTile(BuildContext navCtx, VoidCallback refreshSheet) {
    final approved = LoanStore.isApproved;
    final pending  = LoanStore.isPending;
    final col = approved ? const Color(0xFF9C27B0)
        : pending ? Colors.orange : Colors.white38;
    final icon = approved ? Icons.credit_score_rounded
        : pending ? Icons.hourglass_top_rounded : Icons.credit_card_rounded;
    final label = approved ? 'Зээлийн эрхтэй гишүүн ✓'
        : pending ? 'Зээлийн хүсэлт (шалгагдаж байна)'
        : 'Зээлийн эрх авах';
    return GestureDetector(
      onTap: () async {
        if (approved) {
          await Navigator.push(navCtx, MaterialPageRoute(builder: (_) => const LoanBalanceScreen()));
        } else if (pending) {
          await showDialog<void>(context: navCtx, builder: (_) => AlertDialog(
            backgroundColor: kCard,
            title: Text('Шалгагдаж байна', style: GoogleFonts.notoSans(color: Colors.white)),
            content: Text(
                'Манай баг таны хүсэлтийг шалгаж байна.\n1–3 ажлын өдрийн дотор хариу өгнө.\n\nЗөвшөөрөл олгогдох үед «Миний мэдээлэл» хэсэгт «Зээлийн эрхтэй гишүүн» төлөв автоматаар шинэчлэгдэнэ.',
                style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 13)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(navCtx),
                  child: Text('OK', style: GoogleFonts.notoSans(color: kYellow))),
            ],
          ));
        } else {
          await Navigator.push(navCtx, MaterialPageRoute(builder: (_) => const LoanCornerScreen()));
        }
        await LoanStore.load();
        if (mounted) setState(() {});
        refreshSheet();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: approved ? col.withOpacity(0.5) : kBorder),
          gradient: approved ? LinearGradient(colors: [
            col.withOpacity(0.08), Colors.transparent]) : null),
        child: Row(children: [
          Container(width: 36, height: 36,
              decoration: BoxDecoration(color: col.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: col, size: 18)),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: GoogleFonts.notoSans(
                color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
            if (approved)
              Text(
                LoanStore.hasOpenLoan
                    ? 'Үлдэгдэл ≈ €${LoanStore.remainingEur.toStringAsFixed(2)} · зээлийн дэлгэрэнгүй'
                    : 'Идэвхтэй зээлийн үлдэгдэл байхгүй · баримт 3 сар тутам шинэчилна',
                style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11),
              ),
          ])),
          const Icon(Icons.arrow_forward_ios_rounded, color: Color(0xFF555555), size: 14),
        ]),
      ),
    );
  }

  String _nextTierName(MemberTier t) {
    switch(t){
      case MemberTier.bronze:   return 'Silver 🥈';
      case MemberTier.silver:   return 'Gold 👑';
      case MemberTier.gold:     return 'Platinum 💎';
      default: return '';
    }
  }

  Widget _profileSectionTitle(String title, {double topPad = 16}) {
    return Padding(
      padding: EdgeInsets.only(top: topPad, bottom: 8),
      child: Text(
        title,
        style: GoogleFonts.notoSans(
          color: Colors.white38,
          fontWeight: FontWeight.w800,
          fontSize: 11.5,
          letterSpacing: 0.65,
        ),
      ),
    );
  }

  Widget _profileMenuTile({
    required IconData icon,
    required String title,
    String? subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder),
        ),
        child: Row(
          crossAxisAlignment: subtitle != null ? CrossAxisAlignment.start : CrossAxisAlignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: subtitle == null
                  ? Text(
                      title,
                      style: GoogleFonts.notoSans(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: GoogleFonts.notoSans(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          style: GoogleFonts.notoSans(
                            color: Colors.white38,
                            fontSize: 11,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
            ),
            Padding(
              padding: EdgeInsets.only(top: subtitle != null ? 2 : 0),
              child: const Icon(Icons.arrow_forward_ios_rounded, color: Color(0xFF555555), size: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statCard(String label, String value, IconData icon, Color color) =>
      Expanded(child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 6),
          Text(value, style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(label, style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 10)),
        ]),
      ));

  Widget _menuItem(IconData icon, String label, Color color, VoidCallback onTap) =>
      GestureDetector(onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: kBorder)),
          child: Row(children: [
            Container(width: 36, height: 36,
                decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, color: color, size: 18)),
            const SizedBox(width: 14),
            Expanded(child: Text(label, style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14))),
            const Icon(Icons.arrow_forward_ios_rounded, color: Color(0xFF555555), size: 14),
          ]),
        ));

  Future<void> _showMyInfo(BuildContext ctx) async {
    await VerifyStore.load();
    await LoanStore.load();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx2, setS) => Container(
          decoration: const BoxDecoration(
              color: Color(0xFF1C1C1C), borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
          padding: EdgeInsets.fromLTRB(20, 12, 20, MediaQuery.of(ctx).viewInsets.bottom + 32),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Center(
                  child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 16),
              Text('Миний мэдээлэл',
                  style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 8),
              Text('Баталгаажуулалт ба зээлийн эрхтэй гишүүн — төлөвийг энд харна.',
                  style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11.5, height: 1.35)),
              const SizedBox(height: 14),
              _myInfoVerifyTile(ctx2, () => setS(() {})),
              _myInfoLoanTile(ctx2, () => setS(() {})),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _showAccountSettingsSheet(BuildContext ctx) async {
    await PasscodeStore.load();
    await NotificationPrefsStore.load();
    await AdminStore.load();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx2, setS) => Container(
          decoration: const BoxDecoration(
              color: Color(0xFF1C1C1C), borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
          padding: EdgeInsets.fromLTRB(20, 12, 20, MediaQuery.of(ctx).viewInsets.bottom + 32),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Center(
                  child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 16),
              Text('Бүртгэл ба тохиргоо',
                  style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 8),
              Text('Нэр, утас, гэрийн хаяг · түгжээ, мэдэгдэл.',
                  style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11.5, height: 1.35)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (AdminStore.isFullAdmin)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFF7C4DFF).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFF7C4DFF).withOpacity(0.55)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.admin_panel_settings_rounded, color: Color(0xFFB388FF), size: 14),
                          const SizedBox(width: 5),
                          Text('Админ',
                              style: GoogleFonts.notoSans(color: const Color(0xFFB388FF), fontWeight: FontWeight.w800, fontSize: 11)),
                        ],
                      ),
                    )
                  else if (AdminStore.isModeratorOnly)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00BCD4).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFF00BCD4).withOpacity(0.55)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.visibility_rounded, color: Color(0xFF4DD0E1), size: 14),
                          const SizedBox(width: 5),
                          Text('Модератор',
                              style: GoogleFonts.notoSans(color: const Color(0xFF4DD0E1), fontWeight: FontWeight.w800, fontSize: 11)),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              _accountContactRow(
                icon: Icons.person_rounded,
                label: 'Нэр',
                ctrl: _nameCtrl,
                readOnly: _googleDisplayNameLocked,
                readOnlyHint: 'Google-ээс авсан — засах боломжгүй',
                onRefresh: () => setS(() {}),
              ),
              _accountContactRow(
                icon: Icons.email_rounded,
                label: 'Имэйл хаяг',
                ctrl: _emailCtrl,
                hint: 'example@gmail.com',
                keyboardType: TextInputType.emailAddress,
                verifyChannel: ContactVerifyChannel.email,
                onRefresh: () => setS(() {}),
              ),
              _accountContactRow(
                icon: Icons.flag_rounded,
                label: 'Германы утас (+49)',
                ctrl: _phoneDECtrl,
                hint: '+49 152 XXXXXXXX',
                keyboardType: TextInputType.phone,
                verifyChannel: ContactVerifyChannel.phoneDE,
                onRefresh: () => setS(() {}),
              ),
              _accountContactRow(
                icon: Icons.phone_rounded,
                label: 'Монгол утас (+976)',
                ctrl: _phoneMNCtrl,
                hint: '+976 99XX XXXX',
                keyboardType: TextInputType.phone,
                verifyChannel: ContactVerifyChannel.phoneMN,
                onRefresh: () => setS(() {}),
              ),
              const SizedBox(height: 6),
              Text('Гэрийн хаяг (Герман)',
                  style:
                      GoogleFonts.notoSans(color: Colors.white54, fontWeight: FontWeight.w800, fontSize: 12)),
              const SizedBox(height: 6),
              _infoRow(Icons.home_work_rounded, 'Straße, Hausnummer', _streetCtrl, hint: 'Жишээ: Musterstraße 12'),
              _infoRow(Icons.markunread_mailbox_rounded, 'PLZ (шуудангийн код)', _plzCtrl,
                  hint: '12345', keyboardType: TextInputType.text),
              _infoRow(Icons.location_city_rounded, 'Stadt (хот)', _cityCtrl, hint: 'Berlin'),
              const Divider(color: Color(0xFF2A2A2A), height: 28),
              Text('Аюулгүй байдал',
                  style:
                      GoogleFonts.notoSans(color: Colors.white54, fontWeight: FontWeight.w800, fontSize: 12)),
              const SizedBox(height: 10),
              if (_bioAvailable)
                _toggleRow(
                  icon: Icons.fingerprint_rounded,
                  label: 'Face ID / Хурууны хээ',
                  sub: 'Апп нээгдэхэд биометрик (Passcode заавал)',
                  color: kYellow,
                  value: BiometricStore.enabled,
                  onChanged: (v) async {
                    await _setBiometricEnabled(v);
                    setS(() {});
                  },
                ),
              Material(
                color: const Color(0xFF111111),
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  onTap: () async {
                    Navigator.pop(ctx);
                    await Future.delayed(const Duration(milliseconds: 120));
                    if (mounted) _openPasscodeMenu();
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF2A2A2A)),
                    ),
                    child: Row(children: [
                      Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                              color: kYellow.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
                          child: const Icon(Icons.pin_outlined, color: kYellow, size: 18)),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Passcode',
                            style: GoogleFonts.notoSans(
                                color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
                        Text(
                            PasscodeStore.isLockActive
                                ? '4 оронтын түгжээ идэвхтэй · солих / унтраах'
                                : 'Тохируулаагүй · идэвхжүүлэх',
                            style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 10, height: 1.3)),
                      ])),
                      const Icon(Icons.chevron_right_rounded, color: Color(0xFF555555), size: 22),
                    ]),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              const Divider(color: Color(0xFF2A2A2A), height: 28),
              Text('Мэдэгдэл',
                  style:
                      GoogleFonts.notoSans(color: Colors.white54, fontWeight: FontWeight.w800, fontSize: 12)),
              const SizedBox(height: 10),
              _toggleRow(
                icon: Icons.notifications_active_rounded,
                label: 'Гүйлгээний мэдэгдэл',
                sub: 'Төлөв өөрчлөгдөх, хүргэгдсэн зэргийг апп дотор сануулах',
                color: kBlue,
                value: NotificationPrefsStore.txUpdates,
                onChanged: (v) async {
                  await NotificationPrefsStore.setTxUpdates(v);
                  setS(() {});
                },
              ),
              _toggleRow(
                icon: Icons.campaign_rounded,
                label: 'Урамшуулал ба мэдээ',
                sub: 'Урамшуулал, ханшийн санал зэрэг (имэйл / зарлал)',
                color: kPurple,
                value: NotificationPrefsStore.promotions,
                onChanged: (v) async {
                  await NotificationPrefsStore.setPromotions(v);
                  setS(() {});
                },
              ),
              const SizedBox(height: 18),
              _PBtn(
                  label: 'Хадгалах',
                  onTap: () async {
                    if (!_googleDisplayNameLocked) {
                      UserStore.name = _nameCtrl.text.trim();
                    }
                    UserStore.email = _emailCtrl.text.trim();
                    UserStore.phoneDE = _phoneDECtrl.text.trim();
                    UserStore.phoneMN = _phoneMNCtrl.text.trim();
                    UserStore.addressStreet = _streetCtrl.text.trim();
                    UserStore.addressZip = _plzCtrl.text.trim();
                    UserStore.addressCity = _cityCtrl.text.trim();
                    await UserStore.save();
                    await ContactVerificationStore.reconcileAfterProfileSave();
                    await AccountStore.load();
                    setState(() {});
                    if (ctx.mounted) Navigator.pop(ctx);
                  }),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _toggleRow({required IconData icon, required String label, required String sub,
      required Color color, required bool value, required ValueChanged<bool> onChanged}) =>
    Container(margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: const Color(0xFF111111), borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF2A2A2A))),
      child: Row(children: [
        Container(width: 36, height: 36, decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color, size: 18)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
          Text(sub, style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 10, height: 1.3)),
        ])),
        Switch(value: value, onChanged: onChanged, activeColor: color),
      ]));

  Widget _infoRow(IconData icon, String label, TextEditingController ctrl,
      {String hint = '', TextInputType? keyboardType}) =>
      Padding(padding: const EdgeInsets.only(bottom: 12), child: Row(children: [
        Icon(icon, color: Colors.white38, size: 18),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11)),
          TextField(
              controller: ctrl,
              keyboardType: keyboardType,
              style: GoogleFonts.notoSans(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  hintText: hint,
                  hintStyle: GoogleFonts.notoSans(color: Colors.white24, fontSize: 13),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none)),
        ])),
      ]));

  void _showFeeInfo(BuildContext ctx, MemberTier tier) {
    showModalBottomSheet(context: ctx, backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(color: Color(0xFF1C1C1C), borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 16),
          Text('Шимтгэлийн хөнгөлөлт', style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 16),
          for (final t in MemberTier.values)
            Container(margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: t == tier ? t.color.withOpacity(0.12) : const Color(0xFF111111),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: t == tier ? t.color : const Color(0xFF2A2A2A), width: t == tier ? 1.8 : 1)),
              child: Row(children: [
                Text(t.icon, style: const TextStyle(fontSize: 22)),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${t.label} Member', style: GoogleFonts.notoSans(color: t.color, fontWeight: FontWeight.w700, fontSize: 13)),
                  Text('${t.minTx}+ гүйлгээ · ${(t.discount*100).toStringAsFixed(0)}% хөнгөлөлт',
                      style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11)),
                ])),
                if (t.discount > 0) Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: kGreen.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
                    child: Text('-${(t.discount*100).toStringAsFixed(0)}%',
                        style: GoogleFonts.notoSans(color: kGreen, fontWeight: FontWeight.w800, fontSize: 14)))
                else Text('Хөнгөлөлтгүй', style: GoogleFonts.notoSans(color: Colors.white24, fontSize: 12)),
              ])),
        ]),
      ));
  }

  void _showTxHistory(BuildContext ctx) {
    showModalBottomSheet(context: ctx, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(initialChildSize: 0.7, maxChildSize: 0.95, minChildSize: 0.4,
        builder: (_, sc) => Container(
          decoration: const BoxDecoration(color: Color(0xFF1C1C1C), borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(children: [
            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 12),
            Text('Гүйлгээний түүх', style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 12),
            Expanded(child: widget.history.isEmpty
                ? Center(child: Text('Гүйлгээ байхгүй', style: GoogleFonts.notoSans(color: Colors.white38)))
                : ListView(controller: sc, children: widget.history.map((tx) => _ProfileTxCard(tx: tx)).toList())),
          ]),
        )));
  }
}

class _SavedAccountCard extends StatelessWidget {
  final SavedAccount acc;
  final VoidCallback onDelete;
  const _SavedAccountCard({required this.acc, required this.onDelete});

  @override
  Widget build(BuildContext context) => MSCard(child: Row(children: [
    Container(width: 40, height: 40,
        decoration: BoxDecoration(color: kYellow.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
        child: const Icon(Icons.account_balance_rounded, color: kYellow, size: 20)),
    const SizedBox(width: 12),
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(acc.name.isNotEmpty ? acc.name : acc.bank,
          style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
      Text(savedAccountDisplayNo(acc.accountNo),
          style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12)),
      Text(acc.bank, style: GoogleFonts.notoSans(color: Colors.white24, fontSize: 11)),
    ])),
    // Copy товч
    IconButton(
        icon: const Icon(Icons.copy, color: Color(0xFF555555), size: 18),
        onPressed: () => Clipboard.setData(
            ClipboardData(text: savedAccountClipboardText(acc.accountNo))),
    ),
    // Delete товч
    IconButton(
        icon: const Icon(Icons.delete_outline_rounded, color: kRed, size: 18),
        onPressed: onDelete),
  ]));
}

class _ProfileTxCard extends StatelessWidget {
  final TxRecord tx;
  const _ProfileTxCard({required this.tx});

  @override
  Widget build(BuildContext context) => Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: kBorder)),
      child: Row(children: [
        Container(width: 38, height: 38,
            decoration: BoxDecoration(
                color: tx.isCompleted ? kGreen.withOpacity(0.1) : kYellow.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10)),
            child: Icon(tx.currentStep.icon,
                color: tx.isCompleted ? kGreen : kYellow, size: 18)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${tx.from} → ${tx.to}',
              style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
          Text(tx.date, style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11)),
          Text(tx.currentStep.labelFor(txFlowDir(tx)),
              style: GoogleFonts.notoSans(color: tx.isCompleted ? kGreen : kYellow, fontSize: 11)),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(txListPrimaryAmt(tx),
              style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
          Text(txListSecondaryAmt(tx),
              style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11)),
          Container(
              margin: const EdgeInsets.only(top: 2),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                  color: tx.isCompleted ? kGreen.withOpacity(0.1) : kYellow.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6)),
              child: Text(tx.isCompleted ? '✓ Амжилттай' : '⏳ Явж байна',
                  style: GoogleFonts.notoSans(
                      color: tx.isCompleted ? kGreen : kYellow, fontSize: 10, fontWeight: FontWeight.w600))),
        ]),
      ]));
}

// ─── Animated ────────────────────────────────────────────────────
class _PulseIcon extends StatefulWidget {
  final IconData icon; final Color color;
  const _PulseIcon(this.icon,this.color);
  @override State<_PulseIcon> createState()=>_PulseIconState();
}
class _PulseIconState extends State<_PulseIcon> with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override void initState(){super.initState();_c=AnimationController(vsync:this,duration:const Duration(milliseconds:900));_c.repeat(reverse:true);}
  @override void dispose(){_c.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>ScaleTransition(
      scale:Tween<double>(begin:0.85,end:1.0).animate(CurvedAnimation(parent:_c,curve:Curves.easeInOut)),
      child:Icon(widget.icon,color:widget.color,size:20));
}

class _LoadingDots extends StatefulWidget {
  @override State<_LoadingDots> createState()=>_LoadingDotsState();
}
class _LoadingDotsState extends State<_LoadingDots> with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override void initState(){super.initState();_c=AnimationController(vsync:this,duration:const Duration(milliseconds:1200));_c.repeat();}
  @override void dispose(){_c.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>AnimatedBuilder(animation:_c,builder:(_,__)=>Row(
      children:List.generate(3,(i){
        final t=(_c.value-i*0.2).clamp(0.0,1.0);
        return Padding(padding:const EdgeInsets.only(right:4),child:Container(width:6,height:6,
            decoration:BoxDecoration(color:kYellow.withOpacity(t>0.5?1.0:0.2),shape:BoxShape.circle)));
      })));
}

// ─── MEMBER BENEFIT SCREEN ───────────────────────────────────────
class MemberBenefitScreen extends StatelessWidget {
  final MemberTier tier;
  final int txCount;
  const MemberBenefitScreen({super.key, required this.tier, required this.txCount});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(backgroundColor: kBg, elevation: 0,
          leading: IconButton(icon: const Icon(Icons.arrow_back_ios, color: kYellow), onPressed: () => Navigator.pop(context)),
          title: Text('Урамшуулал & Зэрэглэл', style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 17))),
      body: ListView(padding: const EdgeInsets.all(20), children: [

        // Одоогийн зэрэглэл карт
        Container(padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [tier.color.withOpacity(0.25), tier.color.withOpacity(0.05)]),
            borderRadius: BorderRadius.circular(20), border: Border.all(color: tier.color.withOpacity(0.5))),
          child: Column(children: [
            Text(tier.icon, style: const TextStyle(fontSize: 48)),
            const SizedBox(height: 8),
            Text('${tier.label} Member', style: GoogleFonts.notoSans(color: tier.color, fontWeight: FontWeight.w900, fontSize: 22)),
            const SizedBox(height: 4),
            Text('$txCount гүйлгээ хийсэн', style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 13)),
            const SizedBox(height: 12),
            Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(color: kGreen.withOpacity(0.15), borderRadius: BorderRadius.circular(12)),
              child: Text('${(tier.discount*100).toStringAsFixed(0)}% шимтгэлийн хөнгөлөлт',
                  style: GoogleFonts.notoSans(color: kGreen, fontWeight: FontWeight.w800, fontSize: 16))),
          ])),
        const SizedBox(height: 20),

        Text('Зэрэглэлийн шат', style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
        const SizedBox(height: 12),

        // Бүх tier-үүдийг харуулах
        for (final t in MemberTier.values) ...[
          Container(margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: t == tier ? t.color.withOpacity(0.1) : kCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: t == tier ? t.color : kBorder, width: t == tier ? 2 : 1)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.icon, style: const TextStyle(fontSize: 28)),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text('${t.label} Member', style: GoogleFonts.notoSans(color: t.color, fontWeight: FontWeight.w800, fontSize: 14)),
                  if (t == tier) ...[
                    const SizedBox(width: 8),
                    Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: t.color, borderRadius: BorderRadius.circular(8)),
                        child: Text('Одоогийн', style: GoogleFonts.notoSans(color: Colors.black, fontWeight: FontWeight.w700, fontSize: 10))),
                  ],
                ]),
                const SizedBox(height: 4),
                Text('${t.minTx}+ гүйлгээ шаардлагатай',
                    style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11)),
                const SizedBox(height: 8),
                // Давуу талууд
                for (final benefit in _tierBenefits(t))
                  Padding(padding: const EdgeInsets.only(bottom: 3), child: Row(children: [
                    Icon(Icons.check_circle_rounded, color: t.color, size: 14),
                    const SizedBox(width: 6),
                    Expanded(child: Text(benefit, style: GoogleFonts.notoSans(color: Colors.white60, fontSize: 12))),
                  ])),
              ])),
            ])),
        ],

        const SizedBox(height: 8),
        Container(padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: kYellow.withOpacity(0.06), borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kYellow.withOpacity(0.2))),
          child: Text('💡 Зэрэглэл автоматаар дэвших бөгөөд шимтгэлийн хөнгөлөлт шилжүүлэх дүнд шууд тооцогдоно.',
              style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 12, height: 1.5))),
      ]),
    );
  }

  List<String> _tierBenefits(MemberTier t) {
    switch(t) {
      case MemberTier.bronze:  return ['Үндсэн шилжүүлгийн үйлчилгээ', 'Гүйлгээний түүх', 'Харилцагчийн дэмжлэг'];
      case MemberTier.silver:  return ['5% шимтгэлийн хөнгөлөлт', 'Хурдан дэмжлэг (24 цаг)', 'Хадгалсан данс хязгааргүй'];
      case MemberTier.gold:    return ['10% шимтгэлийн хөнгөлөлт', 'VIP дэмжлэг', 'Тусгай ханшийн хэлцэл', 'Зээлийн хүсэлт'];
      case MemberTier.platinum:return ['20% шимтгэлийн хөнгөлөлт', 'Хувийн менежер', 'Шуурхай шилжүүлэг (5 мин)', 'Онцгой ханш', 'Дурын хэмжээний зээл'];
    }
  }
}

// ─── LOAN CORNER ─────────────────────────────────────────────────
// ─── LOAN CORNER ──────────────────────────────────────────────────
class LoanCornerScreen extends StatefulWidget {
  final String initialAmt;
  const LoanCornerScreen({super.key, this.initialAmt = ''});
  @override State<LoanCornerScreen> createState() => _LoanCornerState();
}

class _LoanCornerState extends State<LoanCornerScreen> {
  final _picker     = ImagePicker();
  final _nameCtrl   = TextEditingController();
  final _emailCtrl  = TextEditingController();
  late final _amtCtrl  = TextEditingController(text: widget.initialAmt);
  final _noteCtrl   = TextEditingController();

  // 4 баримт бичиг
  XFile? _melde;       // Meldebescheinigung
  XFile? _vertrag;     // Arbeits- / Mietvertrag
  XFile? _salary1;     // 1-р сарын цалин
  XFile? _salary2;     // 2-р сарын цалин
  XFile? _salary3;     // 3-р сарын цалин
  XFile? _selbst;      // Selbstauskunft
  XFile? _lastschrift; // Lastschriftmandat

  bool _submitted = false;
  bool _loading   = false;

  bool get _allReady =>
      _nameCtrl.text.trim().isNotEmpty &&
      _emailCtrl.text.trim().isNotEmpty &&
      _amtCtrl.text.trim().isNotEmpty &&
      _melde != null &&
      _vertrag != null &&
      _salary1 != null &&
      _salary2 != null &&
      _salary3 != null &&
      _selbst != null &&
      _lastschrift != null;

  Future<void> _pick(String label, void Function(XFile) onPicked) async {
    final src = await showModalBottomSheet<ImageSource>(
      context: context, backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(color: Color(0xFF1C1C1C),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: GoogleFonts.notoSans(
              color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
          const SizedBox(height: 16),
          _srcBtn(Icons.camera_alt_rounded, 'Камер', ImageSource.camera),
          const SizedBox(height: 10),
          _srcBtn(Icons.photo_library_rounded, 'Галерей', ImageSource.gallery),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (src == null) return;
    final f = await _picker.pickImage(source: src, imageQuality: 80);
    if (f != null) setState(() => onPicked(f));
  }

  Widget _srcBtn(IconData icon, String label, ImageSource src) =>
      GestureDetector(
        onTap: () => Navigator.pop(context, src),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          decoration: BoxDecoration(color: kCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kBorder)),
          child: Row(children: [
            Icon(icon, color: kYellow, size: 20),
            const SizedBox(width: 12),
            Text(label, style: GoogleFonts.notoSans(color: Colors.white, fontSize: 14)),
          ]),
        ),
      );

  // Нэг баримтын картны widget
  Widget _docCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required XFile? file,
    required VoidCallback onTap,
  }) {
    final done = file != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: done ? kYellow.withOpacity(0.07) : kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: done ? kYellow.withOpacity(0.5) : kBorder)),
        child: Row(children: [
          Container(
            width: 42, height: 42,
            decoration: BoxDecoration(
              color: done ? kYellow.withOpacity(0.18) : kBorder.withOpacity(0.35),
              borderRadius: BorderRadius.circular(10)),
            child: Icon(done ? Icons.check_circle_rounded : icon,
                color: done ? kYellow : Colors.white38, size: 22)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: GoogleFonts.notoSans(
                color: done ? kYellow : Colors.white,
                fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(height: 2),
            Text(done ? '✓ Зураг хавсаргасан' : subtitle,
                style: GoogleFonts.notoSans(
                    color: done ? Colors.white54 : Colors.white38, fontSize: 11)),
          ])),
          Icon(Icons.camera_alt_outlined,
              color: done ? kYellow.withOpacity(0.6) : Colors.white24, size: 18),
        ]),
      ),
    );
  }

  Widget _tf(TextEditingController c, String hint, {int lines = 1, TextInputType? kbType}) =>
      TextField(
        controller: c, maxLines: lines, keyboardType: kbType,
        style: GoogleFonts.notoSans(color: Colors.white, fontSize: 14),
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: GoogleFonts.notoSans(color: Colors.white24),
          filled: true, fillColor: kCard,
          border:        OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kBorder)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kBorder)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kYellow)),
        ),
      );

  Future<void> _submit() async {
    setState(() => _loading = true);
    final body = Uri.encodeComponent('''
MoneySENT — Зээлийн хүсэлт

Нэр:    ${_nameCtrl.text.trim()}
Имэйл:  ${_emailCtrl.text.trim()}
Хүссэн дүн: ${_amtCtrl.text.trim()} EUR
Тайлбар: ${_noteCtrl.text.trim()}

── Хавсаргасан баримт бичгүүд ──
✓ Meldebescheinigung:      ${_melde != null ? 'хавсаргасан' : 'байхгүй'}
✓ Arbeits-/Mietvertrag:    ${_vertrag != null ? 'хавсаргасан' : 'байхгүй'}
✓ Цалингийн тодорхойлолт (1): ${_salary1 != null ? 'хавсаргасан' : 'байхгүй'}
✓ Цалингийн тодорхойлолт (2): ${_salary2 != null ? 'хавсаргасан' : 'байхгүй'}
✓ Цалингийн тодорхойлолт (3): ${_salary3 != null ? 'хавсаргасан' : 'байхгүй'}
✓ Selbstauskunft:          ${_selbst != null ? 'хавсаргасан' : 'байхгүй'}
✓ SEPA Lastschriftmandat:  ${_lastschrift != null ? 'хавсаргасан' : 'байхгүй'}

Анхааруулга: Дүрсүүд имэйл клиентийг нээсний дараа гараар хавсаргана уу.
''');
    final sub = Uri.encodeComponent('MoneySENT – Зээлийн хүсэлт | ${_nameCtrl.text.trim()}');
    final u = Uri.parse('mailto:topfiles999@gmail.com?subject=$sub&body=$body');
    if (await canLaunchUrl(u)) {
      await launchUrl(u);
      setState(() { _submitted = true; _loading = false; });
    } else {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg, elevation: 0,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios, color: kYellow),
            onPressed: () => Navigator.pop(context)),
        title: Text('Зээлийн хүсэлт',
            style: GoogleFonts.notoSans(color: Colors.white,
                fontWeight: FontWeight.w800, fontSize: 18)),
      ),
      body: _submitted ? _successView() : _formView(),
    );
  }

  Widget _successView() => Center(child: Padding(
    padding: const EdgeInsets.all(28),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 72, height: 72,
          decoration: BoxDecoration(color: kYellow.withOpacity(0.15),
              shape: BoxShape.circle),
          child: const Icon(Icons.mark_email_read_rounded, color: kYellow, size: 36)),
      const SizedBox(height: 20),
      Text('Баримт бичиг илгээгдлээ', style: GoogleFonts.notoSans(
          color: Colors.white, fontWeight: FontWeight.w800, fontSize: 20)),
      const SizedBox(height: 10),
      Text('Одоо зээлийн гэрээ байгуулж гарын үсэг зурна уу.\nМанай баг шалгаж зөвшөөрснийхөө дараа "Зээлийн эрхтэй гишүүн" болно.',
          textAlign: TextAlign.center,
          style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 13, height: 1.55)),
      const SizedBox(height: 28),
      _PBtn(
        label: '✍️  Зээлийн гэрээ байгуулах  →',
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) =>
            LoanContractScreen(
              name: _nameCtrl.text.trim(),
              email: _emailCtrl.text.trim(),
              amtEur: _amtCtrl.text.trim(),
            ))).then((signed) {
          if (signed == true) Navigator.pop(context);
        }),
      ),
      const SizedBox(height: 12),
      GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Text('Дараа байгуулах', style: GoogleFonts.notoSans(
            color: Colors.white38, fontSize: 12)),
      ),
    ]),
  ));

  Widget _formView() => ListView(padding: const EdgeInsets.all(20), children: [
    // ── Толгой ──
    Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [kYellow.withOpacity(0.14), kYellow.withOpacity(0.04)]),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kYellow.withOpacity(0.35))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.account_balance_wallet_rounded, color: kYellow, size: 22),
          const SizedBox(width: 8),
          Text('3 хувааж төлөх — Зээлийн хүсэлт',
              style: GoogleFonts.notoSans(color: kYellow,
                  fontWeight: FontWeight.w800, fontSize: 14)),
        ]),
        const SizedBox(height: 10),
        Text('Зээл авахын тулд доорх мэдээлэл болон баримт бичгийг бүрэн хавсаргана уу. '
            'Манай баг шалгаж, зөвшөөрөл өгнө.',
            style: GoogleFonts.notoSans(color: Colors.white60, fontSize: 12, height: 1.5)),
      ]),
    ),
    const SizedBox(height: 20),

    // ── Хувийн мэдээлэл ──
    Text('Хувийн мэдээлэл',
        style: GoogleFonts.notoSans(color: Colors.white54,
            fontWeight: FontWeight.w700, fontSize: 12)),
    const SizedBox(height: 8),
    _tf(_nameCtrl, 'Бүтэн нэр (Овог Нэр)'),
    const SizedBox(height: 10),
    _tf(_emailCtrl, 'Имэйл хаяг', kbType: TextInputType.emailAddress),
    const SizedBox(height: 10),
    _tf(_amtCtrl, 'Хүссэн зээлийн дүн (EUR)', kbType: TextInputType.number),
    const SizedBox(height: 10),
    _tf(_noteCtrl, 'Нэмэлт тайлбар (заавал биш)', lines: 3),
    const SizedBox(height: 22),

    // ── Баримт бичгүүд ──
    Text('Шаардлагатай баримт бичгүүд',
        style: GoogleFonts.notoSans(color: Colors.white54,
            fontWeight: FontWeight.w700, fontSize: 12)),
    const SizedBox(height: 4),
    Text('Германд бүртгэлтэй байгааг болон орлогоо нотлох баримтыг хавсаргана уу.',
        style: GoogleFonts.notoSans(color: Colors.white24, fontSize: 11, height: 1.45)),
    const SizedBox(height: 12),

    _docCard(
      title: 'Meldebescheinigung',
      subtitle: 'Германд бүртгэлтэй байгааг нотолно',
      icon: Icons.home_work_rounded,
      file: _melde,
      onTap: () => _pick('Meldebescheinigung', (f) => _melde = f),
    ),
    _docCard(
      title: 'Arbeitsvertrag / Mietvertrag',
      subtitle: 'Ажлын эсвэл түрээсийн гэрээ',
      icon: Icons.description_rounded,
      file: _vertrag,
      onTap: () => _pick('Arbeits- / Mietvertrag', (f) => _vertrag = f),
    ),
    // Salary — 3 тусдаа
    Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kCard, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.payments_rounded,
              color: (_salary1 != null && _salary2 != null && _salary3 != null)
                  ? kYellow : Colors.white38, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text('Сүүлийн 3 сарын цалингийн тодорхойлолт',
              style: GoogleFonts.notoSans(
                  color: (_salary1 != null && _salary2 != null && _salary3 != null)
                      ? kYellow : Colors.white,
                  fontWeight: FontWeight.w700, fontSize: 13))),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          _salaryBtn('1-р сар', _salary1, (f) => _salary1 = f),
          const SizedBox(width: 8),
          _salaryBtn('2-р сар', _salary2, (f) => _salary2 = f),
          const SizedBox(width: 8),
          _salaryBtn('3-р сар', _salary3, (f) => _salary3 = f),
        ]),
      ]),
    ),
    _docCard(
      title: 'Selbstauskunft',
      subtitle: 'Өөрийн орлого, зарлагын мэдүүлэг',
      icon: Icons.article_rounded,
      file: _selbst,
      onTap: () => _pick('Selbstauskunft', (f) => _selbst = f),
    ),
    _docCard(
      title: 'SEPA Lastschriftmandat',
      subtitle: 'Гарын үсэгтэй direct debit зөвшөөрөл',
      icon: Icons.draw_rounded,
      file: _lastschrift,
      onTap: () => _pick('SEPA Lastschriftmandat', (f) => _lastschrift = f),
    ),

    // ── Анхааруулга ──
    Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.3))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.info_outline_rounded, color: Colors.orange, size: 16),
        const SizedBox(width: 8),
        Expanded(child: Text(
          'Имэйл клиент нээгдсэний дараа баримт бичгийн зургуудыг гараар хавсаргана уу. '
          'Зөвшөөрөл өгсний дараа эхний төлбөр автоматаар авагдана.',
          style: GoogleFonts.notoSans(color: Colors.orange, fontSize: 11, height: 1.5))),
      ]),
    ),
    const SizedBox(height: 24),

    _PBtn(
      label: _loading ? 'Уншиж байна...' : 'Хүсэлт илгээх',
      onTap: _allReady && !_loading ? () => _submit() : null,
    ),
    const SizedBox(height: 8),
    if (!_allReady)
      Center(child: Text('Бүх баримт болон мэдээллийг бөглөнө үү',
          style: GoogleFonts.notoSans(color: Colors.white24, fontSize: 11))),
    const SizedBox(height: 20),
  ]);

  Widget _salaryBtn(String label, XFile? file, void Function(XFile) onPicked) =>
      Expanded(child: GestureDetector(
        onTap: () => _pick('Цалингийн тодорхойлолт ($label)', onPicked),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: file != null ? kYellow.withOpacity(0.12) : kBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: file != null ? kYellow.withOpacity(0.5) : kBorder)),
          child: Column(children: [
            Icon(file != null ? Icons.check_circle_rounded : Icons.upload_rounded,
                color: file != null ? kYellow : Colors.white38, size: 20),
            const SizedBox(height: 4),
            Text(label, style: GoogleFonts.notoSans(
                color: file != null ? kYellow : Colors.white38,
                fontWeight: FontWeight.w700, fontSize: 10)),
          ]),
        ),
      ));
}

/// Имэйлээр ханшийн хүсэлт илгээсний дараа — локал тоолуур (админ самбар + профайлын тойм).
class RateRequestQueueStore {
  static const _kPending = 'rate_request_queue_pending';

  static bool _pending = false;
  static bool get isPending => _pending;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _pending = p.getBool(_kPending) ?? false;
  }

  static Future<void> setPending() async {
    _pending = true;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kPending, true);
  }

  static Future<void> clear() async {
    _pending = false;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kPending, false);
  }
}

// ─── RATE REQUEST ─────────────────────────────────────────────────
class RateRequestScreen extends StatefulWidget {
  const RateRequestScreen({super.key});
  @override State<RateRequestScreen> createState()=>_RateRequestState();
}
class _RateRequestState extends State<RateRequestScreen> {
  final _amount=TextEditingController(), _note=TextEditingController();
  bool _sent=false;
  Future<void> _send() async {
    await AdminStore.load();
    final to = AdminStore.rateRequestMailtoRecipients.trim();
    if (to.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('Админы имэйл тохируулаагүй байна.', style: GoogleFonts.notoSans()),
      ));
      return;
    }
    final sub = Uri.encodeComponent('MoneySENT - Ханшийн хүсэлт');
    final who =
        'Хэрэглэгч: ${UserStore.name}\nИмэйл: ${UserStore.email}\nУтас DE: ${UserStore.phoneDE} | MN: ${UserStore.phoneMN}\n\n';
    final body = Uri.encodeComponent('$whoДүн/валют: ${_amount.text}\n\nТайлбар:\n${_note.text}');
    final u = Uri.parse('mailto:$to?subject=$sub&body=$body');
    try {
      final ok = await launchUrl(u, mode: LaunchMode.externalApplication);
      if (!mounted) return;
      if (ok) {
        await RateRequestQueueStore.setPending();
        setState(() => _sent = true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            'И-мэйл апп олдсонгүй. Төхөөрөмж дээрээ и-мэйл (Gmail гэх мэт) тохируулна уу.',
            style: GoogleFonts.notoSans(fontSize: 13),
          ),
        ));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: kRed,
        content: Text('Илгээхэд алдаа: $e', style: GoogleFonts.notoSans(fontSize: 13)),
      ));
    }
  }
  Widget _tf(TextEditingController c,String h,int lines)=>TextField(controller:c,maxLines:lines,
      style:GoogleFonts.notoSans(color:Colors.white,fontSize:14),
      decoration:InputDecoration(hintText:h,hintStyle:GoogleFonts.notoSans(color:Colors.white24),
          filled:true,fillColor:kCard,
          border:OutlineInputBorder(borderRadius:BorderRadius.circular(12),borderSide:const BorderSide(color:kBorder)),
          enabledBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(12),borderSide:const BorderSide(color:kBorder)),
          focusedBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(12),borderSide:const BorderSide(color:kYellow))));
  @override Widget build(BuildContext context)=>Scaffold(
      backgroundColor:kBg,
      appBar:AppBar(backgroundColor:kBg,elevation:0,
          leading:IconButton(icon:const Icon(Icons.arrow_back_ios,color:kYellow),onPressed:()=>Navigator.pop(context)),
          title:Text('Ханшийн хүсэлт',style:GoogleFonts.notoSans(color:Colors.white,fontWeight:FontWeight.w800,fontSize:18))),
      body:ListView(padding:const EdgeInsets.all(20),children:[
        if(_sent)
          MSCard(child:Column(children:[const Text('OK',style:TextStyle(fontSize:36,color:kGreen)),const SizedBox(height:8),
            Text('Админ руу илгээгдлээ',style:GoogleFonts.notoSans(color:kGreen,fontWeight:FontWeight.w700))]))
        else...[
          Text('Тодорхой дүн, валютын ханшийг авахыг хүсвэл бөглөнө үү. Хүсэлтийг зөвхөн бүрэн админ руу илгээнэ.',
              style:GoogleFonts.notoSans(color:Colors.white54,fontSize:13,height:1.45)),
          const SizedBox(height:20),
          _tf(_amount,'Жишээ: 500 EUR -> MNT',1),
          const SizedBox(height:12),
          _tf(_note,'Нэмэлт тайлбар',4),
          const SizedBox(height:20),
          _PBtn(label:'Админ руу илгээх',onTap:_send),
        ],
      ]));
}

// ─── Verification Status Store ────────────────────────────────────
class VerifyStore {
  static const _key = 'verify_status';
  static String _status = 'none'; // none | pending | verified
  static String get status => _status;
  static bool get isPending  => _status == 'pending';
  static bool get isVerified => _status == 'verified';
  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _status = p.getString(_key) ?? 'none';
  }
  static Future<void> setPending() async {
    _status = 'pending';
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, 'pending');
  }
  static Future<void> setVerified() async {
    _status = 'verified';
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, 'verified');
  }

  static Future<void> resetToNone() async {
    _status = 'none';
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, 'none');
  }
}

// ─── ADMIN (энэ төхөөрөмж дээрх төлөвүүдийг удирдах) ───────────────
class AdminStore {
  static const _kWhitelist = 'admin_email_whitelist';
  static const _kModerators = 'moderator_email_whitelist';
  static const _kSessionUntil = 'admin_session_until_ms';

  /// Анхны админ нэвтрэлт — production-д заавал солиод код нууна уу.
  static const String masterUnlockPin = 'MSADM2026';

  /// Бүрэн админ whitelist хоосон үед.
  static const List<String> _defaultWhitelistEmails = ['maag888@gmail.com'];

  /// Модератор: зөвхөн баримт/баталгаажуулалт — зээлийн тохиргоо огт биш.
  static const List<String> _defaultModeratorEmails = ['topfiles999@gmail.com'];

  static List<String> _whitelist = [];
  static List<String> _moderators = [];
  static int _sessionUntilMs = 0;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _sessionUntilMs = p.getInt(_kSessionUntil) ?? 0;

    final raw = p.getString(_kWhitelist) ?? '';
    _whitelist = raw.split('|').map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).toList();
    if (_whitelist.isEmpty) {
      _whitelist = _defaultWhitelistEmails.map((e) => e.trim().toLowerCase()).toList();
      await _persistWhitelist();
    }

    final modRaw = p.getString(_kModerators) ?? '';
    _moderators = modRaw.split('|').map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).toList();
    if (_moderators.isEmpty) {
      _moderators = _defaultModeratorEmails.map((e) => e.trim().toLowerCase()).toList();
      await _persistModerators();
    }
  }

  static bool get sessionActive =>
      DateTime.now().millisecondsSinceEpoch < _sessionUntilMs;

  /// Бүрэн эрх: PIN сесс эсвэл админ whitelist.
  static bool get isFullAdmin {
    if (sessionActive) return true;
    final em = UserStore.email.trim().toLowerCase();
    return em.isNotEmpty && _whitelist.contains(em);
  }

  /// Зөвхөн модератор (бүрэн админ биш).
  static bool get isModeratorOnly {
    final em = UserStore.email.trim().toLowerCase();
    if (em.isEmpty) return false;
    return _moderators.contains(em) && !isFullAdmin;
  }

  /// Самбар руу орох эрх (админ эсвэл модератор).
  static bool hasPanelAccess() {
    final em = UserStore.email.trim().toLowerCase();
    if (isFullAdmin) return true;
    return em.isNotEmpty && _moderators.contains(em);
  }

  /// Whitelist болон бүрэн эрхийн удирдлага.
  static bool get canManageLoanAndStaff => isFullAdmin;

  static Future<bool> unlockWithMasterPin(String pin) async {
    if (pin.trim() != masterUnlockPin) return false;
    _sessionUntilMs = DateTime.now().add(const Duration(hours: 12)).millisecondsSinceEpoch;
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kSessionUntil, _sessionUntilMs);
    return true;
  }

  static Future<void> endSession() async {
    _sessionUntilMs = 0;
    final p = await SharedPreferences.getInstance();
    await p.remove(_kSessionUntil);
  }

  static List<String> get whitelistEmails => List.unmodifiable(_whitelist);
  static List<String> get moderatorEmails => List.unmodifiable(_moderators);

  /// Ханшийн хүсэлт зэргийг зөвхөн **бүрэн админууд** руу илгээх (whitelist бүх имэйл).
  static String get rateRequestMailtoRecipients {
    if (_whitelist.isNotEmpty) return _whitelist.join(',');
    return _defaultWhitelistEmails.first.trim().toLowerCase();
  }

  static Future<void> addWhitelistEmail(String email) async {
    final e = email.trim().toLowerCase();
    if (e.isEmpty || _whitelist.contains(e)) return;
    _whitelist = [..._whitelist, e];
    await _persistWhitelist();
  }

  static Future<void> removeWhitelistEmail(String email) async {
    final e = email.trim().toLowerCase();
    _whitelist = _whitelist.where((x) => x != e).toList();
    await _persistWhitelist();
  }

  static Future<void> addModeratorEmail(String email) async {
    final e = email.trim().toLowerCase();
    if (e.isEmpty || _moderators.contains(e)) return;
    _moderators = [..._moderators, e];
    await _persistModerators();
  }

  static Future<void> removeModeratorEmail(String email) async {
    final e = email.trim().toLowerCase();
    _moderators = _moderators.where((x) => x != e).toList();
    await _persistModerators();
  }

  static Future<void> _persistWhitelist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kWhitelist, _whitelist.join('|'));
  }

  static Future<void> _persistModerators() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kModerators, _moderators.join('|'));
  }
}

class LoanStore {
  static const _key = 'loan_status';
  static String _status = 'none'; // none | pending | approved

  /// Идэвхтэй зээлийн үүрэг (шилжүүлэг гэрээгээр үүссэн)
  static const _kOblActive = 'loan_obligation_active';
  static const _kRemain = 'loan_remaining_eur';
  static const _kGrand = 'loan_grand_eur';
  static const _kPrincipal = 'loan_principal_eur';
  static const _kIntPool = 'loan_interest_pool_eur';
  static const _kStartMs = 'loan_start_ms';

  /// Зээлээр шилжүүлэх үндсэн дүнгийн дээд хязгаар (EUR)
  static const double maxLoanPrincipalEur = 250;

  /// Монголын банкны жишиг жилийн хүү — эрт хаах тооцоололд (батлагдсан дүнг аппын тохиргооноос солино)
  static const double mnBenchmarkAnnualRate = 0.115;

  static String get status => _status;
  static bool get isNone => _status == 'none';
  static bool get isPending => _status == 'pending';
  static bool get isApproved => _status == 'approved';

  static bool _obligationActive = false;
  static double _remainingEur = 0;
  static double _grandEur = 0;
  static double _principalEur = 0;
  static double _interestPoolEur = 0;
  static int _startMs = 0;

  static bool get hasOpenLoan => _obligationActive && _remainingEur > 0.005;
  static bool get canStartLoanTransfer => isApproved && !hasOpenLoan;

  static double get remainingEur => _remainingEur;
  static double get grandTotalEur => _grandEur;
  static double get principalEur => _principalEur;
  static double get interestPoolEur => _interestPoolEur;
  static DateTime? get loanStartDate =>
      _startMs > 0 ? DateTime.fromMillisecondsSinceEpoch(_startMs) : null;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _status = p.getString(_key) ?? 'none';
    _obligationActive = p.getBool(_kOblActive) ?? false;
    _remainingEur = p.getDouble(_kRemain) ?? 0;
    _grandEur = p.getDouble(_kGrand) ?? 0;
    _principalEur = p.getDouble(_kPrincipal) ?? 0;
    _interestPoolEur = p.getDouble(_kIntPool) ?? 0;
    _startMs = p.getInt(_kStartMs) ?? 0;
  }

  static Future<void> _persistObligation() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kOblActive, _obligationActive);
    await p.setDouble(_kRemain, _remainingEur);
    await p.setDouble(_kGrand, _grandEur);
    await p.setDouble(_kPrincipal, _principalEur);
    await p.setDouble(_kIntPool, _interestPoolEur);
    await p.setInt(_kStartMs, _startMs);
  }

  static Future<void> setPending() async {
    _status = 'pending';
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, 'pending');
  }

  static Future<void> setApproved() async {
    _status = 'approved';
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, 'approved');
  }

  /// Зээлийн эрхгүй болгох (түүхэн дэх үүрэг тусад байна).
  static Future<void> setMembershipNone() async {
    _status = 'none';
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, 'none');
  }

  /// Шилжүүлгийн гэрээ баталсны дараа идэвхтэй үүрэг үүсгэнэ (зөвхөн батлагдсан хэрэглэгч, бүрэн тоо өгөгдөлтэй үед).
  static Future<void> activateObligation({
    required double principalEur,
    required double grandTotalEur,
    required double interestPoolEur,
  }) async {
    if (!isApproved || grandTotalEur <= 0 || principalEur <= 0) return;
    _obligationActive = true;
    _principalEur = principalEur;
    _grandEur = grandTotalEur;
    _remainingEur = grandTotalEur;
    _interestPoolEur = interestPoolEur.clamp(0, grandTotalEur);
    _startMs = DateTime.now().millisecondsSinceEpoch;
    await _persistObligation();
  }

  /// Бүрэн төлөгдсөний дараа дахин зээлээр шилжүүлэх боломжтой болгоно.
  static Future<void> settleLoanFully() async {
    _obligationActive = false;
    _remainingEur = 0;
    _grandEur = 0;
    _principalEur = 0;
    _interestPoolEur = 0;
    _startMs = 0;
    await _persistObligation();
  }

  /// Хугацаа дуусахаас өмнө бүтнээр хаахад ойролцоо нийт EUR (үлдэгдэл + жишиг хүүний нэмэгдэл).
  static double earlySettlementEstimate(DateTime payoffDate) {
    if (!hasOpenLoan) return 0;
    final start = DateTime.fromMillisecondsSinceEpoch(_startMs);
    final s0 = DateTime(start.year, start.month, start.day);
    final p0 = DateTime(payoffDate.year, payoffDate.month, payoffDate.day);
    final days = p0.difference(s0).inDays.clamp(0, 3650);
    final benchmarkCharge = _interestPoolEur * mnBenchmarkAnnualRate * (days / 365.0);
    return _remainingEur + benchmarkCharge;
  }

  static Future<void> reset() async {
    _status = 'none';
    final p = await SharedPreferences.getInstance();
    await p.remove(_key);
    await settleLoanFully();
  }
}

// ─── Зээлийн үлдэгдэл / эрт хаах ─────────────────────────────────
class LoanBalanceScreen extends StatefulWidget {
  const LoanBalanceScreen({super.key});
  @override State<LoanBalanceScreen> createState() => _LoanBalanceState();
}

class _LoanBalanceState extends State<LoanBalanceScreen> {
  DateTime _payoffDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    await LoanStore.load();
    if (mounted) setState(() {});
  }

  Future<void> _pickDate() async {
    final first = LoanStore.loanStartDate ?? DateTime.now().subtract(const Duration(days: 365));
    final d = await showDatePicker(
      context: context,
      initialDate: _payoffDate,
      firstDate: DateTime(first.year, first.month, first.day),
      lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
      builder: (_, child) => Theme(
        data: Theme.of(context).copyWith(colorScheme: const ColorScheme.dark(primary: kYellow, surface: kCard)),
        child: child!,
      ),
    );
    if (d != null) setState(() => _payoffDate = d);
  }

  @override
  Widget build(BuildContext context) {
    final start = LoanStore.loanStartDate;
    final open = LoanStore.hasOpenLoan;
    final est = open ? LoanStore.earlySettlementEstimate(_payoffDate) : 0.0;

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: kYellow, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Зээлийн үлдэгдэл',
          style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
        ),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (!open)
            MSCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  'Идэвхтэй зээлийн үлдэгдэл байхгүй',
                  style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14),
                ),
                const SizedBox(height: 8),
                Text(
                  'Зээлээр шилжүүлэг ашигласны дараа энд нийт үүрэг, үлдэгдэл, эрт хаах тооцоолол харагдана.',
                  style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 12.5, height: 1.45),
                ),
              ]),
            )
          else ...[
            MSCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  'Нийт зээлийн үүрэг · үлдэгдэл',
                  style: GoogleFonts.notoSans(color: kYellow, fontWeight: FontWeight.w800, fontSize: 13),
                ),
                const SizedBox(height: 12),
                _lbRow('Гэрээний үндсэн дүн (EUR)', '€${LoanStore.principalEur.toStringAsFixed(2)}'),
                _lbRow('Нийт төлөх төлөвлөгөө (EUR)', '€${LoanStore.grandTotalEur.toStringAsFixed(2)}'),
                _lbRow('Үлдэгдэл одоогоор (EUR)', '€${LoanStore.remainingEur.toStringAsFixed(2)}',
                    highlight: true),
                if (start != null)
                  _lbRow(
                      'Эхэлсэн огноо',
                      DateFormat('yyyy.MM.dd').format(start)),
                const SizedBox(height: 8),
                Text(
                  'Төлөлт бүрэн хийгдсэний дараа доор «Зээл бүрэн төлөгдлөө» дарж дахин зээлээр шилжүүлэх боломж нээгдэнэ.',
                  style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11, height: 1.4),
                ),
              ]),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.07),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.orange.withOpacity(0.35)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  'Эрт хаах (бүтэн дүнгээр)',
                  style: GoogleFonts.notoSans(color: Colors.orange, fontWeight: FontWeight.w800, fontSize: 13),
                ),
                const SizedBox(height: 8),
                Text(
                  'Хугацаа дуусахаас өмнө бүтнээр хаахад гэрээний хүүний хэсэг дээр Монголын банкны жишиг жилийн хүү '
                  '(${ (LoanStore.mnBenchmarkAnnualRate * 100).toStringAsFixed(1)}%) — өдрийн тоогоор пропорционал тооцсон нэмэгдэл үүрэг нэмэгдэнэ. Доорх огноог сонгож ойролцоо нийт төлөх дүнг үзнэ үү.',
                  style: GoogleFonts.notoSans(color: Colors.white60, fontSize: 12, height: 1.5),
                ),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: _pickDate,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: kCard,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: kBorder)),
                    child: Row(children: [
                      const Icon(Icons.calendar_today_rounded, color: kYellow, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          DateFormat('yyyy.MM.dd').format(_payoffDate),
                          style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14),
                        ),
                      ),
                      Text('Сонгох', style: GoogleFonts.notoSans(color: kYellow, fontWeight: FontWeight.w700, fontSize: 12)),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Ойролцоогоор төлөх нийт: €${est.toStringAsFixed(2)} EUR',
                  style: GoogleFonts.notoSans(color: kGreen, fontWeight: FontWeight.w900, fontSize: 15),
                ),
              ]),
            ),
          ],
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: kYellow.withOpacity(0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: kYellow.withOpacity(0.2)),
            ),
            child: Text(
              'Зээлээр шилжүүлэг нэг идэвхтэй үүрэг дээр нэг удаа л авна. Өмнөхийг бүрэн төлөөгүй бол дахин ашиглах боломжгүй. '
              'Одоогоор шилжүүлэх үндсэн дүн хамгийн ихдээ ${LoanStore.maxLoanPrincipalEur.toStringAsFixed(0)} EUR. Хэрэглээний судалгаагаар дээд хэмжээ өөрчлөгдөж болно.',
              style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 12, height: 1.5),
            ),
          ),
          if (open)
            TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: kCard,
                    title: Text('Зээл бүрэн төлөгдсөн гэж үү?', style: GoogleFonts.notoSans(color: Colors.white)),
                    content: Text(
                      'Бүрэн төлж дууссаны дараа л дахин «Зээлээр шилжүүлэх» горимыг ашиглана.',
                      style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 13, height: 1.45),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false),
                          child: Text('Болих', style: GoogleFonts.notoSans(color: Colors.white38))),
                      TextButton(onPressed: () => Navigator.pop(context, true),
                          child: Text('Тийм', style: GoogleFonts.notoSans(color: kGreen))),
                    ],
                  ),
                );
                if (ok == true && mounted) {
                  await LoanStore.settleLoanFully();
                  await _reload();
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    behavior: SnackBarBehavior.floating,
                    content: Text('Зээлийн үлдэгдэл тэглэгдлээ.', style: GoogleFonts.notoSans()),
                  ));
                }
              },
              child: Text(
                'Зээл бүрэн төлөгдлөө (батлах)',
                style: GoogleFonts.notoSans(color: kGreen, fontWeight: FontWeight.w700),
              ),
            ),
          if (!open) const SizedBox(height: 8),
          TextButton(
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  backgroundColor: kCard,
                  title: Text('[Тест] Зээлийн өгөгдөл цэвэрлэх', style: GoogleFonts.notoSans(color: Colors.white)),
                  content: Text(
                    'Зөвхөн хөгжүүлэгчийн туршилт — бүх зээлийн үлдэгдэл устана.',
                    style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 12),
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false),
                        child: Text('Болих', style: GoogleFonts.notoSans(color: Colors.white38))),
                    TextButton(onPressed: () => Navigator.pop(context, true),
                        child: Text('Цэвэрлэх', style: GoogleFonts.notoSans(color: kRed))),
                  ],
                ),
              );
              if (ok == true) {
                await LoanStore.settleLoanFully();
                await _reload();
              }
            },
            child: Text('[Тест] Зээлийн үлдэгдэл цэвэрлэх',
                style: GoogleFonts.notoSans(color: Colors.white24, fontSize: 11)),
          ),
        ],
      ),
    );
  }

  Widget _lbRow(String k, String v, {bool highlight = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(k, style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12)),
            ),
            Text(
              v,
              style: GoogleFonts.notoSans(
                color: highlight ? kYellow : Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ],
        ),
      );
}

// ─── SIGNATURE PAINTER ────────────────────────────────────────────
class _SignaturePainter extends CustomPainter {
  final List<List<Offset>> strokes;
  _SignaturePainter(this.strokes);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.8
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final stroke in strokes) {
      if (stroke.length < 2) continue;
      final path = Path()..moveTo(stroke[0].dx, stroke[0].dy);
      for (int i = 1; i < stroke.length; i++) {
        path.lineTo(stroke[i].dx, stroke[i].dy);
      }
      canvas.drawPath(path, paint);
    }
  }
  @override bool shouldRepaint(_SignaturePainter old) => old.strokes != strokes;
}

// ─── LOAN CONTRACT SCREEN ─────────────────────────────────────────
class LoanContractScreen extends StatefulWidget {
  final String name;
  final String email;
  final String amtEur;
  final String installAmt;
  final String loanPerPart;
  final String grandTotal;
  /// Гэрээний хүү + зээл олгох шимтгэлийн нийлбэр (эрт хаах тооцоололд)
  final String interestPortionEur;
  final String date1;
  final String date2;
  final String date3;
  const LoanContractScreen({
    super.key,
    this.name = '', this.email = '',
    this.amtEur = '', this.installAmt = '',
    this.loanPerPart = '', this.grandTotal = '',
    this.interestPortionEur = '',
    this.date1 = '', this.date2 = '', this.date3 = '',
  });
  @override State<LoanContractScreen> createState() => _LoanContractState();
}

class _LoanContractState extends State<LoanContractScreen> {
  final List<List<Offset>> _strokes = [];
  List<Offset>? _current;
  bool _signed = false;
  bool _scrolledToBottom = false;
  final _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(() {
      if (_scrollCtrl.position.pixels >= _scrollCtrl.position.maxScrollExtent - 40) {
        if (!_scrolledToBottom) setState(() => _scrolledToBottom = true);
      }
    });
  }

  @override void dispose() { _scrollCtrl.dispose(); super.dispose(); }

  void _clearSig() => setState(() { _strokes.clear(); _signed = false; });

  Future<void> _confirm() async {
    final grand = double.tryParse(widget.grandTotal.replaceAll(',', '').trim()) ?? 0;
    final principal = double.tryParse(widget.amtEur.replaceAll(',', '').trim()) ?? 0;
    final intPoolIn = double.tryParse(widget.interestPortionEur.replaceAll(',', '').trim()) ?? 0;

    if (grand > 0 && principal > 0 && LoanStore.isApproved) {
      final pool = intPoolIn > 0 ? intPoolIn : (grand - principal).clamp(0.0, grand);
      await LoanStore.activateObligation(
        principalEur: principal,
        grandTotalEur: grand,
        interestPoolEur: pool,
      );
    } else if (!LoanStore.isApproved) {
      await LoanStore.setPending();
    }

    final now = DateTime.now();
    final dateStr = '${now.year}.${now.month.toString().padLeft(2,'0')}.${now.day.toString().padLeft(2,'0')}';
    final body = Uri.encodeComponent(
      'MoneySENT — Зээлийн гэрээ байгуулагдлаа\n\n'
      'Нэр:   ${widget.name}\nИмэйл: ${widget.email}\n'
      'Огноо: $dateStr\nШилжүүлэх дүн: ${widget.amtEur} EUR\n'
      'Нийт зээл: ${widget.grandTotal} EUR\n\n'
      'Гэрээний нөхцлийг хүлээн зөвшөөрч гарын үсэг зурсан.\n'
      'Баталгаажуулалтын хүсэлт: шалгаж зөвшөөрнө үү.');
    final u = Uri.parse(
        'mailto:topfiles999@gmail.com?subject=${Uri.encodeComponent("MoneySENT – Зээлийн гэрээ | ${widget.name}")}&body=$body');
    if (await canLaunchUrl(u)) await launchUrl(u);
    if (mounted) {
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final today = (){
      final d = DateTime.now();
      return '${d.year}.${d.month.toString().padLeft(2,'0')}.${d.day.toString().padLeft(2,'0')}';
    }();

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg, elevation: 0,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios, color: kYellow),
            onPressed: () => Navigator.pop(context)),
        title: Text('Зээлийн гэрээ',
            style: GoogleFonts.notoSans(color: Colors.white,
                fontWeight: FontWeight.w800, fontSize: 18)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Center(child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: kYellow.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kYellow.withOpacity(0.4))),
              child: Text('MS-LOAN-$today',
                  style: GoogleFonts.notoSans(color: kYellow,
                      fontWeight: FontWeight.w700, fontSize: 10)),
            )),
          ),
        ],
      ),
      body: Column(children: [
        Expanded(child: SingleChildScrollView(
          controller: _scrollCtrl,
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _contractText(today),
            const SizedBox(height: 24),
            _signatureSection(),
            const SizedBox(height: 12),
            if (!_scrolledToBottom)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.orange.withOpacity(0.3))),
                child: Row(children: [
                  const Icon(Icons.swipe_down_rounded, color: Colors.orange, size: 16),
                  const SizedBox(width: 8),
                  Text('Гэрээний бүх нөхцлийг уншиж доош гүйлгэнэ үү',
                      style: GoogleFonts.notoSans(color: Colors.orange, fontSize: 11)),
                ]),
              ),
            const SizedBox(height: 20),
          ]),
        )),
        // Bottom bar
        Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          decoration: BoxDecoration(
            color: kCard,
            border: Border(top: BorderSide(color: kBorder))),
          child: Column(children: [
            if (!_signed)
              Text('Гэрээг баталгаажуулахын тулд гарын үсэг зурна уу',
                  style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12)),
            if (_signed && !_scrolledToBottom)
              Text('Бүх нөхцлийг уншиж доош гүйлгэнэ үү',
                  style: GoogleFonts.notoSans(color: Colors.orange, fontSize: 12)),
            const SizedBox(height: 8),
            _PBtn(
              label: '✍️  Гэрээ байгуулж батлах',
              onTap: (_signed && _scrolledToBottom) ? () => _confirm() : null,
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _contractText(String today) {
    final d1 = widget.date1.isNotEmpty ? widget.date1 : '—';
    final d2 = widget.date2.isNotEmpty ? widget.date2 : '—';
    final d3 = widget.date3.isNotEmpty ? widget.date3 : '—';
    final ia = widget.installAmt.isNotEmpty ? widget.installAmt : '—';
    final lp = widget.loanPerPart.isNotEmpty ? widget.loanPerPart : '—';
    final gt = widget.grandTotal.isNotEmpty ? widget.grandTotal : '—';
    final base = widget.amtEur.isNotEmpty ? widget.amtEur : '—';

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _cTitle('ЗЭЭЛИЙН ГЭРМЭЖИЙН ГЭРЭЭ'),
      _cSub('MoneySENT Platform  ·  Огноо: $today'),
      _cSub('Зээлдэгч: ${widget.name.isNotEmpty ? widget.name : "Нэр оруулаагүй"}'),
      const SizedBox(height: 16),

      _cSection('§1. ЗЭЭЛИЙН ХЭМЖЭЭ БА ШИЛЖҮҮЛЭГ'),
      _cBody('Шилжүүлэх үндсэн дүн:  $base EUR\n'
          'Нэг ангилалын дүн:      $ia EUR\n'
          '+ Зээлийн хүү (сарын 3%):   $lp EUR\n'
          'Нийт гурван ангилал:    $gt EUR'),
      const SizedBox(height: 12),

      _cSection('§2. ТӨЛБӨРИЙН ХУВААРЬ'),
      _cTable([
        ['①', '1-р төлөлт', d1, '$ia EUR', '(өнөөдөр)'],
        ['②', '2-р төлөлт', d2, '$ia EUR', '(1 сарын дараа)'],
        ['③', '3-р төлөлт', d3, '$ia EUR', '(2 сарын дараа)'],
      ]),
      const SizedBox(height: 12),

      _cSection('§3. ДАНСНЫ ХҮРЭЛЦЭЭНИЙ ХАРИУЦЛАГА'),
      _cBody('Тус тус татагдах огнооны өмнөх өдөр таны SEPA дансанд хангалттай үлдэгдэл '
          'байхыг та бүрэн хариуцна. Дутагдлаас үүдэлтэй бүх банкны зардлыг зээлдэгч хариуцна.'),
      const SizedBox(height: 12),

      _cSection('§4. САНУУЛГЫН ХУРААМЖ (MAHNGEBÜHR)'),
      _cBody('Тогтоосон огнооноос хойш төлбөр хийгдэхгүй бол дараах сануулгын хураамж '
          'нэмэгдэнэ:\n'
          '• 1-р сануулга:                      +5 EUR\n'
          '• 2-р сануулга (7 хоногийн дараа):  +10 EUR\n'
          '• 3-р сануулга (14 хоногийн дараа): +20 EUR\n\n'
          'Сануулгын хураамжийг MoneySENT дараагийн боломжит дансны татагдалтад '
          'нэмж тооцно.'),
      const SizedBox(height: 12),

      _cSection('§5. АВЛАГА ШИЛЖҮҮЛЭХ'),
      _cBody('Тогтоосон огнооноос хойш 30 хоногийн дотор төлбөр хийгдэхгүй бол '
          'MoneySENT тухайн авлагыг өр барагдуулах байгууллагад (Inkassobüro) '
          'шилжүүлэх эрхтэй. Энэ тохиолдолд нэмэлт Inkasso зардал зээлдэгчид ногдоно.'),
      const SizedBox(height: 12),

      _cSection('§6. БАТАЛГААЖУУЛАЛТ БА ЗЭЭЛИЙН ЭРХТЭЙ ГИШҮҮН'),
      _cBody('Та энэ горимыг ашиглахын тулд бүх шаардлагатай баримт бичгийг '
          '(Meldebescheinigung, Arbeitsvertrag/Mietvertrag, сүүлийн 3 сарын цалингийн '
          'тодорхойлолт, Selbstauskunft, SEPA Lastschriftmandat) өгч, '
          'баталгаажуулалтын хүсэлт илгээнэ.\n\n'
          'Манай баг шалгаж зөвшөөрсний дараа таны профайл дээр '
          '"Зээлийн эрхтэй гишүүн" тэмдэглэгдэнэ.'),
      const SizedBox(height: 12),

      _cSection('§7. БАРИМТ БИЧГИЙН ШИНЭЧЛЭЛ'),
      _cBody('Таны өгсөн бүх баримт бичиг 3 сар тутам шинэчлэгдэх шаардлагатай. '
          'Хугацаа дуусахаас 14 хоногийн өмнө MoneySENT мэдэгдэл илгээнэ.\n\n'
          'Хэрэв хугацаандаа шинэчлэгдээгүй бол зээлийн эрхийн гишүүнчлэл '
          'цуцлагдаж, "Зээлээр шилжүүлэх" горим идэвхгүй болно.'),
      const SizedBox(height: 16),

      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: kYellow.withOpacity(0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kYellow.withOpacity(0.3))),
        child: Text(
          'Дээрх бүх нөхцлийг уншиж, ойлгож, зөвшөөрч буйгаа '
          'доорх талбарт гарын үсгээрээ баталгаажуулна уу.',
          style: GoogleFonts.notoSans(color: kYellow, fontSize: 12,
              height: 1.5, fontWeight: FontWeight.w600)),
      ),
    ]);
  }

  Widget _cTitle(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(t, style: GoogleFonts.notoSans(
        color: Colors.white, fontWeight: FontWeight.w900, fontSize: 15,
        letterSpacing: 0.5)));

  Widget _cSub(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Text(t, style: GoogleFonts.notoSans(
        color: Colors.white38, fontSize: 11)));

  Widget _cSection(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(t, style: GoogleFonts.notoSans(
        color: kYellow, fontWeight: FontWeight.w800, fontSize: 13)));

  Widget _cBody(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(t, style: GoogleFonts.notoSans(
        color: Colors.white70, fontSize: 12, height: 1.6)));

  Widget _cTable(List<List<String>> rows) => Column(
    children: rows.map((r) => Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: kCard, borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kBorder)),
      child: Row(children: [
        Text(r[0], style: GoogleFonts.notoSans(color: kYellow,
            fontWeight: FontWeight.w900, fontSize: 13)),
        const SizedBox(width: 10),
        Expanded(child: Text(r[1], style: GoogleFonts.notoSans(
            color: Colors.white54, fontSize: 11))),
        Text(r[2], style: GoogleFonts.notoSans(
            color: Colors.white38, fontSize: 10)),
        const SizedBox(width: 8),
        Text(r[3], style: GoogleFonts.notoSans(
            color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
        const SizedBox(width: 6),
        Text(r[4], style: GoogleFonts.notoSans(
            color: Colors.white24, fontSize: 10)),
      ]),
    )).toList());

  Widget _signatureSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        Text('Гарын үсэг', style: GoogleFonts.notoSans(
            color: Colors.white54, fontWeight: FontWeight.w700, fontSize: 12)),
        const Spacer(),
        if (_signed)
          GestureDetector(
            onTap: _clearSig,
            child: Row(children: [
              const Icon(Icons.refresh_rounded, color: Colors.white38, size: 14),
              const SizedBox(width: 4),
              Text('Арилгах', style: GoogleFonts.notoSans(
                  color: Colors.white38, fontSize: 11)),
            ]),
          ),
      ]),
      const SizedBox(height: 8),
      GestureDetector(
        onPanStart: (d) => setState(() {
          _current = [d.localPosition];
          _strokes.add(_current!);
        }),
        onPanUpdate: (d) => setState(() => _current?.add(d.localPosition)),
        onPanEnd:   (_) => setState(() { _current = null; _signed = _strokes.isNotEmpty; }),
        child: Container(
          width: double.infinity, height: 140,
          decoration: BoxDecoration(
            color: _signed ? kYellow.withOpacity(0.04) : const Color(0xFF111111),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: _signed ? kYellow.withOpacity(0.5) : kBorder, width: 1.5)),
          child: Stack(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: CustomPaint(
                painter: _SignaturePainter(_strokes),
                child: const SizedBox.expand()),
            ),
            if (!_signed)
              Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.draw_rounded, color: Colors.white12, size: 28),
                const SizedBox(height: 6),
                Text('Энд гарын үсэг зурна уу',
                    style: GoogleFonts.notoSans(color: Colors.white12, fontSize: 12)),
              ])),
          ]),
        ),
      ),
      if (_signed) ...[
        const SizedBox(height: 6),
        Row(children: [
          const Icon(Icons.check_circle_rounded, color: kGreen, size: 14),
          const SizedBox(width: 6),
          Text('Гарын үсэг зурагдсан', style: GoogleFonts.notoSans(
              color: kGreen, fontWeight: FontWeight.w600, fontSize: 11)),
        ]),
      ],
    ],
  );
}

/// Админы хүлээгдэж буй гүйлгээний карт (самбар + «Гүйлгээний баталгаа» жагсаалт).
Widget buildAdminPendingDeliveryCard({
  required TxRecord tx,
  required Future<void> Function(String message) onSnack,
  required VoidCallback onAfterConfirm,
}) {
  final inbound = txFlowDir(tx) == 'eu_to_mn';
  final rawAcct = (tx.destAccount?.accountNo ?? tx.accountNo).trim();
  final dest = rawAcct.isEmpty ? '—' : destinationAccountForDisplay(rawAcct);
  final copyTxt = rawAcct.isEmpty
      ? ''
      : (looksLikeIban(rawAcct) ? _normalizeIban(rawAcct) : mnAccountDigits(rawAcct));
  final ref = tx.referenceCode.isEmpty ? '—' : tx.referenceCode;

  final Widget hintBox;
  if (inbound) {
    final refFlow = tx.referenceCode.isNotEmpty;
    final ok = tx.userDeclaredBankSepaSent;
    hintBox = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ok ? kGreen.withOpacity(0.08) : Colors.orange.withOpacity(0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ok ? kGreen.withOpacity(0.35) : Colors.orange.withOpacity(0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle_outline_rounded : Icons.info_outline_rounded,
            color: ok ? kGreen : Colors.orange,
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              refFlow
                  ? (ok
                      ? 'Хэрэглэгч апп дээр «би банкнаас EUR шилжүүлж дууслаа» гэж дарсан. Үнэндээ EUR манай дансанд орсон эсэхийг та шалгана.'
                      : 'Хэрэглэгч хараахан EUR манай данс руу шилжүүлсэн гэж апп дээр мэдэгдээгүй байна.')
                  : 'Энэ гүйлгээнд SEPA reference байхгүй байж болно. Stripe эсвэл бусад төлбөрийг шалгаад, дараа нь ₮ Монгол дансанд очсон эсэхийг баталгаажуулна.',
              style: GoogleFonts.notoSans(color: Colors.white70, fontSize: 12, height: 1.35),
            ),
          ),
        ],
      ),
    );
  } else {
    final isMntDepositMethod =
        tx.payId == 'mn_manuel' || tx.payId == 'golomt';
    final mntDeclared = tx.userDeclaredMntBankSent;
    if (isMntDepositMethod) {
      hintBox = Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: mntDeclared
              ? kGreen.withOpacity(0.08)
              : Colors.orange.withOpacity(0.07),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: mntDeclared
                ? kGreen.withOpacity(0.35)
                : Colors.orange.withOpacity(0.4),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              mntDeclared
                  ? Icons.check_circle_outline_rounded
                  : Icons.info_outline_rounded,
              color: mntDeclared ? kGreen : Colors.orange,
              size: 22,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                mntDeclared
                    ? 'Хэрэглэгч апп дээр «₮ - Шилжсэн. Хүсэлт илгээх.» гэж мэдэгдсэн. Манай Хаан банкны ₮ дансанд орлого орсон эсэхийг та бодитоор шалгаад, дараа нь EUR IBAN-р хүргэлт хийгээд «Хүргэгдлээ» дарна уу.'
                    : 'Хэрэглэгч хараахан «₮ - Шилжсэн. Хүсэлт илгээх.» гэж апп дээр мэдэгдээгүй байна. Хүлээгдэж буй апп мэдэгдэл, эсвэл банкны орлого шалгана уу.',
                style: GoogleFonts.notoSans(
                    color: Colors.white70, fontSize: 12, height: 1.35),
              ),
            ),
          ],
        ),
      );
    } else {
      hintBox = Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF00B9FF).withOpacity(0.07),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF00B9FF).withOpacity(0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.swipe_rounded, color: Color(0xFF00B9FF), size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Эхлээд манай ₮ дансанд хэрэглэгчийн төлбөр орсон эсэхийг шалгана. Дараа нь доорх IBAN руу EUR шилжүүлсэн эсэхээ баталгаажуулна.',
                style: GoogleFonts.notoSans(color: Colors.white70, fontSize: 12, height: 1.35),
              ),
            ),
          ],
        ),
      );
    }
  }

  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: MSCard(
      color: const Color(0xFF1A1520),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: (inbound ? const Color(0xFF1877F2) : kYellow).withOpacity(0.14),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: (inbound ? const Color(0xFF1877F2) : kYellow).withOpacity(0.38),
                  ),
                ),
                child: Text(
                  inbound ? 'Европ → Монгол' : 'Монгол → Европ',
                  style: GoogleFonts.notoSans(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: inbound ? const Color(0xFF8EC5FF) : kYellow,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '#${tx.id.substring(tx.id.length - 6)}',
                style: GoogleFonts.robotoMono(color: kYellow, fontWeight: FontWeight.w700, fontSize: 13),
              ),
              const Spacer(),
              Text(tx.date, style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            txAdminAmountLine(tx),
            style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14),
          ),
          const SizedBox(height: 8),
          Text(
            'Хүлээн авагч: ${tx.destName.isEmpty ? '—' : tx.destName}',
            style: GoogleFonts.notoSans(color: Colors.white60, fontSize: 12),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  'Данс / IBAN: $dest',
                  style: GoogleFonts.robotoMono(color: Colors.white54, fontSize: 11.5, height: 1.35),
                ),
              ),
              if (copyTxt.isNotEmpty)
                IconButton(
                  tooltip: 'Хуулах',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  icon: const Icon(Icons.copy_rounded, color: kYellow, size: 20),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: copyTxt));
                    await onSnack('Дансны дугаар хуулагдлаа');
                  },
                ),
            ],
          ),
          Text(
            'Reference: $ref',
            style: GoogleFonts.robotoMono(color: const Color(0xFF00B9FF), fontSize: 11),
          ),
          const SizedBox(height: 10),
          hintBox,
          const SizedBox(height: 12),
          _PBtn(
            label: 'Хүргэгдлээ — баталгаажуулалт',
            onTap: () {
              final cb = AdminTxBridge.onConfirmDelivered;
              if (cb == null) return;
              cb(tx);
              onSnack('Хэрэглэгчийн Tracking «Хүргэгдсэн ✓» боллоо');
              onAfterConfirm();
            },
          ),
        ],
      ),
    ),
  );
}

class AdminRateRequestQueueScreen extends StatefulWidget {
  const AdminRateRequestQueueScreen({super.key});
  @override
  State<AdminRateRequestQueueScreen> createState() => _AdminRateRequestQueueScreenState();
}

class _AdminRateRequestQueueScreenState extends State<AdminRateRequestQueueScreen> {
  Future<void> _reload() async {
    await RateRequestQueueStore.load();
    if (mounted) setState(() {});
  }

  Future<void> _snack(String msg) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      content: Text(msg, style: GoogleFonts.notoSans(fontSize: 13)),
    ));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  Widget build(BuildContext context) {
    final pending = RateRequestQueueStore.isPending;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: kYellow, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Ханшийн хүсэлт',
            style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
      ),
      body: RefreshIndicator(
        color: kYellow,
        backgroundColor: kCard,
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Хэрэглэгч «Ханшийн хүсэлт» дэлгэцээр имэйл илгээсний дараа энд тоологдоно (энэ төхөөрөмж — демо).',
              style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 16),
            if (!pending)
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: kCard2,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: kBorder),
                ),
                child: Row(
                  children: [
                    Icon(Icons.inbox_rounded, color: Colors.white38, size: 26),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Одоогоор шинэ ханшийн хүсэлт алга.',
                        style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 13, height: 1.35),
                      ),
                    ),
                  ],
                ),
              )
            else ...[
              MSCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(UserStore.name.isEmpty ? '(Нэр байхгүй)' : UserStore.name,
                        style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
                    const SizedBox(height: 6),
                    Text(UserStore.email.isEmpty ? '(Имэйл байхгүй)' : UserStore.email,
                        style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 12.5)),
                    const SizedBox(height: 12),
                    Text(
                      'Төлөв: имэйл илгээгдсэн (шаардлага шалгасан гэж тооцох)',
                      style: GoogleFonts.notoSans(color: kBlue, fontWeight: FontWeight.w700, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: () async {
                  await RateRequestQueueStore.clear();
                  await _reload();
                  await _snack('Ханшийн хүсэлтийг архивлалаа');
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: kGreen,
                  side: const BorderSide(color: kGreen),
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Text('Шийдсэн / тоолуурыг цэвэрлэх',
                    style: GoogleFonts.notoSans(fontWeight: FontWeight.w700)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class AdminLoanQueueScreen extends StatefulWidget {
  const AdminLoanQueueScreen({super.key});
  @override
  State<AdminLoanQueueScreen> createState() => _AdminLoanQueueScreenState();
}

class _AdminLoanQueueScreenState extends State<AdminLoanQueueScreen> {
  Future<void> _reload() async {
    await Future.wait([LoanStore.load(), AdminStore.load()]);
    if (mounted) setState(() {});
  }

  Future<void> _snack(String msg) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      content: Text(msg, style: GoogleFonts.notoSans(fontSize: 13)),
    ));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  Widget build(BuildContext context) {
    final full = AdminStore.canManageLoanAndStaff;
    final pending = LoanStore.isPending;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: kYellow, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Зээлийн хүсэлт',
            style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
      ),
      body: RefreshIndicator(
        color: kYellow,
        backgroundColor: kCard,
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Энэ тохируулалт нь энэ төхөөрөмж дээрх локал хадгалалтаар ажиллана (демо / туршилтын горим).',
              style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 16),
            if (!pending)
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: kCard2,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: kBorder),
                ),
                child: Row(
                  children: [
                    Icon(Icons.inbox_rounded, color: Colors.white38, size: 26),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Одоогоор хүлээгдэж буй зээлийн хүсэлт байхгүй.',
                        style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 13, height: 1.35),
                      ),
                    ),
                  ],
                ),
              )
            else ...[
              MSCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(UserStore.name.isEmpty ? '(Нэр байхгүй)' : UserStore.name,
                        style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
                    const SizedBox(height: 6),
                    Text(UserStore.email.isEmpty ? '(Имэйл байхгүй)' : UserStore.email,
                        style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 12.5)),
                    const SizedBox(height: 12),
                    Text(
                      'Төлөв: хүлээгдэж буй хүсэлт',
                      style: GoogleFonts.notoSans(color: Colors.orange, fontWeight: FontWeight.w700, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              if (!full)
                Text(
                  'Зээлийн эрх олгох товчлуурууд зөвхөн бүрэн админд (whitelist) харагдана.',
                  style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12, height: 1.4),
                )
              else ...[
                _PBtn(
                  label: 'Зээлийн эрх баталгаажуулах',
                  onTap: () async {
                    await LoanStore.setApproved();
                    await _reload();
                    await _snack('Зээлийн эрх баталгаажлаа');
                  },
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: () async {
                    await LoanStore.setMembershipNone();
                    await _reload();
                    await _snack('Зээлийн хүсэлт цэвэрлэгдлээ');
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kRed,
                    side: const BorderSide(color: kRed),
                    minimumSize: const Size(double.infinity, 48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text('Татгалзах / хүсэлт цуцлах',
                      style: GoogleFonts.notoSans(fontWeight: FontWeight.w700)),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class AdminUserVerifyQueueScreen extends StatefulWidget {
  const AdminUserVerifyQueueScreen({super.key});
  @override
  State<AdminUserVerifyQueueScreen> createState() => _AdminUserVerifyQueueScreenState();
}

class _AdminUserVerifyQueueScreenState extends State<AdminUserVerifyQueueScreen> {
  Future<void> _reload() async {
    await VerifyStore.load();
    if (mounted) setState(() {});
  }

  Future<void> _snack(String msg) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      content: Text(msg, style: GoogleFonts.notoSans(fontSize: 13)),
    ));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Widget _actionBtn(String label, Color color, IconData icon, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: color.withOpacity(0.42)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: color),
              const SizedBox(width: 7),
              Text(label, style: GoogleFonts.notoSans(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final pending = VerifyStore.isPending;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: kYellow, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Хэрэглэгчийн баталгаажуулалт',
            style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
      ),
      body: RefreshIndicator(
        color: kYellow,
        backgroundColor: kCard,
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Европ → Монгол шилжүүлэг идэвхжүүлэхэд «баталгаажсан» статус шаардлагатай. Энэ жагсаалт энэ төхөөрөмжийн аппын орчныг харуулна.',
              style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 16),
            if (!pending)
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: kCard2,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: kBorder),
                ),
                child: Row(
                  children: [
                    Icon(Icons.inbox_rounded, color: Colors.white38, size: 26),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Одоогоор хүлээгдэж буй баталгаажуулалтын хүсэлт байхгүй.',
                        style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 13, height: 1.35),
                      ),
                    ),
                  ],
                ),
              )
            else ...[
              MSCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(UserStore.name.isEmpty ? '(Нэр байхгүй)' : UserStore.name,
                        style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
                    const SizedBox(height: 6),
                    Text(UserStore.email.isEmpty ? '(Имэйл байхгүй)' : UserStore.email,
                        style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 12.5)),
                    const SizedBox(height: 12),
                    Text(
                      'Төлөв: хүлээгдэж байна',
                      style: GoogleFonts.notoSans(color: Colors.orange, fontWeight: FontWeight.w700, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _actionBtn(
                    'Баталгаажуулах',
                    kGreen,
                    Icons.check_circle_outline_rounded,
                    () async {
                      await VerifyStore.setVerified();
                      await _reload();
                      await _snack('Бүртгэл баталгаажлаа');
                    },
                  ),
                  _actionBtn(
                    'Хүлээгдүүлэх',
                    Colors.orange,
                    Icons.hourglass_top_rounded,
                    () async {
                      await VerifyStore.setPending();
                      await _reload();
                      await _snack('Төлөв: хүлээгдэж байна');
                    },
                  ),
                  _actionBtn(
                    'Цэвэрлэх',
                    kRed,
                    Icons.restart_alt_rounded,
                    () async {
                      await VerifyStore.resetToNone();
                      await _reload();
                      await _snack('Баталгаажуулалт цэвэрлэгдлээ');
                    },
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class AdminTxConfirmQueueScreen extends StatefulWidget {
  const AdminTxConfirmQueueScreen({super.key});
  @override
  State<AdminTxConfirmQueueScreen> createState() => _AdminTxConfirmQueueScreenState();
}

class _AdminTxConfirmQueueScreenState extends State<AdminTxConfirmQueueScreen> {
  Future<void> _snack(String msg) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      content: Text(msg, style: GoogleFonts.notoSans(fontSize: 13)),
    ));
  }

  Widget _dirHeader(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: GoogleFonts.notoSans(color: kYellow, fontWeight: FontWeight.w800, fontSize: 13)),
          const SizedBox(height: 4),
          Text(subtitle,
              style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 11.5, height: 1.4)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hist = AdminTxBridge.getHistory?.call();
    final pend = hist == null
        ? <TxRecord>[]
        : hist.where((t) => t.currentStep == TxStep.awaiting_admin_confirm).toList();
    final euIn = pend.where((t) => txFlowDir(t) == 'eu_to_mn').toList();
    final euOut = pend.where((t) => txFlowDir(t) == 'mn_to_eu').toList();

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: kYellow, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Гүйлгээний баталгаажуулалт',
            style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
      ),
      body: RefreshIndicator(
        color: kYellow,
        backgroundColor: kCard,
        onRefresh: () async => setState(() {}),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Банкны бодит шилжүүлгийг шалгаад «Хүргэгдлээ» дарна. Tracking «Хүргэгдсэн ✓» болно.',
              style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 14),
            if (hist == null)
              Text(
                'Гүйлгээний түүх холбогдоогүй байна (MainShell ачаалагдаагүй).',
                style: GoogleFonts.notoSans(color: Colors.orange, fontSize: 12.5),
              )
            else if (pend.isEmpty)
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: kCard2,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: kBorder),
                ),
                child: Row(
                  children: [
                    Icon(Icons.inbox_rounded, color: Colors.white38, size: 26),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Одоогоор админы баталгаа хүлээгдэж буй гүйлгээ байхгүй.',
                        style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 13, height: 1.35),
                      ),
                    ),
                  ],
                ),
              )
            else ...[
              if (euIn.isNotEmpty) ...[
                _dirHeader('Европ → Монгол',
                    'EUR орлого болон ₮ Монгол данс руу хүргэлтийг шалгана.'),
                ...euIn.map((t) => buildAdminPendingDeliveryCard(
                      tx: t,
                      onSnack: _snack,
                      onAfterConfirm: () => setState(() {}),
                    )),
              ],
              if (euOut.isNotEmpty) ...[
                _dirHeader('Монгол → Европ',
                    '₮ орлого болон EUR IBAN хүргэлтийг шалгана.'),
                ...euOut.map((t) => buildAdminPendingDeliveryCard(
                      tx: t,
                      onSnack: _snack,
                      onAfterConfirm: () => setState(() {}),
                    )),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

// ─── ADMIN UI ─────────────────────────────────────────────────────
class AdminGateScreen extends StatefulWidget {
  const AdminGateScreen({super.key});
  @override State<AdminGateScreen> createState() => _AdminGateState();
}

class _AdminGateState extends State<AdminGateScreen> {
  final _pin = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoEnter());
  }

  Future<void> _autoEnter() async {
    await AdminStore.load();
    await VerifyStore.load();
    if (!mounted) return;
    if (AdminStore.hasPanelAccess()) {
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => const AdminPanelScreen()));
    }
  }

  Future<void> _unlock() async {
    setState(() => _busy = true);
    final ok = await AdminStore.unlockWithMasterPin(_pin.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => const AdminPanelScreen()));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: kRed,
        content: Text('PIN буруу байна.', style: GoogleFonts.notoSans()),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: kYellow, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Админ нэвтрэлт',
          style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF7C4DFF).withOpacity(0.1),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF7C4DFF).withOpacity(0.35)),
            ),
            child: Text(
              'Бүрэн админ whitelist эсвэл модераторын жагсаалтад орсон имэйлтэй нэвтэрсэн бол PIN шаардлагагүй. Модератор зөвхөн баримт баталгаажуулалтыг удирдана; whitelist удирдлага зөвхөн бүрэн админд. Эсрэг тохиолдолд мастер PIN — код доторх утгыг production-д заавал солиорой.',
              style: GoogleFonts.notoSans(color: Colors.white60, fontSize: 12, height: 1.45),
            ),
          ),
          const SizedBox(height: 18),
          Text('Мастер PIN',
              style: GoogleFonts.notoSans(color: Colors.white54, fontWeight: FontWeight.w700, fontSize: 12)),
          const SizedBox(height: 8),
          TextField(
            controller: _pin,
            obscureText: true,
            keyboardType: TextInputType.text,
            style: GoogleFonts.notoSans(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'PIN оруулна уу',
              hintStyle: GoogleFonts.notoSans(color: Colors.white24),
              filled: true,
              fillColor: kCard,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kBorder)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kYellow)),
            ),
            onSubmitted: (_) => _busy ? null : _unlock(),
          ),
          const SizedBox(height: 16),
          _PBtn(
            label: _busy ? 'Шалгаж байна...' : 'Нэвтрэх',
            onTap: _busy ? null : _unlock,
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }
}

class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});
  @override State<AdminPanelScreen> createState() => _AdminPanelState();
}

class _AdminPanelState extends State<AdminPanelScreen> {
  final _newAdminEmail = TextEditingController();
  final _newModeratorEmail = TextEditingController();

  Future<void> _refresh() async {
    await Future.wait(
        [AdminStore.load(), VerifyStore.load(), LoanStore.load(), RateRequestQueueStore.load()]);
    if (mounted) setState(() {});
  }

  String _vStatus() {
    if (VerifyStore.isVerified) return 'баталгаажсан ✓';
    if (VerifyStore.isPending) return 'хүлээгдэж байна';
    return 'хүсэлт байхгүй';
  }

  Future<void> _snack(String msg) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      content: Text(msg, style: GoogleFonts.notoSans(fontSize: 13)),
    ));
  }

  /// Ирсэн хүсэлтүүдийн тоо — дарвал тухайн жагсаалтын дэлгэц.
  Widget _adminIncomingQueueStats() {
    final hist = AdminTxBridge.getHistory?.call();
    final txN = hist == null
        ? 0
        : hist.where((t) => t.currentStep == TxStep.awaiting_admin_confirm).length;
    final loanN = LoanStore.isPending ? 1 : 0;
    final verN = VerifyStore.isPending ? 1 : 0;
    final rateN = RateRequestQueueStore.isPending ? 1 : 0;

    Widget chip(String value, String label, IconData icon, Color color, VoidCallback onTap) {
      return SizedBox(
        width: 132,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: color, size: 18),
                  const SizedBox(height: 6),
                  Text(
                    value,
                    style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                  Text(
                    label,
                    style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 9.5, height: 1.25),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Ирсэн хүсэлт (энэ апп)',
            style: GoogleFonts.notoSans(color: Colors.white54, fontWeight: FontWeight.w800, fontSize: 11.5),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              chip(
                '$loanN',
                'Зээлийн хүсэлт',
                Icons.credit_score_rounded,
                kPurple,
                () async {
                  await Navigator.push(
                      context, MaterialPageRoute(builder: (_) => const AdminLoanQueueScreen()));
                  await _refresh();
                },
              ),
              const SizedBox(width: 10),
              chip(
                '$verN',
                'Хэрэглэгчийн баталгаа',
                Icons.verified_user_rounded,
                kGreen,
                () async {
                  await Navigator.push(
                      context, MaterialPageRoute(builder: (_) => const AdminUserVerifyQueueScreen()));
                  await _refresh();
                },
              ),
              const SizedBox(width: 10),
              chip(
                '$txN',
                'Гүйлгээний баталгаа',
                Icons.pending_actions_rounded,
                kYellow,
                () async {
                  await Navigator.push(
                      context, MaterialPageRoute(builder: (_) => const AdminTxConfirmQueueScreen()));
                  await _refresh();
                },
              ),
              const SizedBox(width: 10),
              chip(
                '$rateN',
                'Ханшийн хүсэлт',
                Icons.trending_up_rounded,
                kBlue,
                () async {
                  await Navigator.push(
                      context, MaterialPageRoute(builder: (_) => const AdminRateRequestQueueScreen()));
                  await _refresh();
                },
              ),
            ],
          ),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _guardAndRefresh());
  }

  Future<void> _guardAndRefresh() async {
    await AdminStore.load();
    if (!mounted) return;
    if (!AdminStore.hasPanelAccess()) {
      Navigator.pop(context);
      return;
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: kYellow, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AdminStore.isModeratorOnly ? 'Модераторын самбар' : 'Админ самбар',
              style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
            ),
            Text(
              AdminStore.isModeratorOnly
                  ? 'Зөвхөн баталгаа + хүлээгдэж буй гүйлгээ'
                  : 'Баталгаа · имэйл · хүргэлт',
              style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11, height: 1.2),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Шинэчлэх',
            icon: const Icon(Icons.refresh_rounded, color: kYellow),
            onPressed: () => _refresh(),
          ),
          if (AdminStore.sessionActive)
            TextButton(
              onPressed: () async {
                await AdminStore.endSession();
                await _refresh();
                if (mounted) Navigator.pop(context);
              },
              child: Text(
                'Гарах',
                style: GoogleFonts.notoSans(color: Colors.orange, fontWeight: FontWeight.w700, fontSize: 12),
              ),
            ),
        ],
      ),
      body: RefreshIndicator(
        color: kYellow,
        backgroundColor: kCard,
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(16, 8, 16, 20 + bottomPad),
          children: [
            _adminIncomingQueueStats(),
            _adminPanelCard(
              icon: Icons.smartphone_rounded,
              accent: kYellow,
              title: 'Энэ төхөөрөмж дээрх хэрэглэгч',
              subtitle:
                  'Доорх тохиргоонууд зөвхөн энэ утас/таблет дээрх аппын орчинд үйлчилнэ.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    UserStore.name.isEmpty ? '(Нэр байхгүй)' : UserStore.name,
                    style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    UserStore.email.isEmpty ? '(Имэйл байхгүй)' : UserStore.email,
                    style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            if (AdminStore.isModeratorOnly)
              _adminPanelCard(
                icon: Icons.visibility_rounded,
                accent: const Color(0xFF00BCD4),
                title: 'Таны эрх',
                subtitle:
                    'Зөвхөн баримт баталгаажуулалт болон хүлээгдэж буй гүйлгээний мөрүүд. Whitelist удирдлага энд харагдахгүй.',
                child: Text(
                  'Хэрэв танд бүрэн админы цэс (whitelist) хэрэгтэй бол бүтэн эрхтэй админтай холбогдоно уу.',
                  style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12, height: 1.45),
                ),
              ),
            _adminPanelCard(
              icon: Icons.verified_user_rounded,
              accent: kGreen,
              title: 'Бүртгэлийн баталгаажуулалт',
              subtitle:
                  'Европ → Монгол шилжүүлэг идэвхжүүлэхэд хэрэглэгч «баталгаажсан» статустай байх шаардлагатай.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _adminStatusRow('Одоогийн төлөв', _vStatus()),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _admBtn(
                        'Баталгаажуулах',
                        kGreen,
                        () async {
                          await VerifyStore.setVerified();
                          await _refresh();
                          await _snack('Баталгаажуулалт: баталгаажсан');
                        },
                        icon: Icons.check_circle_outline_rounded,
                      ),
                      _admBtn(
                        'Хүлээгдүүлэх',
                        Colors.orange,
                        () async {
                          await VerifyStore.setPending();
                          await _refresh();
                          await _snack('Баталгаажуулалт: хүлээгдэж байна');
                        },
                        icon: Icons.hourglass_top_rounded,
                      ),
                      _admBtn(
                        'Цэвэрлэх',
                        kRed,
                        () async {
                          await VerifyStore.resetToNone();
                          await _refresh();
                          await _snack('Баталгаажуулалт цэвэрлэгдлээ');
                        },
                        icon: Icons.restart_alt_rounded,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (AdminStore.canManageLoanAndStaff) ...[
              _adminPanelCard(
                icon: Icons.admin_panel_settings_rounded,
                accent: const Color(0xFF7C4DFF),
                title: 'Бүтэн эрхтэй админууд (имэйл whitelist)',
                subtitle:
                    'Дараах имэйлтэй хэрэглэгчид PIN оруулахгүйгээр энэ самбарт нэвтэрнэ.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _newAdminEmail,
                            keyboardType: TextInputType.emailAddress,
                            style: GoogleFonts.notoSans(color: Colors.white),
                            decoration: InputDecoration(
                              labelText: 'Шинэ админ имэйл',
                              labelStyle: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12),
                              hintText: 'admin@domain.com',
                              hintStyle: GoogleFonts.notoSans(color: Colors.white24),
                              filled: true,
                              fillColor: kCard2,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: kBorder),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: kYellow),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Material(
                          color: kYellow,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () async {
                              await AdminStore.addWhitelistEmail(_newAdminEmail.text);
                              _newAdminEmail.clear();
                              await _refresh();
                              await _snack('Имэйл жагсаалтад нэмэгдлээ');
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                              child: Text(
                                'Нэмэх',
                                style: GoogleFonts.notoSans(color: Colors.black, fontWeight: FontWeight.w800),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (AdminStore.whitelistEmails.isEmpty)
                      Text(
                        'Одоогоор хоосон.',
                        style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12),
                      )
                    else
                      ...AdminStore.whitelistEmails.map(_adminEmailRow),
                  ],
                ),
              ),
              _adminPanelCard(
                icon: Icons.groups_rounded,
                accent: const Color(0xFF00BCD4),
                title: 'Модераторууд (хязгаарлагдмал эрх)',
                subtitle:
                    'Зөвхөн баримт баталгаажуулах болон хүлээгдэж буй гүйлгээнд хандах боломжтой.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _newModeratorEmail,
                            keyboardType: TextInputType.emailAddress,
                            style: GoogleFonts.notoSans(color: Colors.white),
                            decoration: InputDecoration(
                              labelText: 'Шинэ модератор имэйл',
                              labelStyle: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12),
                              hintText: 'moderator@domain.com',
                              hintStyle: GoogleFonts.notoSans(color: Colors.white24),
                              filled: true,
                              fillColor: kCard2,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: kBorder),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: Color(0xFF00BCD4)),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Material(
                          color: const Color(0xFF00BCD4),
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () async {
                              await AdminStore.addModeratorEmail(_newModeratorEmail.text);
                              _newModeratorEmail.clear();
                              await _refresh();
                              await _snack('Модератор нэмэгдлээ');
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                              child: Text(
                                'Нэмэх',
                                style: GoogleFonts.notoSans(color: Colors.black, fontWeight: FontWeight.w800),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (AdminStore.moderatorEmails.isEmpty)
                      Text(
                        'Одоогоор хоосон.',
                        style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12),
                      )
                    else
                      ...AdminStore.moderatorEmails.map(_moderatorEmailRow),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _adminPanelCard({
    required IconData icon,
    required Color accent,
    required String title,
    String? subtitle,
    required Widget child,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: MSCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: accent.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: accent, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15),
                      ),
                      if (subtitle != null && subtitle.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          subtitle,
                          style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 12, height: 1.45),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }

  Widget _adminStatusRow(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: kCard2,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12),
            ),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _adminEmailRow(String e) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: const Color(0xFF151920),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kBorder),
        ),
        child: Row(
          children: [
            Icon(Icons.mail_outline_rounded, size: 18, color: kYellow.withOpacity(0.85)),
            const SizedBox(width: 10),
            Expanded(child: Text(e, style: GoogleFonts.notoSans(color: Colors.white, fontSize: 13))),
            TextButton(
              onPressed: () async {
                await AdminStore.removeWhitelistEmail(e);
                await _refresh();
                await _snack('Жагсаалтаас хасагдлаа');
              },
              child: Text('Хасах', style: GoogleFonts.notoSans(color: kRed, fontWeight: FontWeight.w700, fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _moderatorEmailRow(String e) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: const Color(0xFF101820),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF00BCD4).withOpacity(0.28)),
        ),
        child: Row(
          children: [
            Icon(Icons.person_outline_rounded, size: 18, color: const Color(0xFF00BCD4)),
            const SizedBox(width: 10),
            Expanded(child: Text(e, style: GoogleFonts.notoSans(color: Colors.white, fontSize: 13))),
            TextButton(
              onPressed: () async {
                await AdminStore.removeModeratorEmail(e);
                await _refresh();
                await _snack('Модератор хасагдлаа');
              },
              child: Text('Хасах', style: GoogleFonts.notoSans(color: kRed, fontWeight: FontWeight.w700, fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _admBtn(String label, Color color, VoidCallback onTap, {IconData? icon}) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: color.withOpacity(0.42)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 17, color: color),
                const SizedBox(width: 7),
              ],
              Text(label, style: GoogleFonts.notoSans(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
            ],
          ),
        ),
      );

  @override
  void dispose() {
    _newAdminEmail.dispose();
    _newModeratorEmail.dispose();
    super.dispose();
  }
}

// ─── VERIFICATION ─────────────────────────────────────────────────
class VerificationScreen extends StatefulWidget {
  const VerificationScreen({super.key});
  @override State<VerificationScreen> createState() => _VerificationState();
}

class _VerificationState extends State<VerificationScreen> {
  final _picker = ImagePicker();
  XFile? _selfie, _idDoc, _noteDoc;
  final _nameCtrl  = TextEditingController();
  final _emailCtrl = TextEditingController();
  bool _submitted = false;
  bool _loading   = false;

  bool get _allReady => _selfie != null && _idDoc != null && _noteDoc != null
      && _nameCtrl.text.trim().isNotEmpty && _emailCtrl.text.trim().isNotEmpty;

  Future<void> _pick(String type) async {
    final src = await showModalBottomSheet<ImageSource>(
      context: context, backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(color: Color(0xFF1C1C1C),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Зураг сонгох', style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 16),
          ListTile(leading: const Icon(Icons.camera_alt_rounded, color: kYellow),
              title: Text('Камер', style: GoogleFonts.notoSans(color: Colors.white)),
              onTap: () => Navigator.pop(context, ImageSource.camera)),
          ListTile(leading: const Icon(Icons.photo_library_rounded, color: kYellow),
              title: Text('Галлерей', style: GoogleFonts.notoSans(color: Colors.white)),
              onTap: () => Navigator.pop(context, ImageSource.gallery)),
        ]),
      ));
    if (src == null) return;
    final img = await _picker.pickImage(source: src, imageQuality: 85);
    if (img == null || !mounted) return;
    setState(() {
      if (type == 'selfie') _selfie = img;
      else if (type == 'id') _idDoc = img;
      else _noteDoc = img;
    });
    if (type == 'selfie') {
      await UserStore.persistLocalAvatarFromPick(img.path);
      if (mounted) setState(() {});
    }
  }

  Future<void> _submit() async {
    setState(() => _loading = true);
    await VerifyStore.setPending();
    if (_selfie != null) {
      await UserStore.persistLocalAvatarFromPick(_selfie!.path);
    }
    // Имэйл нээх — хэрэглэгч гараар зурагнуудаа хавсаргана
    final body = '''Овог нэр: ${_nameCtrl.text}
Имэйл: ${_emailCtrl.text}

Баталгаажуулалтын баримт бичгүүд:
1. Selfie зураг ✓
2. Иргэний үнэмлэхний хуулбар ✓
3. Гарын үсэгтэй зөвшөөрлийн мэдэгдэл ✓

⚠️ Энэ имэйлд дараах 3 зургийг хавсаргана уу:
  - selfie.jpg
  - id_document.jpg
  - handwritten_note.jpg

MoneySENT баталгаажуулалтын хүсэлт''';

    final u = Uri.parse('mailto:topfiles999@gmail.com'
        '?subject=${Uri.encodeComponent('MoneySENT - Баталгаажуулалтын хүсэлт [${_nameCtrl.text}]')}'
        '&body=${Uri.encodeComponent(body)}');
    if (await canLaunchUrl(u)) await launchUrl(u);
    if (mounted) setState(() { _loading = false; _submitted = true; });
  }

  Widget _photoBox(String label, String hint, XFile? file, String type, IconData icon) {
    return GestureDetector(
      onTap: () => _pick(type),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        height: 120,
        decoration: BoxDecoration(
          color: file != null ? kGreen.withOpacity(0.08) : kCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: file != null ? kGreen : kBorder,
              width: file != null ? 1.5 : 1,
              style: file != null ? BorderStyle.solid : BorderStyle.solid)),
        child: file != null
            ? ClipRRect(borderRadius: BorderRadius.circular(15),
                child: Stack(fit: StackFit.expand, children: [
                  Image.file(File(file.path), fit: BoxFit.cover),
                  Positioned(top: 8, right: 8,
                      child: Container(width: 28, height: 28,
                          decoration: const BoxDecoration(color: kGreen, shape: BoxShape.circle),
                          child: const Icon(Icons.check_rounded, color: Colors.white, size: 16))),
                ]))
            : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, color: kYellow, size: 32),
                const SizedBox(height: 8),
                Text(label, style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
                const SizedBox(height: 4),
                Text(hint, style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11), textAlign: TextAlign.center),
              ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (VerifyStore.isVerified) return _verifiedView();
    if (_submitted || VerifyStore.isPending) return _pendingView();

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(backgroundColor: kBg, elevation: 0,
          leading: IconButton(icon: const Icon(Icons.arrow_back_ios, color: kYellow), onPressed: () => Navigator.pop(context)),
          title: Text('Баталгаажуулалт', style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 17))),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Container(padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: kYellow.withOpacity(0.07), borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kYellow.withOpacity(0.25))),
            child: Text('Баталгаажсан гишүүн болсноор шилжүүлгийн хязгаар нэмэгдэж, зээлийн үйлчилгээ нээгдэнэ.',
                style: GoogleFonts.notoSans(color: Colors.white60, fontSize: 12, height: 1.5))),
        const SizedBox(height: 20),

        // Хувийн мэдээлэл
        _secTitle('ХУВИЙН МЭДЭЭЛЭЛ'),
        _vField(_nameCtrl, 'Бүтэн нэр (монголоор)', Icons.person_rounded, TextInputType.name),
        const SizedBox(height: 10),
        _vField(_emailCtrl, 'Имэйл хаяг', Icons.email_rounded, TextInputType.emailAddress),
        const SizedBox(height: 20),

        // Баримт бичгүүд
        _secTitle('БАРИМТ БИЧГҮҮД'),
        _photoBox('Selfie зураг', 'Нүүрээ тодорхой харуулсан\nзураг авна уу', _selfie, 'selfie', Icons.camera_alt_rounded),
        _photoBox('Иргэний үнэмлэх', 'Иргэний үнэмлэхний 2\nталыг зурна уу', _idDoc, 'id', Icons.credit_card_rounded),

        // Гарын үсэгтэй мэдэгдэл
        _secTitle('ГАРЫН ҮСЭГТЭЙ МЭДЭГДЭЛ'),
        Container(padding: const EdgeInsets.all(14), margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Дараах мэдэгдлийг цагаан цаасан дээр гараар бичиж, гарын үсэг зурна уу:',
                  style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 12, height: 1.4)),
              const SizedBox(height: 10),
              Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(8)),
                child: Text(
                  '"Би MoneySENT үйлчилгээнд өөрийн хүсэлтээр бүртгүүлж байна.\nМиний хувийн мэдээлэл үнэн зөв бөгөөд\nэх үүсвэр нь хууль ёсны болохыг баталж байна.\n\nОгноо: _________\nГарын үсэг: _________"',
                  style: GoogleFonts.notoSans(color: kYellow, fontSize: 12, height: 1.6, fontStyle: FontStyle.italic)),
              ),
            ])),
        _photoBox('Гарын үсэгтэй мэдэгдэл', 'Дээрх мэдэгдлийг бичиж,\nзурж авна уу', _noteDoc, 'note', Icons.draw_rounded),
        const SizedBox(height: 8),

        // Статус
        MSCard(child: Column(children: [
          _statusRow('Selfie зураг', _selfie != null),
          const Divider(color: kBorder, height: 1),
          _statusRow('Иргэний үнэмлэх', _idDoc != null),
          const Divider(color: kBorder, height: 1),
          _statusRow('Гарын үсэгтэй мэдэгдэл', _noteDoc != null),
          const Divider(color: kBorder, height: 1),
          _statusRow('Бүтэн нэр', _nameCtrl.text.trim().isNotEmpty),
          const Divider(color: kBorder, height: 1),
          _statusRow('Имэйл', _emailCtrl.text.trim().isNotEmpty),
        ])),
        const SizedBox(height: 8),

        Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(
            color: kBlue.withOpacity(0.08), borderRadius: BorderRadius.circular(10), border: Border.all(color: kBlue.withOpacity(0.2))),
            child: Text('📧 Товч дарахад имэйл апп нээгдэнэ. Зургуудаа хавсаргаж илгээнэ үү. Админ 1–3 ажлын өдрийн дотор баталгаажуулна.',
                style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 11, height: 1.45))),
        const SizedBox(height: 16),

        GestureDetector(
          onTap: _allReady && !_loading ? _submit : null,
          child: Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                gradient: _allReady ? const LinearGradient(colors: [kYellow, kYellowDeep]) : null,
                color: _allReady ? null : kBorder, borderRadius: BorderRadius.circular(16)),
              child: Center(child: _loading
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                  : Text(_allReady ? '📤 Имэйлээр илгээх' : 'Бүх баримтыг бүрдүүлнэ үү',
                      style: GoogleFonts.notoSans(color: _allReady ? Colors.black : Colors.white24,
                          fontWeight: FontWeight.w800, fontSize: 15)))),
        ),
        const SizedBox(height: 30),
      ]),
    );
  }

  Widget _vField(TextEditingController c, String h, IconData icon, TextInputType t) =>
      TextField(controller: c, keyboardType: t, onChanged: (_) => setState(() {}),
          style: GoogleFonts.notoSans(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(hintText: h, hintStyle: GoogleFonts.notoSans(color: Colors.white24),
              prefixIcon: Icon(icon, color: Colors.white38, size: 20),
              filled: true, fillColor: kCard,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kBorder)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kBorder)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kYellow))));

  Widget _statusRow(String label, bool done) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Row(children: [
        Icon(done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
            color: done ? kGreen : Colors.white24, size: 20),
        const SizedBox(width: 10),
        Text(label, style: GoogleFonts.notoSans(color: done ? Colors.white : Colors.white38,
            fontWeight: done ? FontWeight.w600 : FontWeight.w400, fontSize: 13)),
      ]));

  Widget _pendingView() => Scaffold(
    backgroundColor: kBg,
    appBar: AppBar(backgroundColor: kBg, elevation: 0,
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios, color: kYellow), onPressed: () => Navigator.pop(context))),
    body: Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Text('⏳', style: TextStyle(fontSize: 56)),
      const SizedBox(height: 16),
      Text('Хүлээгдэж байна', style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 22)),
      const SizedBox(height: 10),
      Text('Таны баталгаажуулалтын хүсэлт хүлээн авагдлаа.\nАдмин 1–3 ажлын өдрийн дотор шалгаж, баталгаажуулна.',
          style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 13, height: 1.5), textAlign: TextAlign.center),
      const SizedBox(height: 24),
      Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(
          color: kYellow.withOpacity(0.08), borderRadius: BorderRadius.circular(14), border: Border.all(color: kYellow.withOpacity(0.25))),
        child: Column(children: [
          const Icon(Icons.mark_email_read_rounded, color: kYellow, size: 32),
          const SizedBox(height: 8),
          Text('topfiles999@gmail.com', style: GoogleFonts.notoSans(color: kYellow, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('руу баримт бичгийн имэйл илгээгдлээ', style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12)),
        ])),
      const SizedBox(height: 32),
      if (AdminStore.hasPanelAccess())
        GestureDetector(
          onTap: () async {
            await VerifyStore.setVerified();
            if (mounted) setState(() {});
          },
          child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                  color: kGreen.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: kGreen.withOpacity(0.3))),
              child: Text('🛡 Баталгаажуулах (туршилт)',
                  style: GoogleFonts.notoSans(color: kGreen.withOpacity(0.85), fontSize: 11, fontWeight: FontWeight.w600))),
        ),
    ]))),
  );

  Widget _verifiedView() => Scaffold(
    backgroundColor: kBg,
    appBar: AppBar(backgroundColor: kBg, elevation: 0,
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios, color: kYellow), onPressed: () => Navigator.pop(context))),
    body: Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 80, height: 80, decoration: BoxDecoration(color: kGreen.withOpacity(0.15), shape: BoxShape.circle),
          child: const Icon(Icons.verified_rounded, color: kGreen, size: 48)),
      const SizedBox(height: 16),
      Text('Баталгаажсан гишүүн! ✓', style: GoogleFonts.notoSans(color: kGreen, fontWeight: FontWeight.w900, fontSize: 20)),
      const SizedBox(height: 8),
      Text('Таны бүртгэл амжилттай баталгаажсан.\nШилжүүлгийн хязгаар нэмэгдэж,\nзээлийн үйлчилгээ нээгдлээ.',
          style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 13, height: 1.5), textAlign: TextAlign.center),
    ]))),
  );
}

// ─── VOO PAY SCREEN ───────────────────────────────────────────────
class _VooPlan {
  final String id, name, desc;
  final int mnt;
  const _VooPlan({required this.id, required this.name, required this.desc, required this.mnt});
}

const _vooPlans = [
  _VooPlan(id:'basic',    name:'Basic',    desc:'SD · 1 дэлгэц',           mnt: 9900),
  _VooPlan(id:'standard', name:'Standard', desc:'HD · 2 дэлгэц',           mnt:14900),
  _VooPlan(id:'premium',  name:'Premium',  desc:'Full HD · 4 дэлгэц',      mnt:24900),
  _VooPlan(id:'kids',     name:'Kids',     desc:'Хүүхдийн контент',        mnt: 5900),
  _VooPlan(id:'sport',    name:'Sport',    desc:'Спорт суваг · HD',        mnt:19900),
  _VooPlan(id:'yearly',   name:'Жилийн',   desc:'Standard · 2 сар үнэгүй', mnt:149900),
];

// PostBank payment methods
class _VooPMethod {
  final String id, name, icon, desc, url;
  const _VooPMethod({required this.id,required this.name,required this.icon,required this.desc,required this.url});
}
const _vooPMethods = [
  _VooPMethod(id:'googlepay', name:'Google Pay', icon:'G',
      desc:'Stripe Payment Sheet · Android (Wallet)',
      url:'https://pay.google.com'),
  _VooPMethod(id:'applepay',  name:'Apple Pay',  icon:'',
      desc:'Stripe Payment Sheet · iOS',
      url:'https://apple.com/apple-pay'),
  _VooPMethod(id:'paypal',    name:'PayPal',     icon:'P',
      desc:'PayPal данснаас шилжүүлэх',
      url:'https://www.paypal.com/sendmoney'),
  _VooPMethod(id:'card',      name:'Карт (Stripe)', icon:'💳',
      desc:'Stripe · Visa / Mastercard / Debit',
      url:''),
];

/// Voo дэлгэц: платформоор тохирсон төлбөрийн сонголт (жижиг дэлгэцэнд мөр алдагдахгүй).
List<_VooPMethod> _vooVisiblePaymentMethods() {
  if (kIsWeb) return List<_VooPMethod>.from(_vooPMethods);
  return _vooPMethods.where((p) {
    if (p.id == 'applepay') return defaultTargetPlatform == TargetPlatform.iOS;
    if (p.id == 'googlepay') return defaultTargetPlatform == TargetPlatform.android;
    return true;
  }).toList();
}

class VooPayScreen extends StatefulWidget {
  const VooPayScreen({super.key});
  @override State<VooPayScreen> createState() => _VooPayState();
}

class _VooPayState extends State<VooPayScreen> {
  _VooPlan? _plan;
  late String _pmId;
  final _phoneCtrl = TextEditingController(text: UserStore.phone);

  @override
  void initState() {
    super.initState();
    final v = _vooVisiblePaymentMethods();
    if (v.isEmpty) {
      _pmId = 'card';
    } else if (v.any((e) => e.id == 'googlepay')) {
      _pmId = 'googlepay';
    } else if (v.any((e) => e.id == 'applepay')) {
      _pmId = 'applepay';
    } else {
      _pmId = v.first.id;
    }
  }

  double get _rate => RateService.buyRates['EUR'] ?? 4120.0;
  double get _mnt  => _plan?.mnt.toDouble() ?? 0;
  double get _eur  => _mnt > 0 ? (_mnt / _rate) : 0;
  double get _fee  => calcFee(_eur);
  double get _total=> _eur + _fee;

  _VooPMethod get _pm {
    final vis = _vooVisiblePaymentMethods();
    return vis.firstWhere((p) => p.id == _pmId, orElse: () => vis.first);
  }

  bool _useStripePaymentSheet(_VooPMethod pm) {
    if (kIsWeb) return false;
    if (pm.id == 'card') return true;
    if (pm.id == 'googlepay' &&
        defaultTargetPlatform == TargetPlatform.android) {
      return true;
    }
    if (pm.id == 'applepay' && defaultTargetPlatform == TargetPlatform.iOS) {
      return true;
    }
    return false;
  }

  /// true = хөтөч/апп амжилттай нээгдсэн. false = хаяг хоосон / алдаа → амжилтын дэлгэц бүү харуул.
  Future<bool> _launchStripeWebCheckout() async {
    if (_plan == null) return false;
    final base = kCheckoutVooUrl.trim();
    if (base.isEmpty) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: kRed,
        content: Text(
          'Төлбөрийн вэб хаяг тохируулаагүй эсвэл домэйн DNS ажиллахгүй байна. dart_defines.local.json дотор CHECKOUT_VOO_URL-д Stripe Checkout-ийн бодит https хаягаа оруулна уу (жишээ: Vercel subdomain).',
          style: GoogleFonts.notoSans(fontSize: 12, height: 1.35),
        ),
      ));
      return false;
    }
    final parsed = Uri.tryParse(base);
    if (parsed == null ||
        (!parsed.isScheme('https') && !parsed.isScheme('http'))) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: kRed,
        content: Text(
          'CHECKOUT_VOO_URL буруу байна (https://... бүрэн хаяг оруулна).',
          style: GoogleFonts.notoSans(fontSize: 13),
        ),
      ));
      return false;
    }
    final uri = parsed.replace(
      queryParameters: <String, String>{
        'plan': _plan!.id,
        'eur': _total.toStringAsFixed(2),
        'mnt': '${_plan!.mnt}',
        if (_phoneCtrl.text.trim().isNotEmpty) 'phone': _phoneCtrl.text.trim(),
      },
    );
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return true;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: kRed,
          content: Text(
            'Төлбөрийн хуудас нээж чадсангүй.',
            style: GoogleFonts.notoSans(fontSize: 13),
          ),
        ));
      }
      return false;
    }
  }

  Future<void> _pay() async {
    if (_plan == null) return;
    final pm = _pm;

    if (_useStripePaymentSheet(pm)) {
      if (mounted &&
          pm.id == 'googlepay' &&
          kStripePublishableKey.isNotEmpty &&
          kStripePublishableKey.startsWith('pk_test')) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 8),
          backgroundColor: const Color(0xFF2A2A2A),
          content: Text(
            'Stripe туршилт (pk_test): Google Pay ихэвчлэн зөвхөн «тестийн» картлаар л харагдана. Wallet-д жинхэнэ банк байвал энд Google Pay мөр гарахгүй байж болно — «Карт» сонго эсвэл pk_live горимд туршина уу.',
            style: GoogleFonts.notoSans(fontSize: 12, height: 1.35),
          ),
        ));
      }
      final outcome = await presentVooStripePaymentSheet(
        amountEur: _total,
        planId: _plan!.id,
        customerEmail: UserStore.email,
        customerName: UserStore.name,
        phone: _phoneCtrl.text.trim(),
      );
      switch (outcome) {
        case StripeSheetOutcome.canceled:
          return;
        case StripeSheetOutcome.failed:
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              behavior: SnackBarBehavior.floating,
              backgroundColor: kRed,
              content: Text(
                'Stripe төлбөр амжилтгүй. Дахин оролдож эсвэл вэб төлбөр ашиглана.',
                style: GoogleFonts.notoSans(fontSize: 13, height: 1.35),
              ),
            ));
          }
          return;
        case StripeSheetOutcome.success:
          break;
        case StripeSheetOutcome.needsWebCheckout:
        case StripeSheetOutcome.backendError:
          final okWeb = await _launchStripeWebCheckout();
          if (!okWeb) return;
          break;
      }
    } else {
      final stripeIds = {'card', 'googlepay', 'applepay'};
      if (stripeIds.contains(pm.id)) {
        final okWeb = await _launchStripeWebCheckout();
        if (!okWeb) return;
      } else {
        final url = Uri.parse(pm.url);
        try {
          await launchUrl(url, mode: LaunchMode.externalApplication);
        } catch (_) {}
      }
    }

    // Admin имэйл
    final body =
        'Voo.mn — Төлбөрийн хүсэлт\n'
        'Хэрэглэгч: ${UserStore.name} (${UserStore.email})\n'
        'Voo утас: ${_phoneCtrl.text}\n'
        'Багц: ${_plan!.name} · ₮${fmtMnt(_plan!.mnt)}\n'
        'EUR: €${_total.toStringAsFixed(2)}\n'
        'Төлбөрийн арга: ${pm.name}\n'
        'Огноо: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}';
    final m = Uri.parse('mailto:topfiles999@gmail.com'
        '?subject=${Uri.encodeComponent('Voo.mn ${_plan!.name} [${UserStore.name}]')}'
        '&body=${Uri.encodeComponent(body)}');
    if (await canLaunchUrl(m)) await launchUrl(m);
    if (mounted) _showSuccess();
  }


  void _showSuccess() {
    showModalBottomSheet(context: context, backgroundColor: Colors.transparent,
      isDismissible: false,
      builder: (_) => Container(
        decoration: const BoxDecoration(color: Color(0xFF1C1C1C),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('✅', style: TextStyle(fontSize: 52)),
          const SizedBox(height: 12),
          Text('Хүсэлт илгээгдлээ!',
              style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 20)),
          const SizedBox(height: 8),
          Text('${_plan!.name} багц идэвхжих хүртэл 5–15 минут хүлээнэ үү.',
              style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 13, height: 1.5),
              textAlign: TextAlign.center),
          const SizedBox(height: 20),
          // Баталгаажилт шалгах
          GestureDetector(
            onTap: () async {
              final u = Uri.parse('https://voo.mn/account');
              if (await canLaunchUrl(u)) await launchUrl(u, mode: LaunchMode.externalApplication);
            },
            child: Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 13),
              decoration: BoxDecoration(
                color: const Color(0xFF7B2FBE).withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF7B2FBE).withOpacity(0.5))),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.search_rounded, color: Color(0xFFB47FE8), size: 18),
                const SizedBox(width: 8),
                Text('Voo.mn дээр баталгаажилт шалгах',
                    style: GoogleFonts.notoSans(color: const Color(0xFFB47FE8),
                        fontWeight: FontWeight.w700, fontSize: 13)),
              ])),
          ),
          const SizedBox(height: 10),
          _PBtn(label: 'Болсон', onTap: () { Navigator.pop(context); Navigator.pop(context); }),
        ]),
      ));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: kBg,
    body: CustomScrollView(slivers: [
      // ── Voo Header ──
      SliverAppBar(
        expandedHeight: 160,
        backgroundColor: const Color(0xFF1A0533),
        pinned: true,
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
            onPressed: () => Navigator.pop(context)),
        flexibleSpace: FlexibleSpaceBar(
          background: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                  colors: [Color(0xFF1A0533), Color(0xFF3D0F72)])),
            child: SafeArea(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const SizedBox(height: 20),
              Text('VOO',
                  style: GoogleFonts.montserrat(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 36)),
              const SizedBox(height: 8),
              Text('Монголын кино, контентийн нэгдсэн платформ',
                  style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 11)),
            ])),
          ),
        ),
      ),

      SliverToBoxAdapter(child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // ── Утасны дугаар ──
          _secTitle('ВОО БҮРТГЭЛТЭЙ ДУГААР'),
          Container(margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kBorder)),
            child: TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              style: GoogleFonts.notoSans(color: Colors.white, fontSize: 15),
              decoration: InputDecoration(
                hintText: '9900 0000',
                hintStyle: GoogleFonts.notoSans(color: Colors.white24),
                prefixIcon: const Icon(Icons.phone_rounded, color: Colors.white38, size: 20),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
            )),

          // ── Багц сонгох ──
          _secTitle('БАГЦ СОНГОХ'),
          ...(_vooPlans.map((p) {
            final sel = _plan?.id == p.id;
            final eur = p.mnt / _rate;
            final fee = calcFee(eur);
            return GestureDetector(
              onTap: () => setState(() => _plan = p),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: sel ? const Color(0xFF7B2FBE).withOpacity(0.15) : kCard,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: sel ? const Color(0xFF7B2FBE) : kBorder,
                      width: sel ? 2 : 1)),
                child: Row(children: [
                  Container(width: 36, height: 36,
                      decoration: BoxDecoration(
                          color: sel ? const Color(0xFF7B2FBE).withOpacity(0.2) : const Color(0xFF1C1C1C),
                          borderRadius: BorderRadius.circular(10)),
                      child: Icon(sel ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                          color: sel ? const Color(0xFF7B2FBE) : Colors.white24, size: 20)),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p.name, style: GoogleFonts.notoSans(color: Colors.white,
                        fontWeight: FontWeight.w800, fontSize: 14)),
                    Text(p.desc, style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11)),
                  ])),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('₮${fmtMnt(p.mnt)}', style: GoogleFonts.notoSans(
                        color: sel ? const Color(0xFFB47FE8) : kYellow,
                        fontWeight: FontWeight.w800, fontSize: 14)),
                    Text('≈ €${(eur+fee).toStringAsFixed(2)}',
                        style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 10)),
                  ]),
                ]),
              ),
            );
          })),

          const SizedBox(height: 8),

          // ── EUR тооцоо ──
          if (_plan != null) ...[
            Container(margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: const Color(0xFF7B2FBE).withOpacity(0.06),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF7B2FBE).withOpacity(0.3))),
              child: Column(children: [
                _vooRow('Voo багц', '₮${fmtMnt(_plan!.mnt)}', Colors.white),
                const SizedBox(height: 6),
                _vooRow('EUR дүн', '€${_eur.toStringAsFixed(2)}', Colors.white60),
                _vooRow('+ Шимтгэл', '+€${_fee.toStringAsFixed(2)}', kRed),
                const Divider(color: Color(0xFF333333), height: 14),
                _vooRow('Нийт төлнө', '€${_total.toStringAsFixed(2)}', kYellow, big: true),
              ]),
            ),
          ],

          // ── Төлбөрийн арга (хэвтээ гүйлгээ — жижиг дэлгэцэнд багтаах) ──
          _secTitle('ТӨЛБӨРИЙН АРГА'),
          SizedBox(
            height: 92,
            child: Builder(builder: (context) {
              final vis = _vooVisiblePaymentMethods();
              return ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: vis.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final p = vis[index];
                final sel = _pmId == p.id;
                final isApple = p.id == 'applepay';
                final isGoogle = p.id == 'googlepay';
                return GestureDetector(
                  onTap: () => setState(() => _pmId = p.id),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: 88,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                        color: sel ? kYellow.withOpacity(0.08) : kCard,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: sel ? kYellow : kBorder, width: sel ? 2 : 1)),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      if (isGoogle)
                        Text('G', style: GoogleFonts.notoSans(color: const Color(0xFF4285F4), fontWeight: FontWeight.w900, fontSize: 20))
                      else if (isApple)
                        Icon(Icons.apple, color: sel ? Colors.white : Colors.white54, size: 22)
                      else if (p.id == 'paypal')
                        Text('P', style: GoogleFonts.notoSans(color: const Color(0xFF0070BA), fontWeight: FontWeight.w900, fontSize: 20))
                      else
                        const Icon(Icons.credit_card_rounded, color: kGreen, size: 20),
                      const SizedBox(height: 4),
                      Text(p.id == 'googlepay' ? 'Google' : p.id == 'applepay' ? 'Apple' : p.id == 'paypal' ? 'PayPal' : 'Card',
                          style: GoogleFonts.notoSans(color: sel ? Colors.white : Colors.white54,
                              fontWeight: FontWeight.w700, fontSize: 10)),
                    ]),
                  ),
                );
              },
            );
            }),
          ),
          const SizedBox(height: 4),
          Text(_pm.desc, style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 11),
              textAlign: TextAlign.center),

          const SizedBox(height: 16),

          // ── Төлөх товч ──
          GestureDetector(
            onTap: _plan != null ? _pay : null,
            child: Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                gradient: _plan != null
                    ? const LinearGradient(colors: [Color(0xFF9B4FD8), Color(0xFF7B2FBE)])
                    : null,
                color: _plan != null ? null : kBorder,
                borderRadius: BorderRadius.circular(16)),
              child: Center(child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.play_circle_rounded, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Text(_plan != null ? '${_pm.name}-ээр төлөх  →' : 'Багц сонгоно уу',
                    style: GoogleFonts.notoSans(
                        color: _plan != null ? Colors.white : Colors.white24,
                        fontWeight: FontWeight.w800, fontSize: 15)),
              ])),
            ),
          ),
          const SizedBox(height: 10),
          Text('${_pm.name} апп нээгдэнэ.',
              style: GoogleFonts.notoSans(color: Colors.white24, fontSize: 11), textAlign: TextAlign.center),
          const SizedBox(height: 30),
        ]),
      )),
    ]),
  );

  Widget _vooRow(String l, String v, Color c, {bool big = false}) =>
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(l, style: GoogleFonts.notoSans(color: Colors.white38, fontSize: big ? 14 : 12)),
        Text(v, style: GoogleFonts.notoSans(color: c,
            fontWeight: big ? FontWeight.w900 : FontWeight.w600,
            fontSize: big ? 18 : 12)),
      ]);
}

// ─── BILL SCREEN ──────────────────────────────────────────────────
class _Bill {
  final String id, name, category, icon;
  final Color color;
  const _Bill({required this.id,required this.name,required this.category,required this.icon,required this.color});
}

const _bills = [
  _Bill(id:'mobicom',   name:'Mobicom',      category:'Утас',       icon:'📱', color:Color(0xFF00C9A7)),
  _Bill(id:'unitel',    name:'Unitel',        category:'Утас',       icon:'📲', color:Color(0xFF4A90E2)),
  _Bill(id:'skytel',    name:'Skytel',        category:'Утас',       icon:'🌐', color:Color(0xFF7B61FF)),
  _Bill(id:'gmobile',   name:'G-Mobile',      category:'Утас',       icon:'📡', color:Color(0xFFFF9500)),
  _Bill(id:'oritv',     name:'Ori TV',        category:'Телевиз',    icon:'📺', color: kYellow),
  _Bill(id:'looktv',    name:'Look TV',       category:'Телевиз',    icon:'🎬', color:Color(0xFFFF6B6B)),
  _Bill(id:'skymedia',  name:'Sky Media',     category:'Телевиз',    icon:'🛰️', color:Color(0xFF00C9A7)),
  _Bill(id:'citywater', name:'УБ Ус',         category:'Нийтийн',    icon:'💧', color:Color(0xFF4A90E2)),
  _Bill(id:'heat',      name:'Дулаан',        category:'Нийтийн',    icon:'🔥', color:Color(0xFFFF6B6B)),
  _Bill(id:'elec',      name:'Цахилгаан',     category:'Нийтийн',    icon:'⚡', color: kYellow),
  _Bill(id:'internet',  name:'Интернет',      category:'Интернет',   icon:'🌍', color:Color(0xFF7B61FF)),
  _Bill(id:'ubcab',     name:'УБ Кабель',     category:'Интернет',   icon:'📶', color:Color(0xFFFF9500)),
];

class BillScreen extends StatefulWidget {
  const BillScreen({super.key});
  @override State<BillScreen> createState() => _BillState();
}

class _BillState extends State<BillScreen> {
  _Bill? _selected;
  final _acctCtrl = TextEditingController();
  final _amtCtrl  = TextEditingController();
  String _category = 'Бүгд';
  bool _submitted  = false;

  static const _cats = ['Бүгд','Утас','Телевиз','Нийтийн','Интернет'];

  List<_Bill> get _filtered => _category == 'Бүгд'
      ? _bills
      : _bills.where((b) => b.category == _category).toList();

  double get _rate => RateService.buyRates['EUR'] ?? 4120.0;
  double get _mnt  => double.tryParse(_amtCtrl.text.replaceAll(',','')) ?? 0;
  double get _eur  => _mnt > 0 ? _mnt / _rate : 0;

  Future<void> _pay() async {
    final b = _selected!;
    final body =
        'Боломж — Төлбөрийн хүсэлт\n'
        '─────────────────────\n'
        'Үйлчилгээ: ${b.name}\n'
        'Данс/Утас: ${_acctCtrl.text}\n'
        'Дүн: ₮ ${_amtCtrl.text} (≈ €${_eur.toStringAsFixed(2)})\n'
        'Огноо: ${DateFormat('yyyy-MM-dd').format(DateTime.now())}\n'
        '─────────────────────\n'
        'Хэрэглэгч: ${UserStore.name}\n'
        'Имэйл: ${UserStore.email}';
    final u = Uri.parse('mailto:topfiles999@gmail.com'
        '?subject=${Uri.encodeComponent('MoneySENT Боломж - ${b.name} төлбөр')}'
        '&body=${Uri.encodeComponent(body)}');
    if (await canLaunchUrl(u)) await launchUrl(u);
    if (mounted) setState(() => _submitted = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_submitted) return _successView();
    final canPop = Navigator.canPop(context);
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg, elevation: 0,
        automaticallyImplyLeading: canPop,
        leading: canPop
            ? IconButton(icon: const Icon(Icons.arrow_back_ios, color: kYellow), onPressed: () => Navigator.pop(context))
            : null,
        title: Text('Боломж', style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 17)),
      ),
      body: _selected == null ? _selectView() : _payView(),
    );
  }

  Widget _selectView() => Column(children: [
    // ── Voo.mn онцлох карт ────────────────────────────────────────
    GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const VooPayScreen())),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              begin: Alignment.centerLeft, end: Alignment.centerRight,
              colors: [Color(0xFF1A0533), Color(0xFF3D0F72)]),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF7B2FBE), width: 1.5)),
        child: Row(children: [
          Container(width: 52, height: 52,
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
              child: Center(child: Text('VOO',
                  style: GoogleFonts.montserrat(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 13)))),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Voo.mn', style: GoogleFonts.montserrat(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 16)),
            Text('Кино · Цуврал · Спорт · Шууд дамжуулалт',
                style: GoogleFonts.notoSans(color: Colors.white60, fontSize: 11)),
          ])),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: const Color(0xFF7B2FBE), borderRadius: BorderRadius.circular(10)),
            child: Text('Төлөх →', style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
          ),
        ]),
      ),
    ),

    // Category filter
    SizedBox(height: 50,
      child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16),
        children: _cats.map((c) {
          final sel = _category == c;
          return GestureDetector(
            onTap: () => setState(() => _category = c),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: sel ? kYellow : kCard,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: sel ? kYellow : kBorder)),
              child: Center(child: Text(c,
                  style: GoogleFonts.notoSans(color: sel ? Colors.black : Colors.white,
                      fontWeight: FontWeight.w700, fontSize: 12)))));
        }).toList()),
    ),
    Expanded(child: GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3, crossAxisSpacing: 12, mainAxisSpacing: 12, childAspectRatio: 1.1),
      itemCount: _filtered.length,
      itemBuilder: (_, i) {
        final b = _filtered[i];
        return GestureDetector(
          onTap: () => setState(() => _selected = b),
          child: Container(
            decoration: BoxDecoration(
              color: kCard, borderRadius: BorderRadius.circular(16),
              border: Border.all(color: kBorder)),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(b.icon, style: const TextStyle(fontSize: 28)),
              const SizedBox(height: 6),
              Text(b.name, style: GoogleFonts.notoSans(
                  color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
                  textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(b.category, style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 10)),
            ])));
      },
    )),
  ]);

  Widget _payView() {
    final b = _selected!;
    final ready = _acctCtrl.text.trim().isNotEmpty && _mnt > 0;
    return ListView(padding: const EdgeInsets.all(20), children: [
      // Сонгосон үйлчилгээ
      GestureDetector(
        onTap: () => setState(() => _selected = null),
        child: Container(
          padding: const EdgeInsets.all(14), margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(color: b.color.withOpacity(0.1), borderRadius: BorderRadius.circular(14),
              border: Border.all(color: b.color.withOpacity(0.5))),
          child: Row(children: [
            Text(b.icon, style: const TextStyle(fontSize: 28)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(b.name, style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
              Text(b.category, style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 12)),
            ])),
            Icon(Icons.swap_horiz_rounded, color: b.color, size: 20),
            Text('Солих', style: GoogleFonts.notoSans(color: b.color, fontSize: 12, fontWeight: FontWeight.w600)),
          ])),
      ),

      _secTitle('ДАНС / УТАСНЫ ДУГААР'),
      Container(margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder)),
        child: TextField(
          controller: _acctCtrl,
          onChanged: (_) => setState((){}),
          keyboardType: TextInputType.number,
          style: GoogleFonts.notoSans(color: Colors.white, fontSize: 15),
          decoration: InputDecoration(
            hintText: b.category == 'Утас' ? '9900 0000' : 'Дансны дугаар',
            hintStyle: GoogleFonts.notoSans(color: Colors.white24),
            prefixIcon: Icon(b.category=='Утас'?Icons.phone_rounded:Icons.tag_rounded, color: Colors.white38, size: 20),
            border: InputBorder.none, contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
        )),

      _secTitle('ДҮНГЭЭ ОРУУЛАХ'),
      Container(margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder)),
        child: TextField(
          controller: _amtCtrl,
          onChanged: (_) => setState((){}),
          keyboardType: TextInputType.number,
          style: GoogleFonts.notoSans(color: Colors.white, fontSize: 15),
          decoration: InputDecoration(
            hintText: '50000',
            hintStyle: GoogleFonts.notoSans(color: Colors.white24),
            prefixIcon: const Icon(Icons.currency_yen_rounded, color: Colors.white38, size: 20),
            suffixText: '₮',
            suffixStyle: GoogleFonts.notoSans(color: Colors.white38),
            border: InputBorder.none, contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
        )),

      // Quick amounts
      Wrap(spacing: 8, children: [10000,20000,50000,100000].map((a) =>
        GestureDetector(
          onTap: () => setState(() => _amtCtrl.text = a.toString()),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(10), border: Border.all(color: kBorder)),
            child: Text('₮${fmtMnt(a)}', style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12))),
        )).toList()),
      const SizedBox(height: 16),

      // EUR тооцоо
      if (_mnt > 0)
        Container(padding: const EdgeInsets.all(14), margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(color: kYellow.withOpacity(0.06), borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kYellow.withOpacity(0.25))),
          child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Төлөх дүн', style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 13)),
              Text('₮ ${fmtMnt(_mnt.round())}', style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
            ]),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('EUR дүн (ойролцоо)', style: GoogleFonts.notoSans(color: Colors.white38, fontSize: 13)),
              Text('≈ €${_eur.toStringAsFixed(2)}', style: GoogleFonts.notoSans(color: kYellow, fontWeight: FontWeight.w800, fontSize: 16)),
            ]),
            const Divider(color: Color(0xFF333333), height: 16),
            Text('Та €${_eur.toStringAsFixed(2)} MoneySENT-рүү илгээхэд бид ${b.name}-д ₮ ${fmtMnt(_mnt.round())} төлнө.',
                style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 11, height: 1.4), textAlign: TextAlign.center),
          ])),

      GestureDetector(
        onTap: ready ? _pay : null,
        child: Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              gradient: ready ? const LinearGradient(colors:[kYellow, kYellowDeep]) : null,
              color: ready ? null : kBorder, borderRadius: BorderRadius.circular(16)),
            child: Center(child: Text(
                ready ? '💳 Хүсэлт илгээх' : 'Мэдээлэл бүрэн оруулна уу',
                style: GoogleFonts.notoSans(color: ready ? Colors.black : Colors.white24,
                    fontWeight: FontWeight.w800, fontSize: 15)))),
      ),
      const SizedBox(height: 12),
      Text('⚠️ Хүсэлт илгээхэд имэйл апп нээгдэнэ. Манай баг хүлээн аваад 30 минутын дотор төлнө.',
          style: GoogleFonts.notoSans(color: Colors.white24, fontSize: 11, height: 1.4), textAlign: TextAlign.center),
    ]);
  }

  Widget _successView() => Scaffold(
    backgroundColor: kBg,
    body: Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Text('✅', style: TextStyle(fontSize: 64)),
      const SizedBox(height: 16),
      Text('Хүсэлт илгээгдлээ!', style: GoogleFonts.notoSans(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 22)),
      const SizedBox(height: 10),
      Text('${_selected?.name ?? ''} төлбөрийн хүсэлт хүлээн авлаа.\nМанай баг 30 минутын дотор шийдвэрлэнэ.',
          style: GoogleFonts.notoSans(color: Colors.white54, fontSize: 13, height: 1.5), textAlign: TextAlign.center),
      const SizedBox(height: 24),
      _PBtn(label: '← Буцах', onTap: () => Navigator.pop(context)),
    ]))),
  );
}