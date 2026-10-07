#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Run','Status','Cancel','Stop','Probe')][string]$Action = 'Run',
    [ValidateSet('Monitor','Test','Auto')][string]$Mode = 'Monitor',
    [string]$ThreadId,
    [string]$AccountId,
    [string]$StateDirectory,
    [string]$TestQuotaFile,
    [int]$PollSeconds = 30,
    [int]$NearLimitPollSeconds = 5,
    [int]$RecoveryConfirmSeconds = 5,
    [ValidateRange(0,9999)][int]$MaxConsecutiveFailures = 0,
    [ValidateRange(0,99)][double]$PauseRemainingPercent = 5,
    [string]$SettingsPath,
    [switch]$Once,
    [switch]$All,
    [switch]$Raw,
    [switch]$Library
)
$ErrorActionPreference = 'Stop'
$script:ObserveOnly = $false
$script:ResumeAll = $true
$script:ResumeThreadIds = @()
$script:ResumeExcludedThreadIds = @()
$script:AutoResetEnabled = $false
$script:ResetWeeklyRemainingPercent = 1.0
$script:NearLimitRemainingPercent = 10.0
$script:ConfiguredNearLimitPollSeconds = $NearLimitPollSeconds
$script:Utf8 = [Text.UTF8Encoding]::new($false)
if([Console]::IsOutputRedirected){[Console]::OutputEncoding=$script:Utf8}
$script:Pipe = $null
$script:ClientId = $null
$script:OwnerId = $null
$script:QuotaProcess = $null
$script:QuotaReadTask = $null
$script:RpcSequence = 0
$script:Journal = $null
$script:Subscriptions = @{}
$script:FleetJournal = $null
$script:FleetStatePath = $null

function Write-JsonAtomic($Path, $Value) {
    $temporary = $Path + '.tmp'
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 40), $script:Utf8)
    [IO.File]::Move($temporary, $Path, $true)
}
function Read-Json($Path) {
    for($attempt=0;$attempt -lt 4;$attempt++){
        try {
            $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try {$reader=[IO.StreamReader]::new($stream,$script:Utf8);$raw=$reader.ReadToEnd()} finally {$stream.Dispose()}
            return $raw | ConvertFrom-Json -AsHashtable -Depth 100
        } catch [IO.IOException] {if($attempt -eq 3){throw};Start-Sleep -Milliseconds 30}
    }
}
function Read-MonitorSettings {
    if(!$SettingsPath -or !(Test-Path -LiteralPath $SettingsPath)){return}
    $settings=Read-Json $SettingsPath
    if($settings.pollSeconds -lt 1 -or $settings.pollSeconds -gt 3600 -or $settings.pauseRemainingPercent -lt 0 -or $settings.pauseRemainingPercent -gt 99){throw 'Invalid monitor settings.'}
    if($null -ne $settings.resetWeeklyRemainingPercent -and ($settings.resetWeeklyRemainingPercent -lt 0 -or $settings.resetWeeklyRemainingPercent -gt 99)){throw 'Invalid monitor settings.'}
    if($null -ne $settings.nearLimitRemainingPercent -and ($settings.nearLimitRemainingPercent -lt 0 -or $settings.nearLimitRemainingPercent -gt 100)){throw 'Invalid monitor settings.'}
    if($null -ne $settings.nearLimitPollSeconds -and ($settings.nearLimitPollSeconds -lt 1 -or $settings.nearLimitPollSeconds -gt 3600)){throw 'Invalid monitor settings.'}
    if($null -ne $settings.maxConsecutiveFailures -and ($settings.maxConsecutiveFailures -lt 0 -or $settings.maxConsecutiveFailures -gt 9999 -or $settings.maxConsecutiveFailures -ne [int]$settings.maxConsecutiveFailures)){throw 'Invalid monitor settings.'}
    $previous=Get-MonitorPolicy | ConvertTo-Json -Compress
    $script:PollSeconds=[int]$settings.pollSeconds
    $script:ConfiguredNearLimitPollSeconds=$(if($null -ne $settings.nearLimitPollSeconds){[int]$settings.nearLimitPollSeconds}else{$script:PollSeconds})
    $script:NearLimitPollSeconds=[Math]::Min($script:PollSeconds,$script:ConfiguredNearLimitPollSeconds)
    $script:NearLimitRemainingPercent=$(if($null -ne $settings.nearLimitRemainingPercent){[double]$settings.nearLimitRemainingPercent}else{10.0})
    $script:MaxConsecutiveFailures=$(if($null -ne $settings.maxConsecutiveFailures){[int]$settings.maxConsecutiveFailures}else{0})
    $script:PauseRemainingPercent=[double]$settings.pauseRemainingPercent
    $script:ObserveOnly=$settings.observeOnly -eq $true
    $script:ResumeAll=$settings.resumeAll -eq $true
    $script:ResumeThreadIds=@($settings.resumeThreadIds | Where-Object {$_})
    $script:ResumeExcludedThreadIds=@($settings.resumeExcludedThreadIds | Where-Object {$_})
    $script:AutoResetEnabled=$settings.autoResetEnabled -eq $true
    $script:ResetWeeklyRemainingPercent=$(if($null -ne $settings.resetWeeklyRemainingPercent){[double]$settings.resetWeeklyRemainingPercent}else{1.0})
    if($previous -ne (Get-MonitorPolicy | ConvertTo-Json -Compress) -and $script:Journal){Write-Event 'settings-updated' @{pollSeconds=$PollSeconds;pauseRemainingPercent=$PauseRemainingPercent;observeOnly=$script:ObserveOnly;resumeAll=$script:ResumeAll;selectedCount=$script:ResumeThreadIds.Count;excludedCount=$script:ResumeExcludedThreadIds.Count;autoResetEnabled=$script:AutoResetEnabled;resetWeeklyRemainingPercent=$script:ResetWeeklyRemainingPercent}}
}
function Get-MonitorPolicy {
    return [ordered]@{pollSeconds=$PollSeconds;nearLimitPollSeconds=$script:ConfiguredNearLimitPollSeconds;nearLimitRemainingPercent=$script:NearLimitRemainingPercent;maxConsecutiveFailures=$MaxConsecutiveFailures;pauseRemainingPercent=$PauseRemainingPercent;observeOnly=$script:ObserveOnly;resumeAll=$script:ResumeAll;resumeThreadIds=@($script:ResumeThreadIds | Sort-Object);resumeExcludedThreadIds=@($script:ResumeExcludedThreadIds | Sort-Object);autoResetEnabled=$script:AutoResetEnabled;resetWeeklyRemainingPercent=$script:ResetWeeklyRemainingPercent}
}
function Get-PollDelay($Quota,$Records,[int]$ActiveCount=-1) {
    $records=@($Records)
    if(@($records|Where-Object phase -in @('pause_pending','resume_submitting')).Count){return [Math]::Min($PollSeconds,$NearLimitPollSeconds)}
    if($ActiveCount -eq 0){return $PollSeconds}
    if(@($records|Where-Object phase -in @('paused','queued','held')).Count -and ($ActiveCount -eq 0 -or ($ActiveCount -lt 0 -and !@($records|Where-Object phase -in @('observing','resumed')).Count))){return $PollSeconds}
    return $(if($Quota.remaining -le $script:NearLimitRemainingPercent){[Math]::Min($PollSeconds,$NearLimitPollSeconds)}else{$PollSeconds})
}
function Test-FailureLimitReached([int]$Failures) {
    return $MaxConsecutiveFailures -gt 0 -and $Failures -ge $MaxConsecutiveFailures
}
function Get-QuotaStatus($Quota) {
    if($null -ne $Quota.weeklyRemaining -and $Quota.weeklyRemaining -le 0){return '周额度耗尽'}
    if($Quota.remaining -le 0){return '五小时额度耗尽'}
    if($Quota.spendControlReached){return '账号消费上限已触发'}
    if(!$Quota.allowed){return '服务暂不允许使用，请查看客户端额度/账号提示'}
    if($Quota.remaining -le $PauseRemainingPercent){return '达到暂停阈值'}
    return '额度可用'
}
function Test-AutoResumeAllowed($State) {
    if($State.manualHold){return $false}
    if($State.manualStart){return $true}
    return $(if($script:ResumeAll){$State.threadId -notin $script:ResumeExcludedThreadIds}else{$State.threadId -in $script:ResumeThreadIds})
}
function Get-AutoResumePendingCount($Records) {
    if($Mode -eq 'Monitor' -or $script:ObserveOnly){return 0}
    return @($Records|Where-Object {
        if($_.pendingCommand){return $_.pendingCommand.action -eq 'Start' -or ($_.pendingCommand.action -eq 'AutoContinue' -and $(if($script:ResumeAll){$_.threadId -notin $script:ResumeExcludedThreadIds}else{$_.threadId -in $script:ResumeThreadIds}))}
        return $_.phase -in @('paused','queued','pause_pending') -and (Test-AutoResumeAllowed $_)
    }).Count
}
function Get-RecoveryWaitReason($State,$Snapshot,$Quota) {
    if($State.phase -notin @('paused','queued','held')){return ''}
    if($State.manualHold){return '手动暂停；需右键开始或登记自动继续'}
    if(!$Snapshot){return '等待客户端加载聊天'}
    if($Mode -eq 'Monitor' -or $script:ObserveOnly){return '只读观察，不提交继续请求'}
    if(!(Test-AutoResumeAllowed $State)){return '未勾选自动继续'}
    if($null -ne $Quota.weeklyRemaining -and $Quota.weeklyRemaining -le 0){return '周额度已耗尽'}
    if($Quota.remaining -le $PauseRemainingPercent){return '五小时额度尚未超过暂停阈值'}
    if(!$Quota.allowed){return (Get-QuotaStatus $Quota)}
    if(@($Snapshot.requests).Count){return '等待你处理聊天内的输入或审批'}
    if((Get-ActiveTurn $Snapshot) -or $Snapshot.threadRuntimeStatus.type -eq 'active'){return '聊天仍在执行'}
    return '正在连续确认额度和原任务状态'
}
function Save-Journal {
    Write-JsonAtomic (Join-Path $script:RunDirectory 'state.json') $script:Journal
    if($script:FleetJournal -and $script:Journal -ne $script:FleetJournal) {
        Write-JsonAtomic $script:FleetStatePath $script:FleetJournal
    }
}
function Get-ChineseReason($Reason) {
    switch -Regex ([string]$Reason) {
        'resume-outcome-unknown-no-resend' { return '没有确认到继续请求的结果。为避免重复执行，已停止自动处理；请先查看聊天当前进度。' }
        'pause-not-confirmed' { return '客户端尚未确认暂停结果，请查看聊天是否仍在执行。' }
        'user-or-another-client-started-new-work|turn-changed-before-interrupt' { return '你或其他客户端已经改变了任务进度，本次旧任务的自动恢复已取消。' }
        'goal-changed|goal-state-changed' { return '目标已被修改、取消或手动接管，旧目标的自动恢复已取消。' }
        'goal-resume-not-confirmed' { return '目标恢复未确认，已停止自动处理；请查看该聊天的目标状态。' }
        'thread-finished-before-pause-confirmation' { return '任务在暂停确认前已经完成。' }
        'identity mismatch|identity/mode mismatch' { return '账号或聊天身份与保存的记录不一致，请核对登录账号和状态目录。' }
        'mode mismatch' { return '当前运行模式与已有记录不一致，请使用对应的模式或另一个状态目录。' }
        'Unsupported snapshot|request-version-mismatch' { return '客户端返回的通信协议无法解析，请保留日志排查。' }
        'Invalid monitor settings' { return '设置文件中的查询间隔或暂停阈值无效，请在窗口内重新保存设置。' }
        'Conversion from JSON|Invalid IPC frame' { return '客户端返回的数据无法解析。请使用最新脚本；若仍失败，保留事件日志排查。' }
        'timeout|timed out|超时' { return '等待客户端响应超时，请确认 Codex 客户端保持打开且网络可用。' }
        'connection closed|server closed|broken pipe|管道.*结束' { return '与客户端的连接已断开，请确认 Codex 客户端仍在运行。' }
        'no-client-found|client-disconnected' { return '当前客户端暂时无法接管该聊天。' }
        'account login is required' { return '需要先登录 ChatGPT 账号，再运行监控器。' }
        'Five-hour quota is unavailable' { return '暂时无法取得五小时额度，自动控制已停止。' }
        'Codex desktop package was not found' { return '没有找到 Codex 桌面客户端，请检查安装状态。' }
        'Codex CLI executable was not found' { return '没有找到 Codex 命令程序，请检查桌面客户端是否完整安装。' }
        'already running|already controls' { return '已有监控实例正在运行，请先停止旧实例，避免重复控制。' }
        'No saved run state' { return '还没有监控记录，请先运行 start-monitor.ps1 启动监控。' }
        'This run has ended' { return '这份单聊天记录已结束；重新登记时需要换一个状态目录。' }
        'Specify|Use -All or -ThreadId|Polling intervals' { return '启动参数不完整或不正确；监控全部聊天时直接运行 start-monitor.ps1 即可。' }
        'Test mode|simulated|TestQuotaFile|requires explicit' { return '测试配置不完整或真实额度不足，请检查测试文件和账号额度。' }
        default { return '发生未识别的运行错误，原始原因保存在事件日志中，请保留日志排查。' }
    }
}
function Get-ChatLabel {
    if($script:Journal.displayTitle){return ('聊天「{0}」' -f $script:Journal.displayTitle)}
    if($ThreadId -and $ThreadId -ne 'all'){return ('聊天（{0}）' -f $ThreadId.Substring(0,[Math]::Min(8,$ThreadId.Length)))}
    return '当前聊天'
}
function Get-ResetText($Timestamp) {
    if(!$Timestamp){return '尚未取得重置时间'}
    return [DateTimeOffset]::FromUnixTimeSeconds([long]$Timestamp).LocalDateTime.ToString('MM-dd HH:mm:ss')
}
function Get-ChineseEvent($Name,$Details) {
    $label=Get-ChatLabel
    switch($Name) {
        {$_ -in @('all-started','started')} {
            $scope=$(if($All){'全部本机聊天（含目标任务）'}else{$label})
            $operation=$(if($Mode -eq 'Monitor' -or $script:ObserveOnly){'只读观察'}elseif($Mode -eq 'Test'){'测试监控'}else{'自动监控'})
            return "${operation}已启动：$scope；暂停阈值 $PauseRemainingPercent%。"
        }
        'checking-quota' { return '正在读取账号的五小时额度和周额度……' }
        'discovering-chats' { return ('额度读取成功：五小时剩余 {0}%，周额度剩余 {1}。正在查找本机聊天……' -f $Details.remaining,$Details.weeklyText) }
        'checking-owners' { return ('发现 {0} 个桌面聊天条目，正在确认哪些可由当前客户端处理……' -f $Details.count) }
        'checking-task-state' { return ('正在向客户端核实 {0} 个已加载聊天的实际任务状态……' -f $Details.count) }
        'monitor' {
            $runtime=$(if($Details.runtime -eq 'active'){'正在执行'}else{'当前空闲'})
            $action=$(switch($Details.wouldDo){'Pause'{'按规则应暂停'}'RecoveryReady'{'按规则已可进行恢复确认'}'Completed'{'当前轮次已完成'}'UserChanged'{'任务已被用户或其他客户端接管'}default{'保持当前状态，继续观察'}})
            return "$label$runtime；五小时额度剩余 $($Details.remaining)%。$action。"
        }
        'all-monitor' {
            $c=$Details.counts;$normal=$c.ordinaryActive
            $weekly=$(if($null -eq $Details.weeklyRemaining){'未知'}else{"$($Details.weeklyRemaining)%"})
            $runningGoals=[int]$c.active-[int]$c.ordinaryActive
            $message="五小时余 $($Details.remaining)% | 周余 $weekly | 执行中 $($c.active)（普通 $normal，目标 $runningGoals） | 已暂停 $($c.paused) | 恢复后待续 $([int]$c.autoResumePending)"
            $status=Get-QuotaStatus @{remaining=$Details.remaining;weeklyRemaining=$Details.weeklyRemaining;allowed=$Details.allowed;spendControlReached=$Details.spendControlReached}
            if($status -eq '额度可用'){$status=$(if($c.paused){'等待恢复'}else{'正常监控'})}
            if($Mode -eq 'Monitor' -or $script:ObserveOnly){$status="只读观察（$status）"}
            $message+=" | $status"
            if($c.goals -gt $runningGoals){$message+=" | 目标待续 $([int]$c.goals-$runningGoals)"}
            if($c.otherMonitor){$message+=" | 其他实例接管 $($c.otherMonitor)"}
            if($c.needsAttention){$message+=" | 需排查 $($c.needsAttention)"}
            return $message
        }
        'pause_pending' { if($script:Journal.pausedForGoal){return "正在暂停$label 的目标和当前执行。"};return "正在请求暂停$label；实际暂停结果还需客户端确认。" }
        'interrupt-response' { if($script:Journal.pausedForGoal){return "$label 的目标暂停请求已完成，等待状态确认。"};if($Details.interruptedTurnId){return "客户端已接收$label 的中断请求，正在等待暂停确认。"};return "$label 的轮次已变化，没有中断新的任务。" }
        'paused' { if($script:Journal.manualHold){return "已确认$label 手动暂停；不会自动继续，可右键开始或登记自动继续。"};return "已确认$label 暂停。额度可用并通过两次检查后恢复，无需等待原重置时间。" }
        'recovery-first-check' { return "$label 已通过第一次恢复检查，至少等待 $RecoveryConfirmSeconds 秒，再次确认额度和任务状态。" }
        'resume_submitting' { return "正在发送$label 的继续请求，请任务先检查已有进度，避免重复操作。" }
        'resume-response' { if($Details.ok){return "客户端已接受$label 的继续请求，正在确认新一轮执行。"};return "$label 的继续请求尚未确认成功，请等待状态核实。" }
        'resumed' { return "已确认$label 开始继续执行。" }
        'completed' { return "$label 的本轮执行已结束，不据此判定整个项目已完成。" }
        'failed' {return "$label 的本轮执行失败，请查看客户端错误；不作为项目完成。"}
        'quota-interrupted' {return "$label 因额度不足中断，已登记等待恢复；勾选自动继续且额度通过检查后继续。"}
        'manual-registered' {return "$label 已登记自动继续，包含空闲或已结束的任务；额度可用后提交一次继续请求。"}
        'manual-command-queued' {
            $action=switch($Details.action){'Pause'{'手动暂停'}'Start'{'手动开始'}'AutoContinue'{'登记自动继续'}'CancelAuto'{'取消自动继续'}}
            return "项目「$($Details.title)」的$action 请求已保存，等待客户端核实后处理。"
        }
        'manual-held' {return "$label 已保持手动暂停，不会自动继续；可右键开始或登记自动继续。"}
        'manual-start' {return "$label 已收到手动开始请求，检查额度和原任务后执行。"}
        'manual-already-active' {return "$label 已在执行，本次没有重复提交开始请求。"}
        'manual-rejected' {return "$label 的操作未执行：$($Details.reason)"}
        'settings-updated' {
            $operation=$(if($Details.observeOnly){'只读观察'}else{'自动监控'})
            $selection=$(if($Details.resumeAll){"默认允许，排除 $($Details.excludedCount) 个"}else{"已选 $($Details.selectedCount) 个聊天"})
            $reset=$(if($Details.autoResetEnabled){"开启，周剩余 ≤$($Details.resetWeeklyRemainingPercent)% 触发"}else{'关闭'})
            $retry=$(if($MaxConsecutiveFailures -gt 0){"连续失败 $MaxConsecutiveFailures 次停止监控"}else{'失败持续重试，不自动停止'})
            return "设置已应用：每 $($Details.pollSeconds) 秒查询，五小时剩余 ≤$($Details.pauseRemainingPercent)% 暂停；$operation；自动继续：$selection；自动重置卡：$reset；$retry。"
        }
        'reset-requested' {return "周额度剩余 $($Details.weeklyRemaining)%，已登记使用一张重置卡，正在等待服务器结果。"}
        'reset-result' {return $(switch($Details.outcome){'reset'{'服务器确认已使用一张重置卡，正在重新查询实际额度。'}'alreadyRedeemed'{'同一重置请求此前已成功，正在重新查询实际额度。'}'nothingToReset'{'服务器当前没有可重置的额度，本次未使用卡；额度耗尽或窗口变化后再检查。'}'noCredit'{'服务器返回没有可用重置卡。'}default{'重置卡结果未知，保留同一请求编号核实。'}})}
        'reset-error' {return $(if($Details.stage -eq 'finished'){'重置卡结果已记录，但新额度读取失败；保留使用记录，稍后重新查询额度。'}else{'重置卡请求结果尚未确认；下一次核实沿用同一请求编号，避免重复消耗。'})}
        'reset-refreshed' {return "重置后实际查询：五小时余 $($Details.remaining)%，周余 $($Details.weeklyRemaining)%，可用卡 $($Details.availableCount) 张。"}
        'waiting' {
            $message="等待 $($Details.seconds) 秒后进行下一次检查；程序仍在运行。"
            if($Details.paused){$message+=" 当前有 $($Details.paused) 个聊天保持暂停；额度可用后还会检查账号、周额度和任务状态。"}
            return $message
        }
        {$_ -in @('all-read-error','connection-or-read-error')} {
            $policy=$(if($Details.error -match 'identity mismatch|Unsupported|Invalid simulated|Real quota is insufficient|requires explicit'){'任务身份或通信校验未通过，将停止自动处理'}elseif(Test-FailureLimitReached $Details.failures){"达到设定的 $MaxConsecutiveFailures 次，将停止监控"}elseif($MaxConsecutiveFailures -gt 0){"达到 $MaxConsecutiveFailures 次才停止监控；将重试"}else{'已关闭自动停止；将持续重试'})
            return "查询连续失败 $($Details.failures) 次；$policy。$(Get-ChineseReason $Details.error)"
        }
        'thread-control-error' { return "$label 的操作暂未确认。$(Get-ChineseReason $Details.error)" }
        'owner-unavailable' { return '有一个聊天暂时无法由当前客户端处理，已跳过本次查询。' }
        'removed-chat' { return '一个已登记聊天已归档或移除，取消它的旧任务自动恢复。' }
        'needs_attention' {
            $target=$(if($script:Journal.scope -eq 'all'){'监控已停止'}else{"$label 的自动处理已停止"})
            return "$target，需要处理后再运行。$(Get-ChineseReason $Details.reason)"
        }
        'stopped' { return '监控已停止。已暂停任务的记录保留，手动再次启动时会重新检查恢复条件。' }
        'cancelled' { return ('{0}。' -f $(if($Details.reason){Get-ChineseReason $Details.reason}else{'已解除本次监控登记，不会再自动恢复这些旧任务'})) }
        'single-check-finished' { return '单次检查已完成，本次程序退出。' }
        'fatal-error' { return "无法继续运行。$(Get-ChineseReason $Details.error)" }
        default { return '监控状态已更新，详细记录已保存。' }
    }
}
function Write-Event($Name, $Details = @{}) {
    $message=Get-ChineseEvent $Name $Details
    $entry = @{ time = [DateTimeOffset]::UtcNow.ToString('o'); event = $Name; mode = $Mode; threadId = $ThreadId; details = $Details }
    $entry.message=$message
    $entry.chatTitle=$(if($script:Journal.displayTitle){$script:Journal.displayTitle}elseif($ThreadId -eq 'all'){'全部聊天'}else{''})
    if($Name -eq 'manual-command-queued'){$entry.threadId=$Details.threadId;$entry.chatTitle=$Details.title}
    $entry.settings=Get-MonitorPolicy
    if($script:Journal.lastQuota){
        $q=$script:Journal.lastQuota
        $entry.quota=@{remaining=$q.remaining;weeklyRemaining=$q.weeklyRemaining;resetsAt=$q.resetsAt;weeklyResetsAt=$q.weeklyResetsAt;simulated=$q.simulated}
        $entry.quotaCheckedAt=$script:Journal.lastCheckedAt
        $entry.resetCredits=$q.resetCredits
    }
    [IO.File]::AppendAllText((Join-Path $script:RunDirectory 'events.jsonl'), ($entry | ConvertTo-Json -Compress -Depth 10) + "`n", $script:Utf8)
    # Routine progress stays in the journal; the console shows one summary per cycle.
    if($Name -in @('checking-quota','discovering-chats','checking-owners','checking-task-state','waiting','recovery-first-check')){return}
    if($All -and $Name -eq 'monitor'){return}
    if(($Name -eq 'interrupt-response' -and ($Details.interruptedTurnId -or ($script:Journal.pausedForGoal -and $Details.ok))) -or ($Name -eq 'resume-response' -and $Details.ok)){return}
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $message)
}
function Set-Phase($Phase, $Details = @{}) {
    $script:Journal.phase = $Phase
    Save-Journal
    Write-Event $Phase $Details
}
function Show-SavedStatus($State,$Path) {
    $phaseText=switch($State.phase){
        'observing'{'已登记，等待或执行检查'}
        'pause_pending'{'已请求暂停，等待客户端确认'}
        'paused'{'已确认暂停，等待额度恢复'}
        'resume_submitting'{'已提交继续请求，等待确认'}
        'resumed'{'已确认继续执行'}
        'completed'{'任务已完成'}
        'stopped'{'监控已停止'}
        'cancelled'{'已解除登记'}
        'needs_attention'{'自动处理已停止，需要排查'}
        default{'尚无可识别的状态记录'}
    }
    $modeText=switch($State.mode){'Auto'{'自动监控'}'Monitor'{'只读观察'}'Test'{'测试监控'}default{'未记录'}}
    Write-Host ('保存的监控记录：{0}；{1}。' -f $modeText,$phaseText)
    Write-Host '以下是上次保存的结果；当前实时进度请查看监控窗口。'
    if($State.lastCheckedAt){Write-Host ('上次检查时间：{0}' -f [DateTimeOffset]::Parse($State.lastCheckedAt).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss'))}
    if($State.lastQuota){
        Write-Host ('五小时额度剩余：{0}%；记录的重置时间：{1}。' -f $State.lastQuota.remaining,(Get-ResetText $State.lastQuota.resetsAt))
        if($null -ne $State.lastQuota.weeklyRemaining){Write-Host ('周额度剩余：{0}%。' -f $State.lastQuota.weeklyRemaining)}
    }
    if($State.scope -eq 'all'){
        Write-Host ('登记聊天：{0} 个；已确认暂停：{1} 个；需要排查：{2} 个。' -f $State.threads.Count,@($State.threads.Values|Where-Object phase -eq 'paused').Count,@($State.threads.Values|Where-Object phase -eq 'needs_attention').Count)
    }
    Write-Host ('状态文件：{0}' -f $Path)
}
function Get-DesktopVersion {
    $package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop
    if (!$package) { throw 'Codex desktop package was not found.' }
    return $package.Version.ToString()
}
function Close-Ipc {
    if ($script:Pipe) {
        try {
            if ($script:Pipe.IsConnected -and $script:ClientId) {
                foreach($id in @($script:Subscriptions.Keys)) {
                    Send-Ipc @{type='broadcast';sourceClientId=$script:ClientId;version=1;method='thread-stream-following-changed';targetClientIds=@($script:Subscriptions[$id]);params=@{hostId='local';conversationId=$id;following=$false}}
                }
            }
        } catch { }
        $script:Pipe.Dispose()
    }
    $script:Pipe = $null; $script:ClientId = $null; $script:OwnerId = $null
    $script:Subscriptions = @{}
}
function Send-Ipc($Message) {
    $payload = $script:Utf8.GetBytes(($Message | ConvertTo-Json -Compress -Depth 30))
    $prefix = [BitConverter]::GetBytes([int]$payload.Length)
    $script:Pipe.Write($prefix, 0, 4)
    $script:Pipe.Write($payload, 0, $payload.Length)
    $script:Pipe.Flush()
}
function Read-PipeBytes([int]$Length, [DateTime]$Deadline) {
    $buffer = [byte[]]::new($Length); $offset = 0
    while ($offset -lt $Length) {
        $remaining = [int]($Deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($remaining -le 0) { throw 'IPC timeout.' }
        $read = $script:Pipe.ReadAsync($buffer, $offset, $Length - $offset)
        if (!$read.Wait($remaining)) { Close-Ipc; throw 'IPC timeout.' }
        $count = $read.Result
        if (!$count) { throw 'IPC connection closed.' }
        $offset += $count
    }
    return ,$buffer
}
function Read-Ipc([DateTime]$Deadline) {
    $prefix = Read-PipeBytes 4 $Deadline
    $length = [BitConverter]::ToInt32($prefix,0)
    if ($length -le 0 -or $length -gt 268435456) { throw 'Invalid IPC frame size.' }
    $payload = Read-PipeBytes $length $Deadline
    $message = $script:Utf8.GetString($payload) | ConvertFrom-Json -AsHashtable -Depth 100
    if ($message.type -eq 'client-discovery-request') {
        Send-Ipc @{type='client-discovery-response';requestId=$message.requestId;response=@{canHandle=$false}}
    }
    return $message
}
function Invoke-Ipc($Method, $Params, [int]$Version, [int]$TimeoutSeconds = 20, [string]$Target) {
    $requestId = [guid]::NewGuid().ToString()
    $request = @{ type='request'; requestId=$requestId; sourceClientId=$script:ClientId; version=$Version; method=$Method; params=$Params; timeoutMs=$TimeoutSeconds*1000 }
    if ($Target) { $request.targetClientId = $Target }
    Send-Ipc $request
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds + 2)
    while ($true) {
        $reply = Read-Ipc $deadline
        if ($reply.type -eq 'response' -and $reply.requestId -eq $requestId) {
            if ($reply.resultType -ne 'success') { throw ('IPC {0}: {1}' -f $Method,$reply.error) }
            return $reply
        }
    }
}
function Connect-Ipc([switch]$WithoutOwner) {
    Close-Ipc
    $script:Pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'codex-ipc', [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
    $script:Pipe.Connect(4000)
    $script:ClientId = 'initializing-client'
    $reply = Invoke-Ipc 'initialize' @{clientType='quota-monitor-v1'} 0
    $script:ClientId = $reply.result.clientId
    if (!$WithoutOwner) {
        $owner = Invoke-Ipc 'thread-owner-discovery' @{hostId='local';conversationId=$ThreadId} 1
        $script:OwnerId = $owner.handledByClientId
    }
}
function Get-Snapshot {
    if (!$script:Pipe -or !$script:Pipe.IsConnected) { Connect-Ipc }
    Send-Ipc @{type='broadcast';sourceClientId=$script:ClientId;version=1;method='thread-stream-following-changed';targetClientIds=@($script:OwnerId);params=@{hostId='local';conversationId=$ThreadId;following=$true}}
    $script:Subscriptions[$ThreadId]=$script:OwnerId
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ($true) {
        $message = Read-Ipc $deadline
        if ($message.method -eq 'thread-stream-state-changed' -and $message.params.conversationId -eq $ThreadId -and $message.params.change.type -eq 'snapshot') {
            if ($message.version -ne 11) { throw 'Unsupported snapshot protocol version.' }
            $snapshot = $message.params.change.conversationState
            if ($snapshot.id -ne $ThreadId -or $snapshot.hostId -ne 'local') { throw 'Snapshot identity mismatch.' }
            return $snapshot
        }
    }
}
function Get-Turns($Snapshot) {
    $seen = @{}
    if ($Snapshot.turnHistory.kind -eq 'canonical') {
        foreach ($island in $Snapshot.turnHistory.history.islands) {
            foreach ($entry in $island.entries) {
                $turn = $Snapshot.turnHistory.history.entitiesByKey[$entry.value]
                if ($turn -and $turn.turnId -and !$seen.ContainsKey($turn.turnId)) {
                    $seen[$turn.turnId] = $true; $turn
                }
            }
        }
    }
    foreach ($turn in $Snapshot.turns) {
        if ($turn.turnId -and !$seen.ContainsKey($turn.turnId)) { $seen[$turn.turnId]=$true; $turn }
    }
}
function Get-ActiveTurn($Snapshot) {
    $active = @(Get-Turns $Snapshot | Where-Object status -eq 'inProgress')
    if ($active.Count -gt 1) { throw 'More than one active turn; refusing ambiguous control.' }
    if ($active.Count) { return $active[0] }
    return $null
}
function Stop-QuotaServer {
    if ($script:QuotaProcess) {
        try {
            if (!$script:QuotaProcess.HasExited) {
                $script:QuotaProcess.StandardInput.Close()
                if (!$script:QuotaProcess.WaitForExit(2000)) { $script:QuotaProcess.Kill() }
            }
        } finally { $script:QuotaProcess.Dispose() }
    }
    $script:QuotaProcess = $null; $script:QuotaReadTask = $null
}
function Invoke-QuotaRpc($Method, $Params) {
    $script:RpcSequence++
    $message = @{id=$script:RpcSequence;method=$Method}
    if ($null -ne $Params) { $message.params=$Params }
    $script:QuotaProcess.StandardInput.WriteLine(($message | ConvertTo-Json -Compress -Depth 10))
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ($true) {
        if (!$script:QuotaReadTask) { $script:QuotaReadTask=$script:QuotaProcess.StandardOutput.ReadLineAsync() }
        $remaining = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($remaining -le 0 -or !$script:QuotaReadTask.Wait($remaining)) { Stop-QuotaServer; throw 'Quota RPC timeout.' }
        $line = $script:QuotaReadTask.Result; $script:QuotaReadTask=$null
        if ($null -eq $line) { throw 'Quota server closed.' }
        $reply = $line | ConvertFrom-Json -AsHashtable -Depth 40
        if ($reply.id -eq $script:RpcSequence) {
            if ($reply.error) { throw ('Quota RPC {0}: {1}' -f $Method,$reply.error.message) }
            return $reply.result
        }
    }
}
function Get-CodexExecutable {
    $command=Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue
    if($command){return $command.Source}
    $binDirectory=Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if(Test-Path -LiteralPath $binDirectory) {
        foreach($directory in @(Get-ChildItem -LiteralPath $binDirectory -Directory|Sort-Object LastWriteTime -Descending)) {
            $candidate=Join-Path $directory.FullName 'codex.exe'
            if(Test-Path -LiteralPath $candidate){return $candidate}
        }
    }
    throw 'Codex CLI executable was not found in PATH or the desktop local bin directory.'
}
function Start-QuotaServer {
    Stop-QuotaServer
    $codex = Get-CodexExecutable
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = [Diagnostics.ProcessStartInfo]::new($codex, 'app-server')
    $process.StartInfo.UseShellExecute=$false; $process.StartInfo.CreateNoWindow=$true
    $process.StartInfo.RedirectStandardInput=$true; $process.StartInfo.RedirectStandardOutput=$true; $process.StartInfo.RedirectStandardError=$true
    # app-server JSON is UTF-8 even when a Windows PowerShell 5.1 parent uses code page 936.
    $process.StartInfo.StandardInputEncoding=$script:Utf8
    $process.StartInfo.StandardOutputEncoding=$script:Utf8
    $process.StartInfo.StandardErrorEncoding=$script:Utf8
    [void]$process.Start()
    $script:QuotaProcess=$process
    if ($script:Journal) { $script:Journal.quotaProcessId=$process.Id }
    # Drain stderr without printing credentials or retaining it in a deliverable.
    $script:QuotaErrorDrain=$process.StandardError.ReadToEndAsync()
    [void](Invoke-QuotaRpc 'initialize' @{clientInfo=@{name='quota_monitor_v1';title='Quota monitor v1';version='0.1.0'}})
    $process.StandardInput.WriteLine('{"method":"initialized"}')
    $account = Invoke-QuotaRpc 'account/read' @{refreshToken=$false}
    if ($account.account.type -ne 'chatgpt') { throw 'A ChatGPT account login is required.' }
}
function Get-LiveQuota {
    # A persistent standalone app-server can return its cached limits indefinitely.
    # A fresh read process gets a current service snapshot without touching desktop work.
    Start-QuotaServer
    $result = Invoke-QuotaRpc 'account/rateLimits/read' $null
    if ($All -and !$AccountId -and $result.accountId) { $script:AccountId=$result.accountId }
    if (!$result.accountId -or $result.accountId -ne $AccountId) { throw 'Account identity mismatch; automatic control is disabled.' }
    $bucket = $result.rateLimitsByLimitId.codex
    if (!$bucket) { $bucket=$result.rateLimits }
    if ($null -eq $bucket.primary.usedPercent -or $bucket.primary.windowDurationMins -ne 300 -or !$bucket.primary.resetsAt) { throw 'Five-hour quota is unavailable.' }
    return @{
        accountId=$result.accountId; remaining=100-[double]$bucket.primary.usedPercent; resetsAt=[long]$bucket.primary.resetsAt
        weeklyRemaining=$(if ($null -ne $bucket.secondary.usedPercent) {100-[double]$bucket.secondary.usedPercent} else {$null})
        weeklyResetsAt=$(if($bucket.secondary.resetsAt){[long]$bucket.secondary.resetsAt}else{$null})
        allowed=($result.ordinaryUsageAllowed -eq $true -and !$bucket.rateLimitReachedType -and !$bucket.spendControlReached)
        simulated=$false
        resetCredits=$result.rateLimitResetCredits
        spendControlReached=$bucket.spendControlReached
        reachedType=$bucket.rateLimitReachedType
        ordinaryUsageAllowed=$result.ordinaryUsageAllowed
    }
}
function Test-QuotaInterrupted($Snapshot) {
    if((Get-ActiveTurn $Snapshot) -or $Snapshot.threadRuntimeStatus.type -eq 'active'){return $false}
    $turns=@(Get-Turns $Snapshot);$latest=$(if($turns.Count){$turns[-1]}else{$null})
    if(!$latest.turnId -or !$Snapshot.latestTurnStartMessageId){return $false}
    return $Snapshot.threadGoal.status -eq 'usageLimited' -or ($latest.status -eq 'failed' -and ($latest.error.codexErrorInfo -eq 'usageLimitExceeded' -or $latest.error.codexErrorInfo.usageLimitExceeded))
}
function Get-QuotaWithAutoReset {
    $live=Get-LiveQuota
    $script:Journal.accountId=$live.accountId
    $script:Journal.lastQuota=$live;$script:Journal.lastCheckedAt=[DateTimeOffset]::UtcNow.ToString('o')
    $script:Journal.resetStatus='自动使用已关闭'
    if($Mode -ne 'Auto' -or $script:ObserveOnly){$script:Journal.resetStatus='只读/测试模式，不使用卡';return $live}
    if(!$script:AutoResetEnabled){return $live}
    if($null -eq $live.weeklyRemaining){$script:Journal.resetStatus='周额度未知，不使用卡';return $live}
    $attempt=$script:Journal.resetAttempt
    if($live.weeklyRemaining -gt $script:ResetWeeklyRemainingPercent){
        $script:Journal.resetStatus='未达到周额度触发值'
        # A successful low-quota episode must visibly recover before another card is eligible.
        if($attempt -and $attempt.stage -eq 'finished'){$script:Journal.resetAttempt=$null;Save-Journal}
        return $live
    }
    $eligibility="$($live.weeklyResetsAt)|$($live.weeklyRemaining -le 0)|$($live.resetCredits.availableCount)"
    if($attempt -and $attempt.stage -eq 'finished'){
        if($attempt.outcome -in @('reset','alreadyRedeemed')){$script:Journal.resetStatus='已使用，等待实际额度回升；不会连续用卡';return $live}
        if($attempt.eligibility -eq $eligibility){$script:Journal.resetStatus=$(if($attempt.outcome -eq 'noCredit'){'没有可用卡'}else{'服务器暂不允许重置，等待额度窗口变化'});return $live}
        $attempt=$null
    }
    if(!$attempt){
        if($null -eq $live.resetCredits.availableCount){$script:Journal.resetStatus='卡片数量未知，不使用卡';return $live}
        if($live.resetCredits.availableCount -lt 1){$script:Journal.resetStatus='没有可用卡';return $live}
        $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $credit=$live.resetCredits.credits | Where-Object {$_.id -and $_.status -eq 'available' -and $_.resetType -eq 'codexRateLimits' -and (!$_.expiresAt -or $_.expiresAt -gt $now)} | Sort-Object @{Expression={if($_.expiresAt){[long]$_.expiresAt}else{[long]::MaxValue}}} | Select-Object -First 1
        if($null -ne $live.resetCredits.credits -and !$credit){$script:Journal.resetStatus='没有符合条件的 Codex 重置卡';return $live}
        $attempt=@{idempotencyKey=[guid]::NewGuid().ToString();creditId=$credit.id;stage='pending';eligibility=$eligibility;weeklyBefore=$live.weeklyRemaining;fiveBefore=$live.remaining;startedAt=[DateTimeOffset]::UtcNow.ToString('o');lastTryAt=0}
        $script:Journal.resetAttempt=$attempt
        Save-Journal
        Write-Event 'reset-requested' @{weeklyRemaining=$live.weeklyRemaining;idempotencyKey=$attempt.idempotencyKey;creditId=$attempt.creditId}
    }
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if($attempt.lastTryAt -and $now-[long]$attempt.lastTryAt -lt 30){$script:Journal.resetStatus='结果待核实，至少间隔 30 秒再查询同一请求';return $live}
    $attempt.lastTryAt=$now;Save-Journal
    $params=@{idempotencyKey=$attempt.idempotencyKey}
    if($attempt.creditId){$params.creditId=$attempt.creditId}
    try {
        $reply=Invoke-QuotaRpc 'account/rateLimitResetCredit/consume' $params
        if($reply.outcome -notin @('reset','alreadyRedeemed','nothingToReset','noCredit')){throw 'Unknown rate-limit reset outcome.'}
        $attempt.stage='finished';$attempt.outcome=$reply.outcome;$attempt.finishedAt=[DateTimeOffset]::UtcNow.ToString('o');Save-Journal
        Write-Event 'reset-result' @{outcome=$reply.outcome;idempotencyKey=$attempt.idempotencyKey}
        $script:Journal.resetStatus=$(if($reply.outcome -in @('reset','alreadyRedeemed')){'已使用，正在确认额度'}elseif($reply.outcome -eq 'noCredit'){'没有可用卡'}else{'服务器暂不允许重置'})
        # The response carries no new limits. Query them instead of assuming 100%.
        $live=Get-LiveQuota
        $script:Journal.lastQuota=$live;$script:Journal.lastCheckedAt=[DateTimeOffset]::UtcNow.ToString('o')
        Save-Journal
        Write-Event 'reset-refreshed' @{remaining=$live.remaining;weeklyRemaining=$live.weeklyRemaining;availableCount=$live.resetCredits.availableCount}
    } catch {
        $script:Journal.resetStatus=$(if($attempt.stage -eq 'finished'){'结果已记录，额度查询失败'}else{'请求结果待核实，保留同一编号'})
        Write-Event 'reset-error' @{error=$_.Exception.Message;idempotencyKey=$attempt.idempotencyKey;stage=$attempt.stage}
    }
    return $live
}
function Get-EffectiveQuota($Live) {
    if ($Mode -ne 'Test') { return $Live }
    if (!$Live.allowed -or $Live.remaining -le $PauseRemainingPercent -or ($null -ne $Live.weeklyRemaining -and $Live.weeklyRemaining -le 0)) { throw 'Real quota is insufficient for Test mode.' }
    $test = Read-Json $TestQuotaFile
    if ($test.simulation -ne $true -or $test.remaining -lt 0 -or $test.remaining -gt 100 -or !$test.resetsAt) { throw 'Invalid simulated quota fixture.' }
    return @{accountId=$Live.accountId;remaining=[double]$test.remaining;resetsAt=[long]$test.resetsAt;weeklyRemaining=$test.weeklyRemaining;allowed=($test.allowed -eq $true);simulated=$true}
}
function Test-SameGoal($Goal,$Saved) {
    return $null -ne $Goal -and $null -ne $Saved -and $Goal.createdAt -eq $Saved.createdAt -and $Goal.objective -eq $Saved.objective -and $Goal.tokenBudget -eq $Saved.tokenBudget
}
function Get-GoalDecision($State,$Snapshot,$Quota,[long]$Now) {
    $goal=$Snapshot.threadGoal;$active=Get-ActiveTurn $Snapshot
    if($State.pausedForGoal -and $State.phase -in @('pause_pending','paused','queued','resume_submitting')) {
        if(!$goal -or $goal.status -eq 'complete') { return $(if($State.phase -eq 'resume_submitting' -and $Snapshot.latestTurnStartMessageId -eq $State.resumeMessageId){'ResumeConfirmed'}else{'Completed'}) }
        if(!(Test-SameGoal $goal $State.pausedGoal)){return 'UserChanged'}
        if($State.phase -eq 'pause_pending') {
            if($goal.status -eq 'paused' -and !$active -and $Snapshot.threadRuntimeStatus.type -ne 'active'){return 'PauseConfirmed'}
            return 'Wait'
        }
        if($State.phase -eq 'resume_submitting') {
            if($Snapshot.latestTurnStartMessageId -eq $State.resumeMessageId){return 'ResumeConfirmed'}
            if($Snapshot.latestTurnStartMessageId -ne $State.baselineMessageId){return 'UserChanged'}
            return 'Wait'
        }
        $expectedStatus=$(if($State.pausedSource -eq 'quota'){'usageLimited'}else{'paused'})
        if($goal.status -ne $expectedStatus -or $goal.updatedAt -ne $State.pausedGoalUpdatedAt -or $Snapshot.latestTurnStartMessageId -ne $State.baselineMessageId){return 'UserChanged'}
        if($active -or $Snapshot.threadRuntimeStatus.type -eq 'active' -or @($Snapshot.requests).Count){return 'Wait'}
        if((Test-AutoResumeAllowed $State) -and $Quota.allowed -and $Quota.remaining -gt $PauseRemainingPercent -and ($null -eq $Quota.weeklyRemaining -or $Quota.weeklyRemaining -gt 0)){return 'RecoveryReady'}
        return 'Wait'
    }
    if($goal.status -eq 'active') {
        if($Quota.remaining -le $PauseRemainingPercent -or !$Quota.allowed -or ($null -ne $Quota.weeklyRemaining -and $Quota.weeklyRemaining -le 0)){return 'Pause'}
        return 'Wait'
    }
    return $null
}
function Get-Decision($State, $Snapshot, $Quota, [long]$Now) {
    $active = Get-ActiveTurn $Snapshot
    $turns = @(Get-Turns $Snapshot)
    $latest = $(if ($turns.Count) {$turns[-1]} else {$null})
    if ($State.phase -in @('cancelled','stopped','needs_attention','completed','failed','held')) { return 'Wait' }
    if ($State.phase -in @('paused','queued','pause_pending','resume_submitting')) {
        if ($Snapshot.latestTurnStartMessageId -ne $State.baselineMessageId -and $Snapshot.latestTurnStartMessageId -ne $State.resumeMessageId) { return 'UserChanged' }
        if ($active -and $active.turnId -ne $State.pausedTurnId) {
            if ($State.phase -eq 'resume_submitting' -and $Snapshot.latestTurnStartMessageId -eq $State.resumeMessageId) { return 'ResumeConfirmed' }
            return 'UserChanged'
        }
    }
    if($State.phase -notin @('paused','queued','resume_submitting') -and (Test-QuotaInterrupted $Snapshot)){return 'QuotaInterrupted'}
    $goalDecision=Get-GoalDecision $State $Snapshot $Quota $Now
    if($goalDecision){return $goalDecision}
    if ($State.phase -eq 'pause_pending') {
        $paused = $turns | Where-Object turnId -eq $State.pausedTurnId | Select-Object -First 1
        if ($paused.status -eq 'interrupted' -and !$active -and $Snapshot.threadRuntimeStatus.type -ne 'active') { return 'PauseConfirmed' }
        if ($paused.status -in @('completed','failed')) { return 'FinishedDuringPause' }
        return 'Wait'
    }
    if ($State.phase -eq 'resume_submitting') {
        if ($Snapshot.latestTurnStartMessageId -eq $State.resumeMessageId -and $latest.turnId -ne $State.pausedTurnId) { return 'ResumeConfirmed' }
        return 'Wait'
    }
    if ($State.phase -in @('paused','queued')) {
        if ($active -or $Snapshot.threadRuntimeStatus.type -eq 'active' -or @($Snapshot.requests).Count) { return 'Wait' }
        if ((Test-AutoResumeAllowed $State) -and $Quota.allowed -and $Quota.remaining -gt $PauseRemainingPercent -and ($null -eq $Quota.weeklyRemaining -or $Quota.weeklyRemaining -gt 0)) { return 'RecoveryReady' }
        return 'Wait'
    }
    if ($active -and ($Quota.remaining -le $PauseRemainingPercent -or !$Quota.allowed -or ($null -ne $Quota.weeklyRemaining -and $Quota.weeklyRemaining -le 0))) { return 'Pause' }
    if (!$active -and $latest -and $latest.status -eq 'failed' -and $Snapshot.threadRuntimeStatus.type -ne 'active') { return 'Failed' }
    if (!$active -and $latest -and $latest.status -eq 'completed' -and $Snapshot.threadRuntimeStatus.type -ne 'active') { return 'Completed' }
    return 'Wait'
}
function Read-Control {
    $path = Join-Path $script:RunDirectory 'control.json'
    if (!(Test-Path -LiteralPath $path)) { return $null }
    $command=Read-Json $path
    if ($command.id -eq $script:Journal.lastControlId) { return $null }
    $script:Journal.lastControlId=$command.id
    Save-Journal
    return $command.action
}
function Get-DesktopCatalog {
    $threads=@{}; $cursor=$null; $cursors=@{}; $total=0
    do {
        $page=Invoke-QuotaRpc 'thread/list' @{limit=100;cursor=$cursor;archived=$false;useStateDbOnly=$true}
        foreach($thread in $page.data) {
            $total++
            if($thread.originator -eq 'Codex Desktop' -and !$thread.ephemeral -and $thread.id -match '^[0-9a-fA-F-]{36}$') { $threads[$thread.id]=@{id=$thread.id;title=$(if($thread.name){$thread.name}else{([string]$thread.preview -split '\r?\n')[0]});updatedAt=$thread.updatedAt} }
        }
        $cursor=$page.nextCursor
        if($cursor) {
            if($cursors.ContainsKey($cursor)){throw 'Thread catalog returned a repeated cursor.'}
            $cursors[$cursor]=$true
        }
    } while($cursor)
    if($Mode -eq 'Test') {
        $fixture=Read-Json $TestQuotaFile
        if(!@($fixture.threadIds).Count -or !$fixture.threadIds) { throw 'All-chat Test mode requires explicit threadIds in the fixture.' }
        $limited=@{}
        foreach($id in $fixture.threadIds) { if($threads.ContainsKey($id)){$limited[$id]=$threads[$id]} }
        $threads=$limited
    }
    return @{total=$total;ids=@($threads.Keys);chats=@($threads.Values | Sort-Object updatedAt -Descending)}
}
function Get-DesktopOwners($Ids) {
    if(!$script:Pipe -or !$script:Pipe.IsConnected){Connect-Ipc -WithoutOwner}
    $owners=@{}
    # Batch discovery avoids waiting separately for hundreds of inactive historical chats.
    for($offset=0;$offset -lt $Ids.Count;$offset+=100) {
        $pending=@{}
        foreach($id in $Ids[$offset..([Math]::Min($offset+99,$Ids.Count-1))]) {
            $requestId=[guid]::NewGuid().ToString(); $pending[$requestId]=$id
            Send-Ipc @{type='request';requestId=$requestId;sourceClientId=$script:ClientId;version=1;method='thread-owner-discovery';params=@{hostId='local';conversationId=$id};timeoutMs=4000}
        }
        $deadline=[DateTime]::UtcNow.AddSeconds(8)
        while($pending.Count) {
            $reply=Read-Ipc $deadline
            if($reply.type -eq 'response' -and $reply.requestId -and $pending.ContainsKey($reply.requestId)) {
                $id=$pending[$reply.requestId]; $pending.Remove($reply.requestId)
                if($reply.resultType -eq 'success' -and $reply.handledByClientId){$owners[$id]=$reply.handledByClientId}
                elseif($reply.error -ne 'no-client-found'){Write-Event 'owner-unavailable' @{id=$id;reason=$reply.error}}
            }
        }
    }
    return $owners
}
function Get-DesktopSnapshots($Owners) {
    $pending=@{}; $snapshots=@{}
    foreach($id in $Owners.Keys) {
        $pending[$id]=$true
        Send-Ipc @{type='broadcast';sourceClientId=$script:ClientId;version=1;method='thread-stream-following-changed';targetClientIds=@($Owners[$id]);params=@{hostId='local';conversationId=$id;following=$true}}
        $script:Subscriptions[$id]=$Owners[$id]
    }
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    while($pending.Count) {
        $message=Read-Ipc $deadline
        $id=$message.params.conversationId
        if($id -and $pending.ContainsKey($id) -and $message.method -eq 'thread-stream-state-changed' -and $message.params.change.type -eq 'snapshot') {
            if($message.version -ne 11){throw 'Unsupported snapshot protocol version.'}
            $snapshot=$message.params.change.conversationState
            if($snapshot.id -ne $id){throw 'Snapshot identity mismatch.'}
            $pending.Remove($id)
            if($snapshot.hostId -eq 'local' -and $snapshot.originator -eq 'Codex Desktop'){$snapshots[$id]=$snapshot}
        }
    }
    return $snapshots
}
function New-ThreadJournal($Id,$Version) {
    return @{threadId=$Id;accountId=$AccountId;mode=$Mode;appVersion=$Version;phase='observing';lastControlId=$null;recoverySeenAt=$null;resumeMessageId=$null}
}
function Get-ThreadRuntimeLabel($Snapshot) {
    if(!$Snapshot){return '未加载'}
    if(@($Snapshot.requests).Count){return '等待输入或审批'}
    if(Get-ActiveTurn $Snapshot){return '执行中'}
    if(Test-QuotaInterrupted $Snapshot){return '额度中断'}
    if($Snapshot.threadGoal.status -eq 'active'){return '目标待续'}
    if($Snapshot.threadGoal.status -eq 'paused'){return '目标已暂停'}
    return '空闲'
}
function Read-ThreadCommands($Fleet,$Version) {
    $directory=Join-Path $script:RunDirectory 'commands'
    if(!(Test-Path -LiteralPath $directory)){return}
    foreach($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.json' | Sort-Object Name)) {
        $command=Read-Json $file.FullName
        if($command.threadId -notmatch '^[0-9a-fA-F-]{36}$' -or $command.action -notin @('Pause','Start','AutoContinue','CancelAuto')){throw 'Invalid project command.'}
        if(!$Fleet.threads[$command.threadId]){$Fleet.threads[$command.threadId]=New-ThreadJournal $command.threadId $Version}
        $record=$Fleet.threads[$command.threadId]
        if($record.lastManualCommandId -ne $command.id){$record.pendingCommand=$command;Save-Journal;Write-Event 'manual-command-queued' @{threadId=$command.threadId;title=$command.title;action=$command.action}}
        Save-Journal
        Remove-Item -LiteralPath $file.FullName
    }
}
function Apply-ThreadCommand($Snapshot) {
    $record=$script:Journal;$command=$record.pendingCommand
    if(!$command){return}
    $active=Get-ActiveTurn $Snapshot
    $record.pendingCommand=$null;$record.lastManualCommandId=$command.id
    if($Mode -eq 'Monitor' -or $script:ObserveOnly){Save-Journal;Write-Event 'manual-rejected' @{reason='只读观察模式不操作项目。'};return}
    if($record.phase -in @('pause_pending','resume_submitting')){Save-Journal;Write-Event 'manual-rejected' @{reason='上一次操作仍待确认，请等待结果后再操作。'};return}
    if($command.action -eq 'CancelAuto'){
        $record.manualStart=$false;$record.manualHold=$true
        if($record.phase -eq 'queued'){$record.phase='held'}
        Save-Journal;Write-Event 'manual-held';return
    }
    if($command.action -eq 'Pause'){
        $record.manualHold=$true;$record.manualStart=$false
        if($active -or $Snapshot.threadGoal.status -eq 'active'){$record.phase='observing';$record.forcePause=$true;Save-Journal}
        else {Set-Phase 'held';Write-Event 'manual-held'}
        return
    }
    $record.manualHold=$false;$record.manualStart=$command.action -eq 'Start'
    if($active -or $Snapshot.threadRuntimeStatus.type -eq 'active' -or $Snapshot.threadGoal.status -eq 'active'){
        $record.phase='observing';$record.manualStart=$false;Save-Journal;Write-Event 'manual-already-active';return
    }
    $latest=@(Get-Turns $Snapshot) | Select-Object -Last 1
    $record.pausedTurnId=$latest.turnId;$record.baselineMessageId=$Snapshot.latestTurnStartMessageId
    $record.resumeMessageId=$null;$record.recoverySeenAt=$null
    $record.pausedForGoal=$Snapshot.threadGoal.status -in @('paused','usageLimited')
    $record.pausedSource=$(if($Snapshot.threadGoal.status -eq 'usageLimited'){'quota'}else{'manual'})
    if($record.pausedForGoal){$g=$Snapshot.threadGoal;$record.pausedGoal=@{objective=$g.objective;createdAt=$g.createdAt;tokenBudget=$g.tokenBudget};$record.pausedGoalUpdatedAt=$g.updatedAt}
    Set-Phase 'queued';Write-Event $(if($record.manualStart){'manual-start'}else{'manual-registered'})
    if($record.manualStart){$record.recoverySeenAt=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-$RecoveryConfirmSeconds*1000;Save-Journal}
}
function Start-AllMonitor {
    $rootDirectory=$script:RunDirectory; $script:ThreadId='all'
    $version=Get-DesktopVersion
    Read-MonitorSettings
    $path=Join-Path $rootDirectory 'state.json'
    $fleet=$(if(Test-Path -LiteralPath $path){Read-Json $path}else{@{scope='all';mode=$Mode;phase='observing';accountId=$AccountId;threads=@{};lastControlId=$null}})
    if($fleet.scope -ne 'all' -or $fleet.mode -ne $Mode){throw 'Saved all-chat state mode mismatch.'}
    if($fleet.accountId){
        if($AccountId -and $AccountId -ne $fleet.accountId){throw 'Account identity mismatch.'}
        $script:AccountId=$fleet.accountId
    }
    foreach($record in $fleet.threads.Values){$record.recoverySeenAt=$null}
    $fleet.phase='observing';$fleet.monitorProcessId=$PID;$fleet.appVersion=$version
    $script:FleetJournal=$fleet;$script:FleetStatePath=$path
    $script:Journal=$fleet;Save-Journal;Write-Event 'all-started' @{appVersion=$version}
    $failures=0
    while($true) {
        $script:RunDirectory=$rootDirectory;$script:Journal=$fleet;$script:ThreadId='all';$script:OwnerId=$null
        $command=Read-Control
        if($command -in @('Stop','Cancel')) {
            if($command -eq 'Cancel'){foreach($record in $fleet.threads.Values){$record.phase='cancelled'}}
            Set-Phase $(if($command -eq 'Stop'){'stopped'}else{'cancelled'});break
        }
        try {
            Read-MonitorSettings
            Read-ThreadCommands $fleet $version
            Write-Event 'checking-quota'
            $live=Get-QuotaWithAutoReset;$fleet.accountId=$AccountId
            $quota=Get-EffectiveQuota $live
            $fleet.lastLiveQuota=$live;$fleet.lastQuota=$quota
            Write-Event 'discovering-chats' @{remaining=$quota.remaining;weeklyText=$(if($null -eq $quota.weeklyRemaining){'暂时无法取得'}else{"$($quota.weeklyRemaining)%"})}
            $catalog=Get-DesktopCatalog
            Write-Event 'checking-owners' @{count=$catalog.ids.Count}
            $owners=Get-DesktopOwners $catalog.ids
            Write-Event 'checking-task-state' @{count=$owners.Count}
            $snapshots=Get-DesktopSnapshots $owners
            $fleet.chats=@()
            foreach($chat in $catalog.chats){
                $snapshot=$snapshots[$chat.id];$record=$fleet.threads[$chat.id]
                $title=$(if($snapshot.title){[string]$snapshot.title}else{[string]$chat.title})
                $status=Get-ThreadRuntimeLabel $snapshot
                $fleet.chats+=@{id=$chat.id;title=($title -replace '[\r\n\t]',' ');runtime=$status;goalStatus=$snapshot.threadGoal.status;monitorPhase=$record.phase;waitReason=''}
            }
            $activeCount=0;$ordinaryActiveCount=0;$goalCount=0;$busyCount=0
            foreach($id in @($snapshots.Keys)) {
                $snapshot=$snapshots[$id];$active=Get-ActiveTurn $snapshot
                $activeGoal=$snapshot.threadGoal.status -eq 'active'
                $quotaInterrupted=Test-QuotaInterrupted $snapshot
                $record=$fleet.threads[$id]
                if(!$record -and !$active -and !$activeGoal -and !$quotaInterrupted){continue}
                if(!$record -or (!$record.pendingCommand -and (($active -or $activeGoal) -and $record.phase -in @('completed','cancelled','failed','held'))) -or (!$record.pendingCommand -and $quotaInterrupted -and $record.phase -eq 'completed') -or ($record.phase -eq 'needs_attention' -and $record.reason -eq 'active-Goal')) {
                    $record=New-ThreadJournal $id $version;$fleet.threads[$id]=$record
                }
                $record.displayTitle=([string]$snapshot.title -replace '[\r\n\t]',' ').Trim()
                if($record.displayTitle.Length -gt 80){$record.displayTitle=$record.displayTitle.Substring(0,80)+'…'}
                if(!$record.pendingCommand -and $record.phase -in @('completed','cancelled','stopped','needs_attention','failed','held')){continue}
                $mutex=[Threading.Mutex]::new($false,('Local\CodexQuotaMonitorV1-'+$id));$owned=$false;$fileLock=$null
                try {
                    try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
                    if(!$owned){$busyCount++;continue}
                    $script:ThreadId=$id;$script:OwnerId=$owners[$id];$script:Journal=$record
                    $script:RunDirectory=Join-Path $rootDirectory ('threads\'+$id)
                    [void][IO.Directory]::CreateDirectory($script:RunDirectory)
                    $fileLock=[IO.File]::Open((Join-Path $script:RunDirectory 'run.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
                    Apply-ThreadCommand $snapshot
                    if($record.phase -in @('paused','queued') -and $record.recoverySeenAt -and ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-[long]$record.recoverySeenAt -ge $RecoveryConfirmSeconds*1000)) {
                        $live=Get-LiveQuota;$quota=Get-EffectiveQuota $live
                        $snapshot=Get-Snapshot
                        $snapshots[$id]=$snapshot
                    }
                    $record.lastCheckedAt=[DateTimeOffset]::UtcNow.ToString('o');$record.lastQuota=$quota;$record.lastLiveQuota=$live
                    $decision=Update-ThreadState $snapshot $quota ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
                    $record.controlFailures=0
                    # Persist each action to the fleet index as well as the per-chat journal.
                    Write-JsonAtomic $path $fleet
                } catch {
                    $record.recoverySeenAt=$null
                    $record.controlFailures=1+[int]$record.controlFailures
                    Write-Event 'thread-control-error' @{error=$_.Exception.Message}
                    if(Test-FailureLimitReached $record.controlFailures){$record.phase='needs_attention';Save-Journal}
                    if(!$script:Pipe -or !$script:Pipe.IsConnected){throw}
                } finally {
                    if($fileLock){$fileLock.Dispose()};if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()
                }
            }
            $script:RunDirectory=$rootDirectory;$script:Journal=$fleet;$script:ThreadId='all';$script:OwnerId=$null
            # An archived/deleted chat must not be resumed from an old saved pause.
            foreach($id in @($fleet.threads.Keys)) {
                if($id -notin $catalog.ids -and ($fleet.threads[$id].phase -in @('paused','queued','pause_pending','resume_submitting') -or $fleet.threads[$id].pendingCommand)) {
                    $fleet.threads[$id].phase='cancelled';$fleet.threads[$id].pendingCommand=$null;Write-Event 'removed-chat' @{id=$id}
                }
            }
            foreach($chat in $fleet.chats){
                $record=$fleet.threads[$chat.id];$chat.monitorPhase=$record.phase
                $chat.runtime=Get-ThreadRuntimeLabel $snapshots[$chat.id];$chat.goalStatus=$snapshots[$chat.id].threadGoal.status
                if($record){$chat.waitReason=$(if($record.pendingCommand){'操作已登记，等待客户端加载该聊天'}else{Get-RecoveryWaitReason $record $snapshots[$chat.id] $quota})}
            }
            $fleet.lastCheckedAt=[DateTimeOffset]::UtcNow.ToString('o')
            $fleet.readFailureCount=0
            $fleet.lastQuota=$quota;$fleet.lastLiveQuota=$live
            $fleet.settings=Get-MonitorPolicy
            $activeCount=0;$ordinaryActiveCount=0;$goalCount=0
            foreach($current in $snapshots.Values){
                $isActive=[bool](Get-ActiveTurn $current)
                if($isActive){$activeCount++}
                if($current.threadGoal.status -eq 'active'){$goalCount++}elseif($isActive){$ordinaryActiveCount++}
            }
            $fleet.counts=@{catalog=$catalog.total;desktopCatalog=$catalog.ids.Count;loaded=$snapshots.Count;active=$activeCount;ordinaryActive=$ordinaryActiveCount;goals=$goalCount;goalSkipped=0;otherMonitor=$busyCount;paused=@($fleet.threads.Values|Where-Object phase -eq 'paused').Count;needsAttention=@($fleet.threads.Values|Where-Object phase -eq 'needs_attention').Count}
            $fleet.counts.autoResumePending=Get-AutoResumePendingCount $fleet.threads.Values
            $fleet.nextPollSeconds=Get-PollDelay $quota $fleet.threads.Values ($activeCount+$goalCount)
            Save-Journal;Write-Event 'all-monitor' @{remaining=$quota.remaining;weeklyRemaining=$quota.weeklyRemaining;allowed=$quota.allowed;spendControlReached=$quota.spendControlReached;counts=$fleet.counts}
            Close-Ipc;$failures=0
            if($Once){Write-Event 'single-check-finished';break}
            $delay=$fleet.nextPollSeconds
        } catch {
            $script:RunDirectory=$rootDirectory;$script:Journal=$fleet;$script:ThreadId='all';$script:OwnerId=$null
            $failures++;Write-Event 'all-read-error' @{error=$_.Exception.Message;failures=$failures}
            $fleet.readFailureCount=$failures;$fleet.lastReadErrorAt=[DateTimeOffset]::UtcNow.ToString('o');$fleet.nextPollSeconds=$PollSeconds
            Close-Ipc;Stop-QuotaServer
            foreach($record in $fleet.threads.Values){$record.recoverySeenAt=$null}
            Save-Journal
            if($_.Exception.Message -match 'identity mismatch|Unsupported|Invalid simulated|Real quota is insufficient|requires explicit' -or (Test-FailureLimitReached $failures)){Set-Phase 'needs_attention' @{reason=$_.Exception.Message};break}
            $delay=$PollSeconds
        }
        if(!(Wait-Poll $delay)){break}
    }
    $script:RunDirectory=$rootDirectory;$script:Journal=$fleet;$script:ThreadId='all'
}
function Wait-Poll([int]$Seconds) {
    $pausedRecords=@($(if($All -and $script:Journal.scope -eq 'all'){$script:Journal.threads.Values}else{$script:Journal})|Where-Object phase -eq 'paused')
    $earliestReset=($pausedRecords|Where-Object pauseResetsAt|Measure-Object -Property pauseResetsAt -Minimum).Minimum
    Write-Event 'waiting' @{seconds=$Seconds;paused=$pausedRecords.Count;resetsAt=$earliestReset}
    $until=[DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $until) {
        $command=Read-Control
        if ($command -eq 'Refresh') { return $true }
        if ($command -eq 'Stop') { Set-Phase 'stopped'; return $false }
        if ($command -eq 'Cancel') {
            if($All -and $script:Journal.scope -eq 'all'){foreach($record in $script:Journal.threads.Values){$record.phase='cancelled'}}
            Set-Phase 'cancelled'; return $false
        }
        if($All -and @((Get-ChildItem -LiteralPath (Join-Path $script:RunDirectory 'commands') -Filter '*.json' -ErrorAction SilentlyContinue)).Count){return $true}
        Start-Sleep -Milliseconds 250
    }
    return $true
}
function Update-ThreadState($snapshot, $quota, [long]$now) {
    Read-MonitorSettings
    $decision=Get-Decision $script:Journal $snapshot $quota $now
    if($script:Journal.forcePause){$decision='Pause';$script:Journal.forcePause=$false}
    Save-Journal
    if ($Mode -eq 'Monitor' -or $script:ObserveOnly) {
        Write-Event 'monitor' @{remaining=$quota.remaining;weeklyRemaining=$quota.weeklyRemaining;runtime=$snapshot.threadRuntimeStatus.type;wouldDo=$decision}
    } else {
        switch ($decision) {
            'QuotaInterrupted' {
                $turns=@(Get-Turns $snapshot);$latest=$turns[-1]
                $script:Journal.pausedTurnId=$latest.turnId;$script:Journal.baselineMessageId=$snapshot.latestTurnStartMessageId
                $script:Journal.pausedSource='quota';$script:Journal.pausedAt=[DateTimeOffset]::UtcNow.ToString('o');$script:Journal.recoverySeenAt=$null
                $script:Journal.pausedForGoal=$snapshot.threadGoal.status -eq 'usageLimited'
                if($script:Journal.pausedForGoal){$g=$snapshot.threadGoal;$script:Journal.pausedGoal=@{objective=$g.objective;createdAt=$g.createdAt;tokenBudget=$g.tokenBudget};$script:Journal.pausedGoalUpdatedAt=$g.updatedAt}
                $script:Journal.phase='paused';Save-Journal;Write-Event 'quota-interrupted' @{turnId=$latest.turnId}
            }
            'UserChanged' { Set-Phase 'cancelled' @{reason='user-or-another-client-started-new-work'} }
            'Pause' {
                $active=Get-ActiveTurn $snapshot
                $script:Journal.pausedSource='monitor'
                $script:Journal.pausedForGoal=$snapshot.threadGoal.status -eq 'active'
                if($script:Journal.pausedForGoal){$script:Journal.pausedGoal=@{objective=$snapshot.threadGoal.objective;createdAt=$snapshot.threadGoal.createdAt;tokenBudget=$snapshot.threadGoal.tokenBudget}}
                $script:Journal.pausedTurnId=$active.turnId
                $script:Journal.baselineMessageId=$snapshot.latestTurnStartMessageId
                $script:Journal.pauseResetsAt=$quota.resetsAt
                $script:Journal.pausedAt=[DateTimeOffset]::UtcNow.ToString('o')
                $script:Journal.recoverySeenAt=$null
                Set-Phase 'pause_pending' @{turnId=$active.turnId;remaining=$quota.remaining;simulated=$quota.simulated}
                $interruptParams=@{conversationId=$ThreadId;mode='system'}
                $interruptVersion=3
                if(!$script:Journal.pausedForGoal){$interruptParams.expectedTurnId=$active.turnId;$interruptVersion=4}
                $reply=Invoke-Ipc 'thread-follower-interrupt-turn' $interruptParams $interruptVersion 20 $script:OwnerId
                Write-Event 'interrupt-response' @{interruptedTurnId=$reply.result.interruptedTurnId;ok=$reply.result.ok}
                if (!$reply.result.interruptedTurnId -and !$script:Journal.pausedForGoal) { Set-Phase 'cancelled' @{reason='turn-changed-before-interrupt'} }
            }
            'PauseConfirmed' {
                if($script:Journal.pausedForGoal){$script:Journal.baselineMessageId=$snapshot.latestTurnStartMessageId;$script:Journal.pausedGoalUpdatedAt=$snapshot.threadGoal.updatedAt}
                Set-Phase 'paused' @{turnId=$script:Journal.pausedTurnId}
            }
            'FinishedDuringPause' { Set-Phase 'completed' @{reason='turn-finished-before-pause-confirmation'} }
            'RecoveryReady' {
                $recoveryNow=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                if (!$script:Journal.recoverySeenAt) { $script:Journal.recoverySeenAt=$recoveryNow; Save-Journal; Write-Event 'recovery-first-check' }
                elseif ($recoveryNow - [long]$script:Journal.recoverySeenAt -ge $RecoveryConfirmSeconds * 1000) {
                    $script:Journal.resumeMessageId=[guid]::NewGuid().ToString()
                    $script:Journal.resumeSubmittedAt=[DateTimeOffset]::UtcNow.ToString('o')
                    Set-Phase 'resume_submitting'
                    if($script:Journal.pausedForGoal){
                        $currentGoal=(Invoke-QuotaRpc 'thread/goal/get' @{threadId=$ThreadId}).goal
                        $expectedStatus=$(if($script:Journal.pausedSource -eq 'quota'){'usageLimited'}else{'paused'})
                        if(!(Test-SameGoal $currentGoal $script:Journal.pausedGoal) -or $currentGoal.status -ne $expectedStatus -or $currentGoal.updatedAt -ne $script:Journal.pausedGoalUpdatedAt){Set-Phase 'cancelled' @{reason='goal-state-changed'};return 'UserChanged'}
                        $goalReply=Invoke-QuotaRpc 'thread/goal/set' @{threadId=$ThreadId;status='active'}
                        if(!(Test-SameGoal $goalReply.goal $script:Journal.pausedGoal) -or $goalReply.goal.status -ne 'active'){throw 'goal-resume-not-confirmed'}
                    }
                    $continueText=$(if($script:Journal.pausedSource -eq 'manual'){'用户已主动请求继续此项目。请先检查当前进度，继续原任务中尚未完成的工作，已完成的步骤不要重复执行；若全部完成，请报告完成情况。'}else{'额度已恢复。请先检查当前进度和已完成的操作，从中断处继续原任务；已完成的步骤不要重复执行。'})
                    $request=@{threadId=$ThreadId;input=@(@{type='text';text=$continueText;text_elements=@()});clientUserMessageId=$script:Journal.resumeMessageId}
                    $reply=Invoke-Ipc 'thread-follower-start-turn' @{conversationId=$ThreadId;turnStart=@{request=$request;context=@{inheritThreadSettings=$true}}} 2 30 $script:OwnerId
                    Write-Event 'resume-response' @{ok=($reply.resultType -eq 'success')}
                }
            }
            'ResumeConfirmed' {
                $script:Journal.manualStart=$false
                if($script:Journal.pausedForGoal){
                    $currentGoal=(Invoke-QuotaRpc 'thread/goal/get' @{threadId=$ThreadId}).goal
                    if($currentGoal -and $currentGoal.status -notin @('active','complete')){Set-Phase 'needs_attention' @{reason='goal-resume-not-confirmed'};return 'Wait'}
                }
                $script:Journal.resumeTurnId=(Get-Turns $snapshot | Select-Object -Last 1).turnId
                Set-Phase 'resumed' @{turnId=$script:Journal.resumeTurnId}
            }
            'Completed' { Set-Phase 'completed' }
            'Failed' {Set-Phase 'failed' @{reason='non-quota-turn-failure'}}
            'Wait' {
                if ($script:Journal.phase -in @('paused','queued') -and $script:Journal.recoverySeenAt) { $script:Journal.recoverySeenAt=$null; Save-Journal }
                if ($script:Journal.phase -eq 'resume_submitting' -and $now - [DateTimeOffset]::Parse($script:Journal.resumeSubmittedAt).ToUnixTimeSeconds() -gt 60) { Set-Phase 'needs_attention' @{reason='resume-outcome-unknown-no-resend'} }
                if ($script:Journal.phase -eq 'pause_pending' -and $now - [DateTimeOffset]::Parse($script:Journal.pausedAt).ToUnixTimeSeconds() -gt 60) { Set-Phase 'needs_attention' @{reason='pause-not-confirmed'} }
            }
        }
    }
    return $decision
}
function Start-Monitor {
    $version=Get-DesktopVersion
    Read-MonitorSettings
    $statePath=Join-Path $script:RunDirectory 'state.json'
    $script:Journal=$(if (Test-Path -LiteralPath $statePath) {Read-Json $statePath} else {@{threadId=$ThreadId;accountId=$AccountId;mode=$Mode;appVersion=$version;phase='observing';lastControlId=$null;recoverySeenAt=$null;resumeMessageId=$null}})
    if ($script:Journal.threadId -ne $ThreadId -or $script:Journal.accountId -ne $AccountId -or $script:Journal.mode -ne $Mode) { throw 'Saved state identity/mode mismatch. Use a separate state directory.' }
    if ($script:Journal.phase -in @('cancelled','stopped','completed','needs_attention')) { throw 'This run has ended. Use a new state directory to register the thread again.' }
    $script:Journal.monitorProcessId=$PID
    # Recheck recovery twice after a process restart, even if a previous check was saved.
    $script:Journal.recoverySeenAt=$null
    Save-Journal
    Write-Event 'started' @{appVersion=$version}
    $failures=0
    while ($true) {
        $command=Read-Control
        if ($command -in @('Cancel','Stop')) { Set-Phase $(if($command -eq 'Cancel'){'cancelled'}else{'stopped'}); break }
        try {
            Read-MonitorSettings
            Write-Event 'checking-quota'
            $live=Get-QuotaWithAutoReset
            $quota=Get-EffectiveQuota $live
            Write-Event 'checking-task-state' @{count=1}
            $snapshot=Get-Snapshot
            $script:Journal.displayTitle=([string]$snapshot.title -replace '[\r\n\t]',' ').Trim()
            if($script:Journal.displayTitle.Length -gt 80){$script:Journal.displayTitle=$script:Journal.displayTitle.Substring(0,80)+'…'}
            $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $script:Journal.lastCheckedAt=[DateTimeOffset]::UtcNow.ToString('o')
            $script:Journal.lastQuota=$quota
            $script:Journal.lastLiveQuota=$live
            $decision=Update-ThreadState $snapshot $quota $now
            $failures=0
            if($Once){Write-Event 'single-check-finished';break}
            if ($script:Journal.phase -in @('completed','failed','cancelled','stopped','needs_attention')) { break }
            $delay=Get-PollDelay $quota @($script:Journal) ([int][bool]((Get-ActiveTurn $snapshot) -or $snapshot.threadGoal.status -eq 'active'))
        } catch {
            $failures++
            Write-Event 'connection-or-read-error' @{error=$_.Exception.Message;failures=$failures}
            Close-Ipc; Stop-QuotaServer
            $script:Journal.recoverySeenAt=$null; Save-Journal
            if ($_.Exception.Message -match 'identity mismatch|Unsupported|Invalid simulated|Real quota is insufficient' -or (Test-FailureLimitReached $failures)) { Set-Phase 'needs_attention' @{reason=$_.Exception.Message}; break }
            $delay=$PollSeconds
        }
        if (!(Wait-Poll $delay)) { break }
    }
}
if ($Library) { return }
try {
if($All -and $ThreadId){throw 'Use -All or -ThreadId, not both.'}
if($All){$ThreadId='all'}
elseif (!$ThreadId -or $ThreadId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Specify -All or a valid -ThreadId.' }
if (!$StateDirectory) { $StateDirectory=Join-Path (Join-Path $env:LOCALAPPDATA 'CodexQuotaMonitor') ('state-'+$ThreadId+'-'+$Mode) }
$script:RunDirectory=[IO.Path]::GetFullPath($StateDirectory)
if ($Action -eq 'Status') {
    $path=Join-Path $script:RunDirectory 'state.json'
    if (!(Test-Path -LiteralPath $path)) { throw 'No saved run state exists.' }
    $state=Read-Json $path
    if($Raw){$state|ConvertTo-Json -Depth 20}else{Show-SavedStatus $state $path}
    return
}
[void][IO.Directory]::CreateDirectory($script:RunDirectory)
if ($Action -in @('Cancel','Stop')) {
    Write-JsonAtomic (Join-Path $script:RunDirectory 'control.json') @{id=[guid]::NewGuid().ToString();action=$Action;time=[DateTimeOffset]::UtcNow.ToString('o')}
    Write-Host $(if($Action -eq 'Stop'){'已发送停止监控请求。请等原监控窗口退出后再重新启动；暂停记录会保留。'}else{'已发送解除登记请求；监控器处理后，不会再自动恢复这些旧任务。'})
    return
}
if (!$AccountId -and !$All) { throw 'Specify the expected ChatGPT -AccountId.' }
if ($PollSeconds -lt 1 -or $NearLimitPollSeconds -lt 1 -or $RecoveryConfirmSeconds -lt 1) { throw 'Polling intervals must be positive.' }
if ($Mode -eq 'Test' -and (!$TestQuotaFile -or !(Test-Path -LiteralPath $TestQuotaFile))) { throw 'Test mode requires -TestQuotaFile.' }
if ($Mode -ne 'Test' -and $TestQuotaFile) { throw '-TestQuotaFile is only accepted in Test mode.' }
$lock=$null; $threadMutex=$null; $ownsThreadMutex=$false;$fleetMutex=$null;$ownsFleetMutex=$false
try {
    $readonlySuffix=$(if($Mode -eq 'Monitor'){'-Readonly-'+[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($script:RunDirectory))).Substring(0,16)}else{''})
    $fleetMutex=[Threading.Mutex]::new($false,('Local\CodexQuotaMonitorAll'+$readonlySuffix))
    try{$ownsFleetMutex=$fleetMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$ownsFleetMutex=$true}
    if(!$ownsFleetMutex){throw 'An all-chat monitor is already running.'}
    if(!$All){$fleetMutex.ReleaseMutex();$ownsFleetMutex=$false}
    $threadMutex=[Threading.Mutex]::new($false, ('Local\CodexQuotaMonitorV1-'+$ThreadId+$readonlySuffix))
    try { $ownsThreadMutex=$threadMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsThreadMutex=$true }
    if (!$ownsThreadMutex) { throw 'Another monitor already controls this thread.' }
    $lock=[IO.File]::Open((Join-Path $script:RunDirectory 'run.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    if($All) {
        if($Action -eq 'Probe'){throw 'Use -All -Mode Monitor -Once for a read-only discovery check.'}
        Start-AllMonitor
    } elseif ($Action -eq 'Probe') {
        $quota=Get-LiveQuota
        $snapshot=Get-Snapshot
        $active=Get-ActiveTurn $snapshot
        $reply=Invoke-Ipc 'thread-follower-interrupt-turn' @{conversationId=$ThreadId;mode='system';expectedTurnId=('quota-readonly-no-such-turn-'+[guid]::NewGuid())} 4 20 $script:OwnerId
        $after=Get-Snapshot
        [ordered]@{desktopVersion=(Get-DesktopVersion);accountId=$quota.accountId;quota=$quota;threadId=$ThreadId;runtime=$after.threadRuntimeStatus;activeTurnId=$active.turnId;noopInterrupt=$reply.result;sameActiveTurn=((Get-ActiveTurn $after).turnId -eq $active.turnId)} | ConvertTo-Json -Depth 10
    } else { Start-Monitor }
} finally {
    Close-Ipc; Stop-QuotaServer
    if($lock){$lock.Dispose()}
    if($ownsThreadMutex){$threadMutex.ReleaseMutex()}
    if($threadMutex){$threadMutex.Dispose()}
    if($ownsFleetMutex){$fleetMutex.ReleaseMutex()}
    if($fleetMutex){$fleetMutex.Dispose()}
}
} catch {
    $reason=$_.Exception.Message
    if($script:RunDirectory -and (Test-Path -LiteralPath $script:RunDirectory)){
        Write-Event 'fatal-error' @{error=$reason}
    }else{
        Write-Host ('无法启动监控。{0}' -f (Get-ChineseReason $reason))
    }
    exit 1
}
