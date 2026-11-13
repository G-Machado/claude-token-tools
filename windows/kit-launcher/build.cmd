@echo off
rem Build start-claude.exe with the C# compiler that ships with .NET Framework 4 (every Windows 10/11).
setlocal
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
if not exist "%CSC%" (echo csc.exe not found & exit /b 1)
"%CSC%" /nologo /target:winexe /optimize+ /out:"%~dp0start-claude.exe" /r:System.Windows.Forms.dll "%~dp0Launcher.cs"
