@echo off
REM ============================================================
REM  Handpan Practice v0.9 - Windows build script
REM  Requires: JDK 17+, Python 3, Android build-tools, android.jar, R8
REM  See the build instructions document for details.
REM ============================================================
setlocal
set ROOT=%~dp0
set TOOLS=%ROOT%tools
if defined HP_TOOLS set TOOLS=%HP_TOOLS%
set APP=%ROOT%app
set OUT=%ROOT%out
set SDK=%TOOLS%\android-35\android.jar
set BT=%TOOLS%\android-14
set KS=%ROOT%keystore\development.keystore

where javac >nul 2>nul || (echo [ERROR] javac not found. Install JDK 17+ and add it to PATH. & exit /b 1)
if not exist "%SDK%" (echo [ERROR] missing %SDK% & exit /b 1)
if not exist "%BT%\aapt2.exe" (echo [ERROR] missing build-tools: %BT% & exit /b 1)
if not exist "%TOOLS%\r8.jar" (echo [ERROR] missing %TOOLS%\r8.jar & exit /b 1)

REM Signing keys are local-only and are not published.
if not exist "%ROOT%keystore" mkdir "%ROOT%keystore"
if not exist "%KS%" (
  keytool -genkeypair -keystore "%KS%" -alias androiddebugkey -storepass android -keypass android -dname "CN=Android Debug,O=Android,C=US" -keyalg RSA -keysize 2048 -validity 10000 || goto :err
)

if not exist "%OUT%" mkdir "%OUT%"
if exist "%OUT%\classes" rmdir /s /q "%OUT%\classes"
mkdir "%OUT%\classes"

echo [1/6] javac
javac -encoding UTF-8 -nowarn --release 11 -classpath "%SDK%" -d "%OUT%\classes" ^
  "%APP%\cn\handpan\practice\MainActivity.java" ^
  "%APP%\cn\handpan\practice\Protocol.java" ^
  "%APP%\cn\handpan\practice\PracticeSongs.java" ^
  "%APP%\cn\handpan\practice\PositionMap.java" ^
  "%APP%\cn\handpan\practice\Song.java" || goto :err

echo [2/6] d8
if exist "%OUT%\dex" rmdir /s /q "%OUT%\dex"
mkdir "%OUT%\dex"
jar cf "%OUT%\app.jar" -C "%OUT%\classes" . || goto :err
java -cp "%TOOLS%\r8.jar" com.android.tools.r8.D8 --min-api 21 --lib "%SDK%" --output "%OUT%\dex" "%OUT%\app.jar" || goto :err

echo [3/6] aapt2
if exist "%OUT%\base.apk" del "%OUT%\base.apk"
if exist "%OUT%\res.zip" del "%OUT%\res.zip"
pushd "%APP%"
"%BT%\aapt2.exe" compile --dir res -o "%OUT%\res.zip" || (popd & goto :err)
popd
"%BT%\aapt2.exe" link -o "%OUT%\base.apk" --manifest "%APP%\AndroidManifest.xml" -I "%SDK%" "%OUT%\res.zip" -0 wav --min-sdk-version 21 --target-sdk-version 33 --version-code 10 --version-name 0.9 || goto :err

echo [4/6] package
python "%ROOT%pack.py" || goto :err

echo [5/6] zipalign
"%BT%\zipalign.exe" -f -p 4 "%OUT%\unsigned.apk" "%OUT%\aligned.apk" || goto :err

echo [6/6] sign
call "%BT%\apksigner.bat" sign --ks "%KS%" --ks-key-alias androiddebugkey --ks-pass pass:android --key-pass pass:android --out "%OUT%\HandpanPractice-v0.9.apk" "%OUT%\aligned.apk" || goto :err

echo BUILD OK: %OUT%\HandpanPractice-v0.9.apk
exit /b 0

:err
echo BUILD FAILED
exit /b 1
