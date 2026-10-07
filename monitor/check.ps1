#requires -Version 7.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'quota-monitor.ps1') -Library
$checks=0
function Assert-Decision($Name,$Expected,$State,$Snapshot,$Quota,$Now=100) {
    $actual=Get-Decision $State $Snapshot $Quota $Now
    if($actual -ne $Expected){throw "$Name expected $Expected, received $actual"}
    $script:checks++
    Write-Host "PASS $Name"
}
$active=@{id='test';hostId='local';turns=@(@{turnId='turn-1';status='inProgress'});requests=@();latestTurnStartMessageId='message-1';threadRuntimeStatus=@{type='active'}}
$idle=@{id='test';hostId='local';turns=@(@{turnId='turn-1';status='interrupted'});requests=@();latestTurnStartMessageId='message-1';threadRuntimeStatus=@{type='idle'}}
$quota=@{remaining=6;resetsAt=100;weeklyRemaining=50;allowed=$true}
$state=@{phase='observing'}
Assert-Decision '6 percent continues' Wait $state $active $quota
$quota.remaining=5
Assert-Decision '5 percent pauses' Pause $state $active $quota
$quota.remaining=100;$quota.weeklyRemaining=0
Assert-Decision 'weekly exhaustion pauses active work' Pause $state $active $quota
$quota.weeklyRemaining=50
$paused=@{phase='paused';pausedTurnId='turn-1';baselineMessageId='message-1';pauseResetsAt=100;resumeMessageId=$null}
Assert-Decision 'early quota refill permits ordinary recovery checks' RecoveryReady $paused $idle $quota 99
Assert-Decision 'usable reset permits recovery checks' RecoveryReady $paused $idle $quota 100
$quota.remaining=5
Assert-Decision 'remaining 5 cannot resume' Wait $paused $idle $quota
$quota.remaining=100;$quota.allowed=$false
Assert-Decision 'account block prevents resume' Wait $paused $idle $quota
$quota.allowed=$true;$quota.weeklyRemaining=0
Assert-Decision 'weekly block prevents resume' Wait $paused $idle $quota
$quota.weeklyRemaining=50
$newUser=$idle.Clone();$newUser.latestTurnStartMessageId='manual-message'
Assert-Decision 'manual message releases ownership' UserChanged $paused $newUser $quota
$newActive=$active.Clone();$newActive.turns=@(@{turnId='manual-turn';status='inProgress'})
Assert-Decision 'another client active turn prevents duplicate resume' UserChanged $paused $newActive $quota
$pending=$paused.Clone();$pending.phase='pause_pending'
Assert-Decision 'interruption must be confirmed' PauseConfirmed $pending $idle $quota
Assert-Decision 'still-active task not marked paused' Wait $pending $active $quota
$complete=$idle.Clone();$complete.turns=@(@{turnId='turn-1';status='completed'})
Assert-Decision 'completion racing pause is preserved' FinishedDuringPause $pending $complete $quota
$resuming=$paused.Clone();$resuming.phase='resume_submitting';$resuming.resumeMessageId='resume-message'
$confirmed=$newActive.Clone();$confirmed.latestTurnStartMessageId='resume-message'
Assert-Decision 'matching continuation confirms once' ResumeConfirmed $resuming $confirmed $quota
Assert-Decision 'unknown continuation result never resends' Wait $resuming $idle $quota
$goal=$active.Clone();$goal.threadGoal=@{status='active'}
Assert-Decision 'active Goal stays registered above threshold' Wait $state $goal $quota
$quota.remaining=5
Assert-Decision 'active Goal pauses at threshold' Pause $state $goal $quota
$goalGap=$complete.Clone();$goalGap.threadGoal=@{status='active'}
Assert-Decision 'Goal is paused between automatic turns' Pause $state $goalGap $quota
$quota.remaining=100
Assert-Decision 'active Goal is not completed between turns' Wait $state $goalGap $quota
$goalPaused=$idle.Clone();$goalPaused.threadGoal=@{status='paused';objective='test goal';createdAt=1;updatedAt=2;tokenBudget=1000}
$goalState=$paused.Clone();$goalState.pausedForGoal=$true;$goalState.pausedGoal=@{objective='test goal';createdAt=1;tokenBudget=1000};$goalState.pausedGoalUpdatedAt=2
Assert-Decision 'early quota refill permits Goal recovery checks' RecoveryReady $goalState $goalPaused $quota 99
Assert-Decision 'paused Goal can resume after reset' RecoveryReady $goalState $goalPaused $quota
$quota.remaining=5
Assert-Decision 'paused Goal cannot resume at 5 percent before reset' Wait $goalState $goalPaused $quota 99
$quota.remaining=100;$quota.allowed=$false
Assert-Decision 'paused Goal cannot resume when account blocked before reset' Wait $goalState $goalPaused $quota 99
$quota.allowed=$true;$quota.weeklyRemaining=0
Assert-Decision 'paused Goal cannot resume when weekly exhausted before reset' Wait $goalState $goalPaused $quota 99
$quota.weeklyRemaining=50
$goalChanged=$goalPaused.Clone();$goalChanged.threadGoal=$goalPaused.threadGoal.Clone();$goalChanged.threadGoal.objective='replacement'
Assert-Decision 'edited Goal is not automatically resumed' UserChanged $goalState $goalChanged $quota
$goalChanged.threadGoal=$goalPaused.threadGoal.Clone();$goalChanged.threadGoal.status='active'
Assert-Decision 'manual Goal resume releases ownership' UserChanged $goalState $goalChanged $quota
$goalChanged.threadGoal=$goalPaused.threadGoal.Clone();$goalChanged.threadGoal.status='budgetLimited'
Assert-Decision 'Goal budget limit is not overridden' UserChanged $goalState $goalChanged $quota
$goalPending=$goalState.Clone();$goalPending.phase='pause_pending'
Assert-Decision 'Goal pause requires paused status and idle task' PauseConfirmed $goalPending $goalPaused $quota
$goalStillActive=$goalPaused.Clone();$goalStillActive.threadGoal=$goalPaused.threadGoal.Clone();$goalStillActive.threadGoal.status='active'
Assert-Decision 'active Goal is not falsely confirmed paused' Wait $goalPending $goalStillActive $quota
$waiting=$idle.Clone();$waiting.requests=@(@{method='item/tool/requestUserInput'})
Assert-Decision 'pending user input waits' Wait $paused $waiting $quota
$canonical=$active.Clone();$canonical.turns=@();$canonical.turnHistory=@{kind='canonical';history=@{islands=@(@{entries=@(@{value='turn-key'})});entitiesByKey=@{'turn-key'=@{turnId='canonical-turn';status='inProgress'}}}}
if((Get-ActiveTurn $canonical).turnId -ne 'canonical-turn'){throw 'Canonical history active turn was not found'}
$checks++
Write-Host "PASS canonical history"
$script:PauseRemainingPercent=14
$quota.remaining=14
Assert-Decision 'custom threshold pauses ordinary task' Pause $state $active $quota
Assert-Decision 'custom threshold pauses Goal' Pause $state $goal $quota
$quota.remaining=15
Assert-Decision 'above custom threshold continues ordinary task' Wait $state $active $quota
$paused.threadId='ordinary';$goalState.threadId='goal'
$script:ResumeAll=$false;$script:ResumeThreadIds=@('goal')
Assert-Decision 'unselected ordinary task stays paused' Wait $paused $idle $quota
Assert-Decision 'selected Goal enters recovery checks' RecoveryReady $goalState $goalPaused $quota
$script:ResumeThreadIds=@('ordinary')
Assert-Decision 'selected ordinary task enters recovery checks' RecoveryReady $paused $idle $quota
Assert-Decision 'unselected Goal stays paused' Wait $goalState $goalPaused $quota
$quota.remaining=14
Assert-Decision 'unselected chat still pauses at threshold' Pause $state $goal $quota
$script:PauseRemainingPercent=5;$script:ResumeAll=$true;$script:ResumeThreadIds=@()
$script:RunDirectory=Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\work\quota-monitor-settings-check'))) ([guid]::NewGuid().ToString())
[void][IO.Directory]::CreateDirectory($script:RunDirectory)
$script:SettingsPath=Join-Path $script:RunDirectory 'settings.json'
Write-JsonAtomic $SettingsPath @{pollSeconds=17;pauseRemainingPercent=8;observeOnly=$true;resumeAll=$false;resumeThreadIds=@('goal')}
Read-MonitorSettings
if($PollSeconds -ne 17 -or $NearLimitPollSeconds -ne 17 -or $PauseRemainingPercent -ne 8 -or !$script:ObserveOnly -or $script:ResumeAll -or $script:ResumeThreadIds[0] -ne 'goal'){throw 'GUI settings were not applied'}
$checks++;Write-Host 'PASS live settings include interval threshold observe-only and selected chats'
$script:Journal=@{phase='observing'};$quota.remaining=1
function Invoke-Ipc {throw 'Read-only setting must not submit any control request'}
[void](Update-ThreadState $active $quota 100)
if($script:Journal.phase -ne 'observing'){throw 'Read-only setting modified control phase'}
$checks++;Write-Host 'PASS read-only setting does not pause an actual turn'
Write-JsonAtomic $SettingsPath @{pollSeconds=18;pauseRemainingPercent=8;observeOnly=$true;resumeAll=$false;resumeThreadIds=@('goal')}
Read-MonitorSettings
$logged=@(Get-Content -LiteralPath (Join-Path $script:RunDirectory 'events.jsonl') | ForEach-Object {$_ | ConvertFrom-Json -AsHashtable}) | Where-Object event -eq 'settings-updated' | Select-Object -Last 1
if(!$logged.time -or $logged.settings.pollSeconds -ne 18){throw 'Settings changes must be logged after being applied'}
$checks++;Write-Host 'PASS settings changes are logged with the applied policy'
Write-Host "$checks checks passed."
