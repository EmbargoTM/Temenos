# ============================================================
# Temenos - NewDesktop.ps1
# Entry point usado pelo atalho "+ Nova Área".
# ============================================================

$ErrorActionPreference = "SilentlyContinue"

$CodeRoot = $PSScriptRoot
. (Join-Path $CodeRoot "DesktopActions.ps1")

New-TemenosVirtualDesktop
