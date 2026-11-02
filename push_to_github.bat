@echo off
setlocal
chcp 65001 >nul
echo ========================================================
echo   Zontes RideScreen iOS - Push to GitHub for Cloud Build
echo ========================================================
echo.

set GIT_EXE="%~dp0..\tools\git\cmd\git.exe"

if not exist %GIT_EXE% (
    echo [ERROR] Git not found at %GIT_EXE%
    pause
    exit /b 1
)

echo โปรดใส่ GitHub Repository URL ของคุณ (เช่น https://github.com/your-username/zontes-ios.git)
set /p REPO_URL="Repo URL: "

if "%REPO_URL%"=="" (
    echo [ERROR] ไม่ได้ระบุ URL ยกเลิกการทำงาน
    pause
    exit /b 1
)

cd /d "%~dp0"

echo.
echo [1/3] กำลังตั้งค่า Remote...
%GIT_EXE% remote remove origin 2>nul
%GIT_EXE% remote add origin %REPO_URL%

echo [2/3] กำลังเตรียม Branch main...
%GIT_EXE% branch -M main

echo [3/3] กำลัง Push โค้ดขึ้น GitHub...
echo (หากมีหน้าต่างถาม ให้เข้าสู่ระบบ GitHub หรือใส่ Personal Access Token)
%GIT_EXE% push -u origin main

if %ERRORLEVEL% EQU 0 (
    echo.
    echo ========================================================
    echo   [สำเร็จ!] โค้ดถูกส่งขึ้น GitHub เรียบร้อยแล้ว
    echo   ระบบ GitHub Actions บน macOS กำลังเริ่มบิลด์ไฟล์ .ipa ให้คุณ
    echo   ให้เข้าไปที่แท็บ 'Actions' ในหน้าเว็บ GitHub ของคุณ เพื่อดูสถานะ
    echo ========================================================
) else (
    echo.
    echo [ข้อผิดพลาด] ไม่สามารถ Push ได้ โปรดตรวจสอบ URL หรือสิทธิ์การเข้าถึง
)

echo.
pause
