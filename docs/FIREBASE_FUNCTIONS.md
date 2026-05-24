# Firebase Cloud Functions (Stripe PaymentIntent)

MoneySENT Flutter аппын `stripe_payment.dart` нь **POST** хүсэлтээр `amount_cents`, `currency` илгээж, хариуд **`client_secret`** хүлээнэ. Энэ функц түүнийг сервер дээр Stripe `sk_` түлхүүрээр үүсгэнэ.

## Шаардлага

- **Firebase** төсөл (console.firebase.google.com)
- Төлөвлөгөө: **Blaze** (Stripe руу гадагш явах сүлжээний хувьд Cloud Functions ихэнх тохиолдолд шаардлагатай)
- [Firebase CLI](https://firebase.google.com/docs/cli): `npm install -g firebase-tools`

## 1. Firebase төсөл холбох

Төслийн үндсэн хавтаснаас:

```bash
firebase login
firebase use --add
```

### Алдаа: `Invalid project id: YOUR_FIREBASE_PROJECT_ID`

`.firebaserc` дээр жинхэнэ төсөл холбоогүй байна. Дараагийн командуудыг **`moneysent` үндсэн хавтаснаас** (аль `firebase.json` байгаа газраас) ажиллуулна:

```bash
cd C:\Users\maag8\StudioProjects\moneysent
firebase login
firebase use --add
```

Жагсаалтаас төслөө сонгоход `.firebaserc` автоматаар шинэчлэгдэнэ. Firebase **Project ID** нь ихэвчлэн жижиг үсэг (`my-app-123a`) байдаг.

## 2. Stripe нууц түлхүүр (Secret)

**Энэ түлхүүрийг Git-д бүү хийнэ.**

Мөн үндсэн хавтаснаас:

```bash
firebase functions:secrets:set STRIPE_SECRET_KEY
```

Дараа нь `sk_test_...` эсвэл `sk_live_...`-ээ буулгаад Enter.

## 3. Сонголттой: Bearer нууцлал

Хэрэв Flutter талдаа `STRIPE_BACKEND_BEARER` (`dart_defines.local.json`) бөглөсөн бол функц дээр ижил утгыг **parameter** болгон өгнө.

`functions` хавтас дотор `.env` файл үүсгэ (`.gitignore`-д орсон):

```env
BACKEND_BEARER=өөрийн_нууц_танхимын_түлхүүр
```

Эсвэл deploy үед Firebase CLI параметрийг асах үед оруулна (Firebase Params документ).

Апп ба функц хоёулаад ижил `Bearer …` ашиглана.

## 4. Суулгах ба шалгах

```bash
cd functions
npm install
npm run build
```

## 5. Deploy

Төслийн үндсэн хавтаснаас:

```bash
firebase deploy --only functions:createPaymentIntent
```

Эсвэл бүх функц:

```bash
firebase deploy --only functions
```

Анх удаа **secret** ашигласан үед Cloud-д Secret холбох зөвшөөрөл асах болно (`--force` гэх мэт заавар CLI харуулна).

## 6. Flutter `dart_defines.local.json`

Функцийн **HTTP URL** (жишээ бүтэц):

```text
https://europe-west3-<PROJECT_ID>.cloudfunctions.net/createPaymentIntent
```

Жинхэнэ хаягийг Firebase Console → Functions эсвэл deploy-ийн гаралтын дараа хуулна.

`dart_defines.local.example.json`-тай адил:

```json
{
  "STRIPE_PUBLISHABLE_KEY": "pk_test_...",
  "STRIPE_PAYMENT_INTENT_URL": "https://europe-west3-YOUR_FIREBASE_PROJECT_ID.cloudfunctions.net/createPaymentIntent",
  "STRIPE_BACKEND_BEARER": "",
  "CHECKOUT_VOO_URL": ""
}
```

`STRIPE_BACKEND_BEARER`-ийг functions `.env` дээрх `BACKEND_BEARER`-тэй тааруулж бөглөөгүй бол хоосон орхино.

Аппыг:

```bash
flutter run --dart-define-from-file=dart_defines.local.json
```

## Эмулятор

```bash
cd functions
npm run serve
```

Локалд Stripe secret эмуляторт тохируулах зааврыг [Firebase docs — secrets emulator](https://firebase.google.com/docs/functions/config-env)-ээс үзнэ үү.

## Бүс (region)

Одоо **`europe-west3`** (Frankfurt) тохируулсан. Өөрчлөх бол `functions/src/index.ts` дотор `region`-ийг солиод дахин deploy хийнэ. URL дахь бүсийн нэр ч өөрчлөгдөнө.
