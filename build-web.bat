@echo off
setlocal enabledelayedexpansion

if not exist web mkdir web

for /f "delims=" %%i in ('odin root') do set "ODIN_PATH=%%i"

echo Building...
odin build . -debug -target:js_wasm32 -out:web/module.wasm %*

if %ERRORLEVEL% neq 0 (
    exit /b %ERRORLEVEL%
)

echo Copying runtime...
copy "%ODIN_PATH%\core\sys\wasm\js\odin.js" "web\odin.js" /Y

echo Done!
