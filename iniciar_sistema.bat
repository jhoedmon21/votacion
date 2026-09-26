@echo off
title Sistema de Computo Electoral - Arequipa 2026
cd /d "%~dp0"

rem ============================================================
rem  Levanta backend (API 8000) + frontend (Web 3000) en modo red
rem  y abre el navegador. Comparte con otras PCs de tu red:
rem      http://192.168.1.11:3000
rem  (si tu router cambia la IP de esta PC, edita IP_LOCAL abajo)
rem ============================================================

set "IP_LOCAL=192.168.1.11"
set "URL=http://%IP_LOCAL%:3000"

rem --- Límite de memoria del frontend (heap de Node/Vite): 1 GB es de sobra
rem --- para el dev server incluso con 100 navegadores conectados.
set "NODE_OPTIONS=--max-old-space-size=1024"

echo.
echo  ==========================================================
echo    SISTEMA DE COMPUTO ELECTORAL  -  AREQUIPA 2026
echo    Acceso desde otras PCs:  %URL%
echo  ==========================================================
echo.

rem --- Si el sistema ya esta corriendo, solo abre el navegador
curl -s -o nul --max-time 3 http://localhost:3000/ >nul 2>&1
if not errorlevel 1 goto ya_corriendo

echo  [1/2] Iniciando backend (API, puerto 8000)...
rem  Un solo worker uvicorn: cada worker duplica la memoria base (~120 MB);
rem  con 100 usuarios concurrentes conviene 1 worker + threads de asyncio.
start "FA Backend - API 8000 (NO CERRAR)" /min cmd /c "cd /d %~dp0backend && venv\Scripts\python.exe -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 1"

echo  [2/2] Iniciando frontend (Web, puerto 3000)...
start "FA Frontend - Web 3000 (NO CERRAR)" /min cmd /c "cd /d %~dp0frontend && npm run dev"

echo  Esperando a que el sistema levante...
set /a INTENTOS=0
:esperar
ping -n 3 127.0.0.1 >nul
curl -s -o nul --max-time 2 http://localhost:3000/ >nul 2>&1
if not errorlevel 1 goto listo
set /a INTENTOS+=1
if %INTENTOS% GEQ 30 goto error_arranque
goto esperar

:listo
echo  Sistema corriendo. Abriendo tu navegador...
start "" %URL%
echo.
echo  ==========================================================
echo    LISTO. Comparte esta direccion con otras PCs de tu red:
echo.
echo        %URL%
echo.
echo    Login demo:   admin@computoarequipa.gob.pe
echo    Contrasena:   Admin.Arequipa2026
echo.
echo    Deja abiertas las dos ventanas minimizadas
echo    (API 8000 y Web 3000). Cerralas para DETENER el sistema.
echo  ==========================================================
echo.
pause
exit /b 0

:ya_corriendo
echo  El sistema ya esta corriendo. Abriendo navegador...
start "" %URL%
exit /b 0

:error_arranque
echo.
echo  ERROR: el frontend no levanto despues de ~90 segundos.
echo  Revisa las dos ventanas minimizadas para ver el detalle.
echo.
pause
exit /b 1
