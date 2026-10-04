@echo off
chcp 65001 >nul
cd /d %~dp0
if not exist .venv\Scripts\python.exe (
  echo 第一次运行，正在安装依赖……
  python -m venv .venv
  if errorlevel 1 goto failed
)
".venv\Scripts\python.exe" -c "import starlette, uvicorn, requests, yaml, PIL, pypdfium2, segno" >nul 2>&1
if errorlevel 1 (
  ".venv\Scripts\python.exe" -m pip install -r requirements.txt
  if errorlevel 1 goto failed
)
".venv\Scripts\python.exe" -X utf8 run.py %*
if errorlevel 1 goto failed
pause
exit /b 0
:failed
echo 启动失败。请查看上方错误信息；未继续启动游戏。
pause
exit /b 1
