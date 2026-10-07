#requires -Version 7.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'quota-monitor.ps1') -Library -All -Mode Auto -RecoveryConfirmSeconds 1
$script:ActualWaitPoll=${function:Wait-Poll}
$script:AccountId='mock-account'
$script:RunDirectory=Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\work\quota-monitor-all-checks'))) ([guid]::NewGuid().ToString())
[void][IO.Directory]::CreateDirectory($script:RunDirectory)
$script:TestRoot=$script:RunDirectory
$script:TestIds=@('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000005')
$script:TestIteration=0;$script:Calls=[Collections.Generic.List[object]]::new()
$script:MockGoal=@{status='active';objective='mock goal';createdAt=1;updatedAt=1;tokenBudget=10000}
function Get-DesktopVersion{return 'unlisted-client-version'}
function Get-LiveQuota{return @{accountId=$AccountId;remaining=$(if($script:TestIteration -lt 2){5}else{100});resetsAt=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+18000);weeklyRemaining=50;allowed=$true;simulated=$true}}
function Get-EffectiveQuota($live){return $live}
function Get-DesktopCatalog{return @{total=5;ids=$script:TestIds}}
function Get-DesktopOwners($ids){$map=@{};foreach($id in $ids){$map[$id]='mock-owner'};return $map}
function New-TestSnapshot($id) {
    $record=$script:FleetJournal.threads[$id]
    $status=$(if($script:TestIteration -eq 1){'inProgress'}elseif($script:TestIteration -lt 5){'interrupted'}elseif($script:TestIteration -eq 5){'inProgress'}else{'completed'})
    if($id -eq $script:TestIds[4] -and $script:TestIteration -lt 5){$status='failed'}
    $turn=$(if($script:TestIteration -ge 5){'continued-'+$id}else{'original-'+$id})
    $snapshot=@{id=$id;hostId='local';originator='Codex Desktop';requests=@();turns=@(@{turnId=$turn;status=$status});latestTurnStartMessageId=$(if($script:TestIteration -ge 5){$record.resumeMessageId}else{'initial-'+$id});threadRuntimeStatus=@{type=$(if($status -eq 'inProgress'){'active'}else{'idle'})}}
    if($id -eq $script:TestIds[3]){$snapshot.threadGoal=$script:MockGoal.Clone();if($script:TestIteration -ge 6){$snapshot.threadGoal.status='complete'}}
    if($id -eq $script:TestIds[4] -and $status -eq 'failed'){$snapshot.turns[0].error=@{codexErrorInfo='usageLimitExceeded'}}
    return $snapshot
}
function Get-DesktopSnapshots($owners) {
    $script:TestIteration++
    $map=@{}
    foreach($id in @($script:TestIds[0],$script:TestIds[1],$script:TestIds[3],$script:TestIds[4])){$map[$id]=New-TestSnapshot $id}
    $map[$script:TestIds[2]]=@{id=$script:TestIds[2];requests=@();turns=@(@{turnId='finished-history';status='completed'});latestTurnStartMessageId='history';threadRuntimeStatus=@{type='idle'}}
    return $map
}
function Get-Snapshot{return New-TestSnapshot $ThreadId}
function Invoke-Ipc($method,$params,$version,$timeout,$target) {
    if($method -eq 'thread-follower-interrupt-turn' -and $ThreadId -eq $script:TestIds[3]){
        if($version -ne 3 -or $params.ContainsKey('expectedTurnId')){throw 'Goal pause must use the owner goal-aware interrupt path.'}
        $script:MockGoal.status='paused';$script:MockGoal.updatedAt=2
    }
    if($method -eq 'thread-follower-start-turn') {
        $saved=Read-Json (Join-Path $script:TestRoot 'state.json')
        if($saved.threads[$ThreadId].phase -ne 'resume_submitting' -or $saved.threads[$ThreadId].resumeMessageId -ne $params.turnStart.request.clientUserMessageId){throw 'Continuation was sent before its unique ID was saved.'}
    }
    $script:Calls.Add(@{method=$method;threadId=$ThreadId;params=$params;version=$version})
    return @{resultType='success';result=@{ok=$true;interruptedTurnId=$(if($ThreadId -eq $script:TestIds[3]){'original-'+$ThreadId}else{$params.expectedTurnId})}}
}
function Invoke-QuotaRpc($method,$params){
    if($method -eq 'thread/goal/set'){
        $saved=Read-Json (Join-Path $script:TestRoot 'state.json')
        if($saved.threads[$ThreadId].phase -ne 'resume_submitting' -or !$saved.threads[$ThreadId].resumeMessageId){throw 'Goal was reactivated before durable resume registration.'}
        $script:MockGoal.status=$params.status;$script:MockGoal.updatedAt=3
        $script:Calls.Add(@{method=$method;threadId=$ThreadId;params=$params})
    }
    return @{goal=$script:MockGoal.Clone()}
}
function Wait-Poll($seconds){if($script:TestIteration -ge 6){return $false};Start-Sleep -Milliseconds 1100;return $true}
Write-JsonAtomic (Join-Path $script:TestRoot 'state.json') @{scope='all';mode='Auto';phase='observing';accountId=$AccountId;threads=@{($script:TestIds[3])=@{phase='needs_attention';reason='active-Goal'};($script:TestIds[4])=@{phase='completed'}};lastControlId=$null}
Start-AllMonitor
$saved=Read-Json (Join-Path $script:TestRoot 'state.json')
$pauses=@($script:Calls|Where-Object method -eq 'thread-follower-interrupt-turn')
$resumes=@($script:Calls|Where-Object method -eq 'thread-follower-start-turn')
if($pauses.Count -ne 3){throw 'Expected independent pauses for two ordinary chats and one Goal.'}
if($resumes.Count -ne 4){throw 'Expected exactly one continuation for each paused chat including Goal and quota-interrupted legacy record.'}
if($resumes[0].params.turnStart.request.clientUserMessageId -eq $resumes[1].params.turnStart.request.clientUserMessageId){throw 'Continuation IDs must be unique per chat.'}
foreach($id in @($script:TestIds[0],$script:TestIds[1],$script:TestIds[3],$script:TestIds[4])){if($saved.threads[$id].phase -ne 'completed'){throw 'All tracked chats must reach completed state.'}}
if($saved.threads.ContainsKey($script:TestIds[2])){throw 'Completed history was incorrectly registered.'}
if($saved.counts.goalSkipped -ne 0 -or @($script:Calls|Where-Object method -eq 'thread/goal/set').Count -ne 1){throw 'Goal must be included and reactivated exactly once.'}
Write-Host 'PASS independent pauses for two ordinary chats and one Goal'
Write-Host 'PASS exactly one continuation per paused chat'
Write-Host 'PASS early quota refill resumes ordinary chats and Goal before saved reset time'
Write-Host 'PASS distinct continuation IDs saved before requests'
Write-Host 'PASS both chats complete independently'
Write-Host 'PASS completed history is not restarted'
Write-Host 'PASS Goal enrolled after legacy exclusion and reactivated exactly once'
Write-Host 'PASS quota-failed legacy completed record is reclassified and continued exactly once'
foreach($id in @($script:TestIds[0],$script:TestIds[1],$script:TestIds[3])) {
    $events=@(Get-Content -LiteralPath (Join-Path $script:TestRoot ('threads\'+$id+'\events.jsonl')) | ForEach-Object {$_ | ConvertFrom-Json -AsHashtable})
    foreach($eventName in @('paused','resumed')) {
        $event=$events | Where-Object event -eq $eventName | Select-Object -First 1
        if(!$event.time -or $null -eq $event.quota.remaining -or $null -eq $event.quota.weeklyRemaining -or !$event.quotaCheckedAt){throw 'Control log must preserve event time and both quota snapshots.'}
    }
}
Write-Host 'PASS pause and resume logs preserve timestamps and both quotas'
$script:Journal=$script:FleetJournal;$script:RunDirectory=$script:TestRoot
foreach($record in $script:Journal.threads.Values){$record.phase='paused'}
Write-JsonAtomic (Join-Path $script:TestRoot 'control.json') @{id=[guid]::NewGuid().ToString();action='Cancel'}
$keepRunning=& $script:ActualWaitPoll 1
$cancelled=Read-Json (Join-Path $script:TestRoot 'state.json')
if($keepRunning -or $cancelled.phase -ne 'cancelled' -or @($cancelled.threads.Values|Where-Object phase -ne 'cancelled').Count){throw 'Global cancellation failed to clear saved pause eligibility.'}
Write-Host 'PASS cancellation clears paused records during poll wait'
# Exercise actual fleet error handling, without client connections or task controls.
function Get-LiveQuota {
    $script:ReadStep++
    if($script:ReadPlan[$script:ReadStep-1] -eq 'fail'){throw 'temporary read timeout'}
    return @{accountId=$AccountId;remaining=50;weeklyRemaining=50;allowed=$true;simulated=$true}
}
function Get-DesktopCatalog {return @{total=0;ids=@();chats=@()}}
function Get-DesktopOwners {return @{}}
function Get-DesktopSnapshots {return @{}}
function Wait-Poll($seconds){
    if($seconds -ne 180){throw 'Read retries must use configured normal interval'}
    return $script:ReadStep -lt $script:ReadPlan.Count
}
function Check-ReadRetry($limit,$plan,$expectedSteps,$expectedFailures,$expectedPhase) {
    $script:RunDirectory=Join-Path $script:TestRoot ([guid]::NewGuid().ToString());[void][IO.Directory]::CreateDirectory($script:RunDirectory)
    $script:SettingsPath=Join-Path $script:RunDirectory 'settings.json'
    Write-JsonAtomic $script:SettingsPath @{pollSeconds=180;pauseRemainingPercent=5;maxConsecutiveFailures=$limit}
    $script:ReadPlan=$plan;$script:ReadStep=0
    Start-AllMonitor
    $result=Read-Json (Join-Path $script:RunDirectory 'state.json')
    if($script:ReadStep -ne $expectedSteps -or $result.readFailureCount -ne $expectedFailures -or $result.phase -ne $expectedPhase){throw "Incorrect fleet retry handling for failure limit $limit"}
}
Check-ReadRetry 0 @('fail','fail','fail','fail','fail','fail','ok') 7 0 'observing'
Write-Host 'PASS six consecutive failures do not stop by default and a successful read clears the counter'
Check-ReadRetry 3 @('fail','fail','fail','fail','fail') 3 3 'needs_attention'
Write-Host 'PASS configured threshold stops fleet monitoring after exactly three failed reads'
Check-ReadRetry 2 @('fail','ok','fail','fail','ok') 4 2 'needs_attention'
Write-Host 'PASS a successful query resets the consecutive failure threshold before later errors'
Write-Host 'All-chat coordination checks passed (mocked client and quota; no real chats controlled).'
