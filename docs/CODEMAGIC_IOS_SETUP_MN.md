# Codemagic + Apple iOS (IPA) тохируулга

Cursor дотор энэ файлыг нээж, доорх алхмуудыг **өөрийн браузерт** Codemagic / Apple дээр дагана.

Би (агент) Codemagic эсвэл Apple-д таны нэрээр нэвтрэж орж чадахгүй — нууцлагдмал түлхүүр, 2FA таныхаар дамжина.

---

## 1. Apple Developer Programs

1. https://developer.apple.com/account → Identifiers → `com.topfilesLLC.Moneysent` байгааг шалга.
2. Certificates, IDs & Profiles → **Profiles** → **App Store** төрөл, тэр Bundle ID-д зориулсан profile байгааг шалга.

---

## 2. App Store Connect API key (.p8)

1. https://appstoreconnect.apple.com → Users and Access → Integrations → **App Store Connect API**.
2. **Key** үүсгэж `.p8` татаж авна (**зөвхөн нэг удаа**).
3. **Issuer ID**, **Key ID**-гаа түр хуулна.

---

## 3. Codemagic Team (хамгийн чухал: Code signing identities)

1. https://codemagic.io → **Team settings** → **Codemagic.yaml settings** → **Code signing identities**.
2. **Developer Portal** → **Manage keys** → өмнөх `.p8` оруулж хадгална.
3. **iOS certificates**:
   - **Generate** эсвэл **Upload** (`Apple Distribution` / App Store-д зориулсан).
4. **iOS provisioning profiles**:
   - **Fetch profiles** эсвэл `.mobileprovision` upload — **App Store** profile, Bundle `com.topfilesLLC.Moneysent`.
5. Жагсаалтанд profile-ийн **Certificate** хэсэгт ногоон тэмдэг (cert-тай таарсан)-ийг харна.

Репоны `codemagic.yaml`-д аль хэдийн:

```yaml
ios_signing:
  distribution_type: app_store
  bundle_identifier: com.topfilesLLC.Moneysent
```

байгаа тохиолдолд Codemagic эндхээс **татан** build дээр keychain суулгадаг.

---

## 4. Codemagic Application — YAML уншуулах

IPA build логонд зөвхөн `flutter build ipa` байвал **YAML ажилаагүй** байгаа билээ.

Шалга:

- Аппыг зөөх **branch** дээр `codemagic.yaml` **репо root** (`moneysent/`)-д байгаа эсэх.
- Codemagic → апп → **repository / workflow**: **Configuration as code** эсвэл `codemagic.yaml`-аас ажлуулдаг байх (`ios-release` workflow).

---

## 5. Шалгалт дахин build

Build амжилттай болсон эсэхийг шалгахад логоор `flutter pub get`, `pod install`, `xcode-project use-profiles`, дараа нь `flutter build ipa --export-method app-store` (олон хувилбарт `--release` шаардлагагүй — байхгүй бол алдаанаас авна) гэж алхмууд дарааллаар орсон байх ёстой.

Алдаа гарвал **Set up code signing identities** ба **Build signed IPA** алхмуудын **бүтэн логийг** буулгаж үлдээ.

---

## Албан баримтууд

- [Codemagic: Signing iOS apps](https://docs.codemagic.io/yaml-code-signing/signing-ios/)
