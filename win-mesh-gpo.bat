@echo off
REM =============================================================================
REM Deploy-MeshCentralAgent.bat
REM MeshCentral Agent — GPO Computer Startup wrapper
REM =============================================================================
REM Purpose
REM   GPO hook only. Launches the PowerShell deploy script as SYSTEM.
REM
REM Deployment chain
REM   GPO Computer Startup
REM     → this .bat
REM     → powershell.exe -NoProfile -ExecutionPolicy Bypass -File <ps1>
REM     → Deploy-MeshCentralAgent.ps1
REM     → meshagent64-<Group>.exe -fullinstall
REM
REM   Do not pass -fullinstall here. The .ps1 bakes that in.
REM
REM Implementation
REM   1. Put this .bat, the .ps1, and the MeshAgent EXE on the same share
REM      Domain Computers can READ and EXECUTE, e.g.
REM        \\CONTOSO\NETLOGON\MeshCentral
REM   2. Change the UNC below to match your share and .ps1 name.
REM   3. GPO: Computer Configuration → Policies → Windows Settings
REM      → Scripts → Startup → Add this .bat. No parameters.
REM   4. Link the GPO to a computer OU. Filter on Domain Computers.
REM   5. Reboot to test. gpupdate /force does not run startup scripts.
REM =============================================================================

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "\\CONTOSO\NETLOGON\MeshCentral\Deploy-MeshCentralAgent.ps1"
