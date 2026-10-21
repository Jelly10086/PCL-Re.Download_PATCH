@echo off
chcp 65001 >nul
setlocal DisableDelayedExpansion
title 启动器下载恢复补丁 - 恢复原版
if "%~1"=="" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0LauncherPatch.ps1" -Restore
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0LauncherPatch.ps1" -TargetPath "%~1" -Restore
)
set "patchExit=%errorlevel%"
echo.
echo 按任意键关闭窗口...
pause >nul
exit /b %patchExit%
