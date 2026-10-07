#requires -Version 7.0
$ErrorActionPreference='Stop'
foreach($name in @('check.ps1','check-features.ps1','check-all.ps1','check-concurrency.ps1')){
    # Run each check in a fresh process so mocked functions and compiled test helpers stay isolated.
    & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $PSScriptRoot ('monitor\'+$name))
    if($LASTEXITCODE -ne 0){throw "Check failed: $name"}
}
Write-Host 'All checks passed. No real chats or reset cards were controlled.'

