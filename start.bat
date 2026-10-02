@echo off
chcp 65001 >nul
cd /d %~dp0
if not exist .venv (
  echo 第一次运行，正在安装依赖……
  python -m venv .venv
  call .venv\Scripts\activate.bat
  pip install -r requirements.txt
) else (
  call .venv\Scripts\activate.bat
)
python run.py %*
pause
