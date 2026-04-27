@echo off
chcp 65001 >nul
title qustion_researcher Windows Release Build
echo ============================================
echo  qustion_researcher Windows Release Build
echo ============================================
echo.

:: 设置当前目录为脚本所在目录
cd /d "%~dp0"

:: Step 1: 清理
echo [1/4] 清理之前的构建缓存...
call flutter clean >nul 2>&1
if %errorlevel% neq 0 (
    echo 清理完成或有部分残留（可忽略）
) else (
    echo 清理完成
)

:: Step 2: 拉取依赖
echo [2/4] 拉取依赖包...
call flutter pub get
if %errorlevel% neq 0 (
    echo [错误] flutter pub get 失败！
    pause
    exit /b 1
)
echo 依赖拉取完成
echo.

:: Step 3: 编译 Release
echo [3/4] 编译 Windows Release 版本（可能需要几分钟）...
call flutter build windows --release
if %errorlevel% neq 0 (
    echo [错误] 编译失败！
    pause
    exit /b 1
)
echo 编译成功
echo.

:: Step 4: 打包产物到 release 目录
echo [4/4] 打包产物到 release\ 目录...

set SRC_DIR=build\windows\x64\runner\Release
set DST_DIR=release

:: 删除旧的 release 目录
if exist "%DST_DIR%" rmdir /s /q "%DST_DIR%"
mkdir "%DST_DIR%"

:: 复制 exe 和 dll
copy "%SRC_DIR%\qustion_researcher.exe" "%DST_DIR%\" >nul
echo   - qustion_researcher.exe
copy "%SRC_DIR%\flutter_windows.dll" "%DST_DIR%\" >nul
echo   - flutter_windows.dll
copy "%SRC_DIR%\flutter_secure_storage_windows_plugin.dll" "%DST_DIR%\" >nul
echo   - flutter_secure_storage_windows_plugin.dll
copy "%SRC_DIR%\file_selector_windows_plugin.dll" "%DST_DIR%\" >nul
echo   - file_selector_windows_plugin.dll
copy "%SRC_DIR%\sqlite3.dll" "%DST_DIR%\" >nul
echo   - sqlite3.dll

:: 复制 data 目录
xcopy "%SRC_DIR%\data" "%DST_DIR%\data\" /e /i /q /y >nul
echo   - data\ (运行时资源)

echo.
echo ============================================
echo  构建完成！
echo  产物路径: %~dp0%DST_DIR%\
echo  可执行文件: %DST_DIR%\qustion_researcher.exe
echo ============================================
echo.

pause