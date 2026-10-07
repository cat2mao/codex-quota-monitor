#requires -Version 7.0
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'tools\generate-icon.ps1')
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(!(Test-Path -LiteralPath $compiler)){throw 'Windows .NET Framework C# compiler was not found.'}
$destination=Join-Path $PSScriptRoot 'dist'
[void][IO.Directory]::CreateDirectory($destination)
$backend=Join-Path $PSScriptRoot 'monitor\quota-monitor.ps1'
$output=Join-Path $destination 'CodexQuotaMonitor.exe'
& $compiler /nologo /target:winexe /platform:x64 /optimize+ /codepage:65001 "/out:$output" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll /reference:System.Core.dll "/win32icon:$PSScriptRoot\assets\quota-monitor.ico" "/win32manifest:$PSScriptRoot\src\app.manifest" "/resource:$backend,quota-monitor.ps1" "$PSScriptRoot\src\QuotaMonitor.cs" "$PSScriptRoot\src\LogWindow.cs" "$PSScriptRoot\src\AssemblyInfo.cs"
if($LASTEXITCODE -ne 0){throw 'EXE compilation failed.'}
Write-Host "已生成：$output"

