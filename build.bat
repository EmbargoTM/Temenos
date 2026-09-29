@echo off
rem Build Temenos.exe next to Temenos.json (needs the Odin compiler and the MSVC linker).
odin build "%~dp0src" -out:"%~dp0Temenos.exe" -subsystem:windows -o:speed -vet %*
