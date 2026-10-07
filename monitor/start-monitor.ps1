# This launcher runs in Windows PowerShell 5.1 or PowerShell 7.
[CmdletBinding()]
param(
    [string]$ThreadId,
    [string]$AccountId,
    [ValidateSet('Run','Status','Cancel','Stop','Probe')][string]$Action='Run',
    [ValidateSet('Monitor','Test','Auto')][string]$Mode='Auto',
    [string]$StateDirectory,
    [string]$TestQuotaFile,
    [int]$PollSeconds=30,
    [ValidateRange(0,9999)][int]$MaxConsecutiveFailures=0,
    [ValidateRange(0,99)][double]$PauseRemainingPercent=5,
    [string]$SettingsPath,
    [switch]$Once,
    [switch]$All,
    [switch]$Raw
)
$ErrorActionPreference='Stop'
if(!$ThreadId){$PSBoundParameters['All']=[Management.Automation.SwitchParameter]::new($true)}
$PSBoundParameters['Mode']=$Mode
$runtime=Get-Command pwsh.exe -ErrorAction SilentlyContinue
$runtimePath=if($runtime){$runtime.Source}else{
    Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe'
}
if(!(Test-Path -LiteralPath $runtimePath)){
    Write-Host '无法启动：没有找到 PowerShell 7。请安装 PowerShell 7，或恢复 Codex 自带的运行环境。'
    exit 1
}
$launchArguments=@('-NoProfile','-File',(Join-Path $PSScriptRoot 'quota-monitor.ps1'))
foreach($entry in $PSBoundParameters.GetEnumerator()){
    if($entry.Value -is [Management.Automation.SwitchParameter]){
        if($entry.Value.IsPresent){$launchArguments+='-'+$entry.Key}
    }else{
        $launchArguments+='-'+$entry.Key
        $launchArguments+=[string]$entry.Value
    }
}
if($Action -eq 'Run'){Write-Host '正在启动额度监控器，首次读取和连接客户端可能需要几秒……'}
& $runtimePath @launchArguments
exit $LASTEXITCODE
