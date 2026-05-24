@echo off
REM MoneySENT — launcher icon үүсгэх (заавал LOCAL компьютер дээр ажиллуулна)
cd /d "%~dp0"

if not exist "assets\logo.png" (
  echo [АЛДАА] assets\logo.png олдсонгүй. PNG логоо энэ замд хадгална уу.
  pause
  exit /b 1
)

echo Flutter packages...
call flutter pub get
if errorlevel 1 goto err

echo Launcher icons үүсгэж байна...
call dart run flutter_launcher_icons
if errorlevel 1 goto err

echo.
echo БОЛСОН. Дараа нь заавал:
echo   flutter clean
echo   flutter run
echo.
pause
exit /b 0

:err
echo [АЛДАА] Дээрх командууд амжилтгүй. Terminal-оос гарсан бүтэн алдааг хадгална уу.
pause
exit /b 1
