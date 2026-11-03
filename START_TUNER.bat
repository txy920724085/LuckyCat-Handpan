@echo off
cd /d "%~dp0project\tuner"
python app.py
if errorlevel 1 pause
