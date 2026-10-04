$ErrorActionPreference = 'Stop'
$appRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$environment = Join-Path $appRoot 'data/LocalTTS/windows/.venv'
$python = Join-Path $environment 'Scripts/python.exe'
if (!(Test-Path -LiteralPath $python)) {
    python -m venv $environment
    if ($LASTEXITCODE -ne 0) { throw 'Install Python 3.12 and retry.' }
}
& $python -m pip install torch==2.8.0 torchaudio==2.8.0 --index-url https://download.pytorch.org/whl/cu128
if ($LASTEXITCODE -ne 0) { throw 'CUDA PyTorch installation failed.' }
$lockFile = Join-Path $PSScriptRoot 'requirements.lock.txt'
if (Test-Path -LiteralPath $lockFile) {
    & $python -m pip install -r $lockFile
} else {
    & $python -m pip install qwen-tts==0.1.1
}
if ($LASTEXITCODE -ne 0) { throw 'Qwen installation failed.' }
& $python -m pip check
if ($LASTEXITCODE -ne 0) { throw 'Dependency check failed.' }
& $python -c "import torch; assert torch.cuda.is_available(), 'CUDA unavailable'; print(torch.cuda.get_device_name(0))"
if ($LASTEXITCODE -ne 0) { throw 'GPU check failed.' }
