@echo off
cd D:\alcaldia\frontend
call npm install 2>nul
call .\node_modules\.bin\vite dev --port 3000