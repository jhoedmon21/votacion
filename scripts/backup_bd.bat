@echo off
rem ============================================================
rem  Backup de la base de datos computo_arequipa (PostgreSQL 16)
rem  Genera un SQL completo (esquema + datos) con fecha:
rem     backups\computo_arequipa_YYYYMMDD_HHMM.sql
rem  Conserva los 10 backups más recientes.
rem ============================================================
setlocal
cd /d "%~dp0.."

set "PGPASSWORD=Areq2026!pg"
set "PGBIN=C:\Program Files\PostgreSQL\16\bin"
set "DESTINO=backups"

if not exist "%DESTINO%" mkdir "%DESTINO%"

for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /value') do set "F=%%I"
set "STAMP=%F:~0,8%_%F:~8,4%"
set "ARCHIVO=%DESTINO%\computo_arequipa_%STAMP%.sql"

echo Generando backup: %ARCHIVO% ...
"%PGBIN%\pg_dump.exe" -U postgres -d computo_arequipa ^
  --format=plain --encoding=UTF8 --no-owner --no-privileges ^
  --file="%ARCHIVO%"

if errorlevel 1 (
  echo ERROR: el backup no se completo. Revisa credenciales y servicio PostgreSQL.
  pause
  exit /b 1
)

for %%A in ("%ARCHIVO%") do echo OK: %%A ^(~%%~zA bytes^)

rem --- Conservar solo los 10 más recientes
powershell -NoProfile -Command "$fs = Get-ChildItem '%DESTINO%\computo_arequipa_*.sql' | Sort-Object LastWriteTime -Descending; $fs | Select-Object -Skip 10 | Remove-Item -ErrorAction SilentlyContinue"

echo.
echo Backups conservados:
dir /b /o-d "%DESTINO%\computo_arequipa_*.sql" 2>nul | more
pause
