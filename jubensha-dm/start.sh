#!/bin/bash
# Mac / Linux 启动脚本：第一次运行会自动安装依赖
cd "$(dirname "$0")"
if [ ! -d .venv ]; then
  echo "第一次运行，正在安装依赖……"
  python3 -m venv .venv
  source .venv/bin/activate
  pip install -r requirements.txt
else
  source .venv/bin/activate
fi
python run.py "$@"
