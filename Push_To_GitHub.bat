@echo off
title Push iOS Project to GitHub
cd /d "%~dp0"

echo ========================================================
echo   PUSH DU AN LEN REPO https://github.com/codebywin/locgo.git
echo ========================================================
echo.

git remote set-url origin https://github.com/codebywin/locgo.git
echo Dang day code len branch main...
git push -u origin main

if errorlevel 1 (
    echo.
    echo ========================================================
    echo [!] Neu bao loi 403 (Permission denied):
    echo     Nguyen nhan: May tinh dang luu tai khoan Git cu (appbywin).
    echo.
    echo     BAN CO 2 CACH XU LY NHANH:
    echo     Cach 1: Vao Settings repo https://github.com/codebywin/locgo/settings/access
    echo            Them tai khoan "appbywin" lam Collaborator (Write access).
    echo.
    echo     Cach 2: Nhap Personal Access Token (PAT) cua "codebywin" vao duoi:
    echo ========================================================
    set /p "TOKEN=Nhap GitHub Token (hoac an Enter de thoat): "
    if not "!TOKEN!"=="" (
        git remote set-url origin https://!TOKEN!@github.com/codebywin/locgo.git
        git push -u origin main
    )
) else (
    echo.
    echo [OK] DA PUSH THANH CONG LEN GITHUB!
    echo Vao muc Actions de xem tien trinh build:
    echo https://github.com/codebywin/locgo/actions
)

echo.
pause
