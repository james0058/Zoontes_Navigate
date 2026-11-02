@echo off
setlocal
chcp 65001 >nul
echo ========================================================
echo   Zontes RideScreen iOS - Push to GitHub for Cloud Build
echo ========================================================
echo.

set GIT_EXE="%~dp0..\tools\git\cmd\git.exe"
set REPO_URL=https://github.com/james0058/Zoontes_Navigate.git

if not exist %GIT_EXE% (
    echo [ERROR] Git not found at %GIT_EXE%
    pause
    exit /b 1
)

cd /d "%~dp0"

echo Repository: %REPO_URL%
echo.
echo [1/3] กำลังตั้งค่า Remote origin...
%GIT_EXE% remote remove origin 2>nul
%GIT_EXE% remote add origin %REPO_URL%

echo [2/3] กำลังตั้ง Branch main...
%GIT_EXE% branch -M main

echo [3/3] กำลังส่งโค้ดทั้งหมดขึ้น GitHub...
echo ********************************************************
echo  หากมีหน้าต่างถาม ให้เข้าสู่ระบบ GitHub หรือกรอก Token
echo ********************************************************
echo.

%GIT_EXE% push -u origin main

if %ERRORLEVEL% EQU 0 (
    echo.
    echo ========================================================
    echo   [สำเร็จ!] โค้ดทั้งหมดถูกส่งขึ้น GitHub เรียบร้อยแล้ว
    echo.
    echo   ขั้นตอนต่อไป:
    echo   1. เปิดเว็บ: https://github.com/james0058/Zoontes_Navigate/actions
    echo   2. คุณจะเห็นระบบเริ่มทำการ Build บน macOS ให้ทันที
    echo   3. รอ 3-5 นาที เมื่อเสร็จแล้ว เลื่อนลงมาล่างสุด
    echo      ดาวน์โหลดไฟล์ 'RideScreen-iOS-IPA' ได้เลยครับ!
    echo ========================================================
) else (
    echo.
    echo [คำแนะนำ] หากติดปัญหาเรื่องสิทธิ์การเข้าถึง (Authentication):
    echo สามารถสร้าง GitHub Personal Access Token (PAT) ได้ที่:
    echo https://github.com/settings/tokens
    echo แล้วใช้ Token เป็นรหัสผ่าน หรือพิมพ์ลงในช่องนี้
)

echo.
pause
