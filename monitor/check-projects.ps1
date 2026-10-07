#requires -Version 7.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'quota-monitor.ps1') -Library -All -Mode Auto -RecoveryConfirmSeconds 1
$script:Checks=0;$script:ThreadId='00000000-0000-0000-0000-000000000001';$script:AccountId='mock-account'
$script:RunDirectory=Join-Path (Join-Path $PSScriptRoot '..\work\project-checks') ([guid]::NewGuid().ToString())
[void][IO.Directory]::CreateDirectory($script:RunDirectory)
$script:Calls=[Collections.Generic.List[object]]::new()
function Assert($ok,$name){if(!$ok){throw "FAIL $name"};$script:Checks++;Write-Host "PASS $name"}
function Invoke-Ipc($method,$params) {
    if($method -eq 'thread-follower-start-turn'){
        $saved=Read-Json (Join-Path $script:RunDirectory 'state.json')
        if($saved.phase -ne 'resume_submitting' -or $saved.resumeMessageId -ne $params.turnStart.request.clientUserMessageId){throw 'Manual start must be durable before submission'}
    }
    $script:Calls.Add(@{method=$method;params=$params})
    return @{resultType='success';result=@{interruptedTurnId='original';ok=$true}}
}
function Command($action){$script:Journal.pendingCommand=@{id=[guid]::NewGuid().ToString();threadId=$ThreadId;action=$action}}
$q=@{remaining=90;weeklyRemaining=80;allowed=$true}
$s=@{id=$ThreadId;turns=@(@{turnId='original';status='inProgress'});latestTurnStartMessageId='baseline';threadRuntimeStatus=@{type='active'};requests=@()}
$script:Journal=New-ThreadJournal $ThreadId 'any-version'
Command 'Pause';Apply-ThreadCommand $s;[void](Update-ThreadState $s $q 100)
Assert ($script:Journal.phase -eq 'pause_pending' -and $script:Calls.Count -eq 1 -and $script:Journal.manualHold) 'manual pause interrupts active work above quota threshold'
$s.turns[0].status='interrupted';$s.threadRuntimeStatus.type='idle';[void](Update-ThreadState $s $q 101)
Assert ($script:Journal.phase -eq 'paused') 'manual pause requires actual interruption confirmation'
Assert ((Get-Decision $script:Journal $s $q 102) -eq 'Wait' -and (Get-AutoResumePendingCount @($script:Journal)) -eq 0) 'manual hold is excluded from automatic recovery count'
Command 'AutoContinue';Apply-ThreadCommand $s
Assert ($script:Journal.phase -eq 'queued' -and (Get-AutoResumePendingCount @($script:Journal)) -eq 1) 'explicit registration arms a manually paused project once'
[void](Update-ThreadState $s $q 103);$script:Journal.recoverySeenAt=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-2000
[void](Update-ThreadState $s $q 104)
Assert ($script:Journal.phase -eq 'resume_submitting' -and @($script:Calls|Where-Object method -eq 'thread-follower-start-turn').Count -eq 1) 'registered project submits exactly one durable continuation'
Command 'Start';Apply-ThreadCommand $s
Assert ($script:Journal.phase -eq 'resume_submitting' -and @($script:Calls|Where-Object method -eq 'thread-follower-start-turn').Count -eq 1) 'right click cannot duplicate an unconfirmed start'
$s.latestTurnStartMessageId=$script:Journal.resumeMessageId;$s.turns=@(@{turnId='continued';status='inProgress'});$s.threadRuntimeStatus.type='active'
[void](Update-ThreadState $s $q 105);[void](Update-ThreadState $s $q 106)
Assert ($script:Journal.phase -eq 'resumed' -and $script:Calls.Count -eq 2) 'confirmed continuation does not restart repeatedly'
$s.turns[0].status='completed';$s.threadRuntimeStatus.type='idle';[void](Update-ThreadState $s $q 107)
Command 'AutoContinue';Apply-ThreadCommand $s
Assert ($script:Journal.phase -eq 'queued' -and (Get-Decision $script:Journal $s $q 108) -eq 'RecoveryReady') 'completed project can be explicitly registered for continuation'
$s.turns=@();$script:Journal=New-ThreadJournal $ThreadId 'any-version';Command 'Start';Apply-ThreadCommand $s
Assert ($script:Journal.phase -eq 'queued' -and $script:Journal.manualStart -and (Get-Decision $script:Journal $s $q 109) -eq 'RecoveryReady') 'idle project with no prior turn can be manually started'
$low=@{remaining=4;weeklyRemaining=80;allowed=$true}
Assert ((Get-Decision $script:Journal $s $low 110) -eq 'Wait') 'manual start waits for usable quota when account is low'
$s.requests=@(@{type='approval'})
Assert ((Get-Decision $script:Journal $s $q 111) -eq 'Wait') 'manual registration waits for existing approval or input'
$s.requests=@();Command 'CancelAuto';Apply-ThreadCommand $s
Assert ($script:Journal.phase -eq 'held' -and (Get-AutoResumePendingCount @($script:Journal)) -eq 0) 'cancel registration clears queued one-shot intent'
$script:ObserveOnly=$true;$before=$script:Calls.Count;Command 'Start';Apply-ThreadCommand $s
Assert ($script:Calls.Count -eq $before -and $script:Journal.phase -eq 'held') 'read-only mode rejects manual controls'
$script:ObserveOnly=$false
$script:Journal=New-ThreadJournal $ThreadId 'any-version';$s.threadGoal=@{status='paused';objective='mock goal';createdAt=1;updatedAt=2;tokenBudget=1000}
Command 'AutoContinue';Apply-ThreadCommand $s
Assert ($script:Journal.pausedForGoal -and (Get-Decision $script:Journal $s $q 112) -eq 'RecoveryReady') 'right-click continuation uses original paused Goal identity'
$s.threadGoal.objective='changed goal'
Assert ((Get-Decision $script:Journal $s $q 113) -eq 'UserChanged') 'edited Goal is not overridden by a queued continuation'
$s.threadGoal.status='complete';$script:Journal=New-ThreadJournal $ThreadId 'any-version';Command 'AutoContinue';Apply-ThreadCommand $s
Assert (!$script:Journal.pausedForGoal -and (Get-Decision $script:Journal $s $q 114) -eq 'RecoveryReady') 'completed Goal permits an explicitly requested project follow-up'
$s.Remove('threadGoal');$script:ResumeAll=$false;$script:ResumeThreadIds=@('chosen')
Assert ((Get-AutoResumePendingCount @(@{threadId='chosen';phase='paused'},@{threadId='other';phase='paused'},@{threadId='chosen';phase='held';manualHold=$true})) -eq 1) 'waiting count includes only selected resumable projects'
Assert ((Get-AutoResumePendingCount @(@{threadId='chosen';phase='held';manualHold=$true;pendingCommand=@{action='AutoContinue'}})) -eq 1) 'new continuation intent overrides an old manual hold in pending count'
Assert ((Get-AutoResumePendingCount @(@{threadId='chosen';phase='paused';pendingCommand=@{action='Pause'}})) -eq 0) 'pending manual pause is excluded from continuation count'
$script:PollSeconds=180;$script:NearLimitPollSeconds=10
Assert ((Get-PollDelay $low @(@{phase='paused'},@{phase='observing'}) 0) -eq 180) 'idle observing records no longer keep polling fast after confirmed pause'
Assert ((Get-PollDelay $low @() 0) -eq 180) 'no running project uses normal interval even if quota remains low'
Assert ((Get-PollDelay $low @(@{phase='paused'},@{phase='resumed'}) 1) -eq 10) 'actual remaining active work retains quota protection'
$fleet=@{scope='all';threads=@{}};$script:Journal=$fleet
$directory=Join-Path $script:RunDirectory 'commands';[void][IO.Directory]::CreateDirectory($directory)
$command=@{id='durable-command';threadId=$ThreadId;action='AutoContinue'}
Write-JsonAtomic (Join-Path $directory '001.json') $command;Read-ThreadCommands $fleet 'any-version'
$saved=Read-Json (Join-Path $script:RunDirectory 'state.json')
Assert ($saved.threads[$ThreadId].pendingCommand.id -eq 'durable-command' -and !(Test-Path (Join-Path $directory '001.json'))) 'unloaded project command is saved before its queue file is removed'
$script:Journal.lastControlId=$null
Write-JsonAtomic (Join-Path $directory '002.json') $command
Write-JsonAtomic (Join-Path $script:RunDirectory 'control.json') @{id='stop-before-project-command';action='Stop'}
$running=Wait-Poll 1
Assert (!$running -and $script:Journal.phase -eq 'stopped' -and (Test-Path (Join-Path $directory '002.json'))) 'global stop is honored before pending project commands'
Write-Host "$script:Checks project checks passed (mocked client; no real chats controlled)."
