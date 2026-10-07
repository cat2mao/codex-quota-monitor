#requires -Version 7.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'quota-monitor.ps1') -Library -All -Mode Auto
$script:RunDirectory=Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\work\quota-monitor-feature-check'))) ([guid]::NewGuid().ToString())
[void][IO.Directory]::CreateDirectory($script:RunDirectory)
$script:Journal=@{phase='observing';threadId='mock-thread'}
$script:AccountId='mock-account';$script:ThreadId='all';$script:Checks=0
function Assert($ok,$name){if(!$ok){throw "FAIL $name"};$script:Checks++;Write-Host "PASS $name"}
$script:PollSeconds=180;$script:NearLimitPollSeconds=10;$script:NearLimitRemainingPercent=10
Assert ((Get-PollDelay @{remaining=11} @()) -eq 180) 'normal quota uses normal interval'
Assert ((Get-PollDelay @{remaining=10} @()) -eq 10) '10 percent triggers faster checks'
Assert ((Get-PollDelay @{remaining=99} @(@{phase='paused'})) -eq 10) 'recovery wait uses faster checks'
$script:PollSeconds=3
Assert ((Get-PollDelay @{remaining=0} @()) -eq 3) 'near-limit interval never slows a faster normal interval'
Assert ((Get-QuotaStatus @{remaining=0;weeklyRemaining=84;allowed=$false}) -eq '五小时额度耗尽') 'zero five-hour quota is not mislabeled as bad account'
Assert ((Get-QuotaStatus @{remaining=90;weeklyRemaining=0;allowed=$false}) -eq '周额度耗尽') 'weekly exhaustion has its own message'
$script:ResumeAll=$true;$script:ResumeExcludedThreadIds=@('excluded')
Assert (!(Test-AutoResumeAllowed @{threadId='excluded'})) 'per-chat exception works with default enabled'
Assert (Test-AutoResumeAllowed @{threadId='included'}) 'other chats keep default enabled'
$script:ResumeAll=$false;$script:ResumeThreadIds=@('included')
Assert (Test-AutoResumeAllowed @{threadId='included'}) 'explicit selection works with default disabled'
Assert (!(Test-AutoResumeAllowed @{threadId='other'})) 'unselected chat stays disabled'
$script:ResumeAll=$true;$script:ResumeExcludedThreadIds=@()
$state=@{threadId='mock-thread';phase='observing'}
$snapshot=@{turns=@(@{turnId='failed-turn';status='failed';error=@{codexErrorInfo='usageLimitExceeded'}});latestTurnStartMessageId='original-message';threadRuntimeStatus=@{type='idle'};requests=@()}
$quota=@{remaining=0;weeklyRemaining=80;allowed=$false}
Assert ((Get-Decision $state $snapshot $quota 100) -eq 'QuotaInterrupted') 'quota failure is registered instead of completed'
$snapshot.threadGoal=@{status='usageLimited';objective='mock goal';createdAt=1;updatedAt=2;tokenBudget=1000}
Assert ((Get-Decision $state $snapshot $quota 100) -eq 'QuotaInterrupted') 'usage-limited Goal is resumable'
$script:Journal=$state.Clone();$script:ThreadId='mock-thread'
[void](Update-ThreadState $snapshot $quota 100)
Assert ($script:Journal.phase -eq 'paused' -and $script:Journal.pausedForGoal -and $script:Journal.pausedSource -eq 'quota') 'quota-limited Goal persists original identity and waiting phase'
$quota=@{remaining=90;weeklyRemaining=80;allowed=$true}
Assert ((Get-Decision $script:Journal $snapshot $quota 200) -eq 'RecoveryReady') 'quota-limited Goal recovers after usable quota returns'
$goal=$snapshot.threadGoal;$snapshot.Remove('threadGoal')
$script:Journal=$state.Clone()
[void](Update-ThreadState $snapshot $quota 100)
Assert ($script:Journal.phase -eq 'paused' -and !$script:Journal.pausedForGoal) 'ordinary quota failure also waits for recovery'
Assert ((Get-Decision $script:Journal $snapshot $quota 200) -eq 'RecoveryReady') 'ordinary failed-by-quota turn resumes'
$snapshot.latestTurnStartMessageId='user-new-message'
Assert ((Get-Decision $script:Journal $snapshot $quota 200) -eq 'UserChanged') 'manual takeover cancels old quota recovery'
$snapshot.latestTurnStartMessageId='original-message';$snapshot.turns[0].error.codexErrorInfo='serverOverloaded'
Assert ((Get-Decision $state $snapshot $quota 200) -eq 'Failed') 'other errors are neither completed nor automatically resumed'
$snapshot.turns[0].status='completed';$snapshot.turns[0].error=$null
Assert ((Get-Decision $state $snapshot $quota 200) -eq 'Completed') 'genuine completed turn remains ended'
# Verify the fresh-process boundary using a mock service, not real account requests.
$actualLive=${function:Get-LiveQuota};$script:Starts=0
function Start-QuotaServer {$script:Starts++}
function Invoke-QuotaRpc {return @{accountId='mock-account';ordinaryUsageAllowed=$true;rateLimits=@{primary=@{usedPercent=($script:Starts*10);windowDurationMins=300;resetsAt=10000};secondary=@{usedPercent=20;resetsAt=20000}};rateLimitResetCredits=@{availableCount=0;credits=@()}}}
$first=& $actualLive;$second=& $actualLive
Assert ($script:Starts -eq 2 -and $first.remaining -eq 90 -and $second.remaining -eq 80) 'each live quota request refreshes the service process'
function Get-LiveQuota {return $script:MockLive.Clone()}
$script:ResetCalls=[Collections.Generic.List[object]]::new();$script:ResetOutcome='reset';$script:RefillAfterReset=$true
function Invoke-QuotaRpc($method,$params){
    if($method -ne 'account/rateLimitResetCredit/consume'){throw 'Unexpected method'}
    $saved=Read-Json (Join-Path $script:RunDirectory 'state.json')
    if($saved.resetAttempt.idempotencyKey -ne $params.idempotencyKey -or $saved.resetAttempt.stage -ne 'pending'){throw 'Reset key must be durable before consumption'}
    $script:ResetCalls.Add($params.Clone())
    if($script:ResetOutcome -eq 'timeout'){throw 'Quota RPC timeout.'}
    if($script:RefillAfterReset -and $script:ResetOutcome -in @('reset','alreadyRedeemed')){$script:MockLive.remaining=98;$script:MockLive.weeklyRemaining=97;$script:MockLive.resetCredits=@{availableCount=0;credits=@()}}
    return @{outcome=$script:ResetOutcome}
}
function Reset-Fixture {
    $script:Journal=@{phase='observing';threadId='all'};$script:ThreadId='all';$script:ResetCalls.Clear();$script:ObserveOnly=$false;$script:AutoResetEnabled=$true;$script:ResetWeeklyRemainingPercent=1;$script:Mode='Auto';$script:ResetOutcome='reset';$script:RefillAfterReset=$true
    $script:MockLive=@{accountId='mock-account';remaining=2;weeklyRemaining=1;resetsAt=10000;weeklyResetsAt=20000;allowed=$true;resetCredits=@{availableCount=2;credits=@(@{id='later';resetType='codexRateLimits';status='available';expiresAt=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+10000)},@{id='earlier';resetType='codexRateLimits';status='available';expiresAt=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+5000)})}}
}
Reset-Fixture;$script:AutoResetEnabled=$false;[void](Get-QuotaWithAutoReset)
Assert ($script:ResetCalls.Count -eq 0) 'reset switch off consumes nothing'
Reset-Fixture;$script:ObserveOnly=$true;[void](Get-QuotaWithAutoReset)
Assert ($script:ResetCalls.Count -eq 0) 'readonly consumes nothing even with auto-reset enabled'
Reset-Fixture;$script:Mode='Test';[void](Get-QuotaWithAutoReset)
Assert ($script:ResetCalls.Count -eq 0) 'test mode never consumes a real card'
Reset-Fixture;$script:MockLive.weeklyRemaining=2;[void](Get-QuotaWithAutoReset)
Assert ($script:ResetCalls.Count -eq 0) 'above weekly threshold consumes nothing'
Reset-Fixture;$script:MockLive.resetCredits=@{availableCount=0;credits=@()};[void](Get-QuotaWithAutoReset)
Assert ($script:ResetCalls.Count -eq 0) 'no cards consumes nothing'
Reset-Fixture;$q=Get-QuotaWithAutoReset
Assert ($script:ResetCalls.Count -eq 1 -and $script:ResetCalls[0].creditId -eq 'earlier') 'one card is used with earliest expiry preferred'
Assert ($q.remaining -eq 98 -and $q.weeklyRemaining -eq 97) 'display uses refreshed service quota rather than guessed 100 percent'
Reset-Fixture;$script:RefillAfterReset=$false;[void](Get-QuotaWithAutoReset);[void](Get-QuotaWithAutoReset)
Assert ($script:ResetCalls.Count -eq 1) 'successful request cannot chain cards while quota has not recovered'
Reset-Fixture;$script:ResetOutcome='timeout';[void](Get-QuotaWithAutoReset)
$key=$script:ResetCalls[0].idempotencyKey
$script:Journal=Read-Json (Join-Path $script:RunDirectory 'state.json');$script:Journal.resetAttempt.lastTryAt=0;$script:ResetOutcome='alreadyRedeemed'
$q=Get-QuotaWithAutoReset
Assert ($script:ResetCalls.Count -eq 2 -and $script:ResetCalls[1].idempotencyKey -eq $key) 'restart and retry preserve same idempotency key'
Assert ($q.weeklyRemaining -eq 97 -and $script:Journal.resetAttempt.outcome -eq 'alreadyRedeemed') 'already-redeemed result is treated as success and refreshed'
Reset-Fixture;$script:ResetOutcome='nothingToReset';[void](Get-QuotaWithAutoReset);[void](Get-QuotaWithAutoReset)
Assert ($script:ResetCalls.Count -eq 1) 'not-eligible result does not hammer consumption every poll'
$script:MockLive.weeklyRemaining=0;[void](Get-QuotaWithAutoReset)
Assert ($script:ResetCalls.Count -eq 2) 'reaching exhaustion permits a new eligibility check'
Reset-Fixture;$script:ResetOutcome='noCredit';[void](Get-QuotaWithAutoReset);[void](Get-QuotaWithAutoReset)
Assert ($script:ResetCalls.Count -eq 1 -and $script:Journal.resetStatus -eq '没有可用卡') 'server no-credit result is shown and deduplicated'
Reset-Fixture;$script:MockLive.resetCredits.credits=$null;[void](Get-QuotaWithAutoReset)
Assert (!$script:ResetCalls[0].ContainsKey('creditId')) 'count-only credits let the service choose a card'
Reset-Fixture;$script:MockLive.resetCredits.credits=@(@{id='expired';status='available';resetType='codexRateLimits';expiresAt=1});[void](Get-QuotaWithAutoReset)
Assert ($script:ResetCalls.Count -eq 0) 'expired or incompatible details are not consumed'
$events=@(Get-Content (Join-Path $script:RunDirectory 'events.jsonl') | ForEach-Object {$_|ConvertFrom-Json -AsHashtable})
Assert (@($events|Where-Object {$_.event -eq 'reset-result' -and $_.quota.weeklyRemaining -eq 1 -and $_.time}).Count -gt 0) 'reset logs preserve timestamps and quota snapshots'
$script:RecoveryConfirmSeconds=1;$script:MockGoal=$goal.Clone();$script:ContinuationCalls=[Collections.Generic.List[object]]::new()
function Invoke-QuotaRpc($method,$params){
    if($method -eq 'thread/goal/set'){$script:MockGoal.status=$params.status;$script:MockGoal.updatedAt=3}
    return @{goal=$script:MockGoal.Clone()}
}
function Invoke-Ipc($method,$params){
    $saved=Read-Json (Join-Path $script:RunDirectory 'state.json')
    if($saved.phase -ne 'resume_submitting' -or $saved.resumeMessageId -ne $params.turnStart.request.clientUserMessageId){throw 'Continuation must be saved before send'}
    $script:ContinuationCalls.Add($params)
    return @{resultType='success'}
}
foreach($isGoal in @($false,$true)){
    $script:Journal=@{threadId='mock-thread';phase='observing'};$script:ThreadId='mock-thread';$script:MockGoal=$goal.Clone()
    $interrupted=@{turns=@(@{turnId='quota-failed';status='failed';error=@{codexErrorInfo='usageLimitExceeded'}});latestTurnStartMessageId='original-message';threadRuntimeStatus=@{type='idle'};requests=@()}
    if($isGoal){$interrupted.threadGoal=$script:MockGoal.Clone()}
    [void](Update-ThreadState $interrupted @{remaining=0;weeklyRemaining=80;allowed=$false} 100)
    [void](Update-ThreadState $interrupted $quota 200)
    $script:Journal.recoverySeenAt=[long]$script:Journal.recoverySeenAt-1100
    [void](Update-ThreadState $interrupted $quota 202)
    Assert ($script:Journal.phase -eq 'resume_submitting') "quota-interrupted continuation is submitted (Goal=$isGoal)"
    if($isGoal){Assert ($script:MockGoal.status -eq 'active') 'usageLimited Goal is reactivated with original budget'}
    $interrupted.latestTurnStartMessageId=$script:Journal.resumeMessageId;$interrupted.turns=@(@{turnId='continued';status='inProgress'});$interrupted.threadRuntimeStatus.type='active'
    if($isGoal){$interrupted.threadGoal=$script:MockGoal.Clone()}
    [void](Update-ThreadState $interrupted $quota 203)
    [void](Update-ThreadState $interrupted $quota 204)
    Assert ($script:Journal.phase -eq 'resumed') "quota-interrupted continuation is confirmed (Goal=$isGoal)"
}
Assert ($script:ContinuationCalls.Count -eq 2) 'ordinary and Goal quota failures continue exactly once each'
Write-Host "$script:Checks feature checks passed (mocked service; no real cards or chats changed)."
