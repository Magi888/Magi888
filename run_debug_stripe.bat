@echo off
cd /d "%~dp0"
if not exist dart_defines.local.json (
  echo [Алдаа] dart_defines.local.json байхгүй байна.
  echo dart_defines.local.example.json файлыг хуулж dart_defines.local.json болгоод pk_test түлхүүрээ оруулна уу.
  exit /b 1
)
flutter run --dart-define-from-file=dart_defines.local.json
