@echo off
setlocal
chcp 65001 >nul
echo ========================================================
echo   GitHub Login ด้วย Personal Access Token (PAT)
echo ========================================================
echo.
echo เข้าไปสร้าง Token ได้ที่: https://github.com/settings/tokens/new
echo (อย่าลืมติ๊กถูกที่ช่อง 'repo' และ 'workflow')
echo.

set GIT_EXE="%~dp0..\tools\git\cmd\git.exe"

set /p TOKEN="วาง Personal Access Token (ghp_...): "

if "%TOKEN%"=="" (
    echo [ERROR] ไม่ได้ใส่ Token ยกเลิกการทำงาน
    pause
    exit /b 1
)

cd /d "%~dp0"

echo.
echo กำลังตั้งค่าการเชื่อมต่อด้วย Token...
%GIT_EXE% remote set-url origin https://%TOKEN%@github.com/james0058/Zoontes_Navigate.git

echo กำลัง Push โค้ดขึ้น GitHub...
%GIT_EXE% push -u origin main

if %ERRORLEVEL% EQU 0 (
    echo.
    echo ========================================================
    echo   [สำเร็จ!] Login และ Push โค้ดเรียบร้อยแล้ว
    echo   เข้าไปดูการบิลด์ไฟล์ .ipa ได้ที่:
    echo   https://github.com/james0058/Zoontes_Navigate/actions
    echo ========================================================
) else (
    echo.
    echo [ERROR] Token ไม่ถูกต้อง หรือไม่มีสิทธิ์ Push ใน Repository นี้
)

echo.
pause
