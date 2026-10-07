using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

public class MonitorSettings {
    public int pollSeconds = 30;
    public double pauseRemainingPercent = 5;
    public bool observeOnly = false;
    public bool resumeAll = true;
    public string[] resumeThreadIds = new string[0];
    public string[] resumeExcludedThreadIds = new string[0];
    public bool autoResetEnabled = false;
    public double resetWeeklyRemainingPercent = 1;
    public double nearLimitRemainingPercent = 10;
    public int nearLimitPollSeconds = 10;
    public int maxConsecutiveFailures = 0;
    public bool showAllProjects = false;
    public string stateDirectory;
}

static class Program {
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [STAThread] static void Main(string[] args) {
        SetProcessDPIAware();
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        bool first;
        using (var singleton = new Mutex(true, "Local\\CodexQuotaMonitorDesktop"+(args.Contains("--smoke-test") ? "-ReadonlyCheck" : ""), out first)) {
            if (!first) { MessageBox.Show("额度监控器已经打开，请从右下角托盘打开窗口。", "额度监控器"); return; }
            try { Application.Run(new MonitorWindow(args)); }
            catch (Exception e) { MessageBox.Show("无法打开额度监控器：" + e.Message, "额度监控器"); }
        }
    }
}

class QuotaMeter : Control {
    public int Value;
    public Color Accent=Color.FromArgb(30,133,125);
    public QuotaMeter(){DoubleBuffered=true;}
    protected override void OnPaint(PaintEventArgs e){
        base.OnPaint(e); e.Graphics.Clear(Color.White);
        using(var background=new SolidBrush(Color.FromArgb(231,238,245))) e.Graphics.FillRectangle(background,0,2,Width,6);
        using(var fill=new SolidBrush(Accent)) e.Graphics.FillRectangle(fill,0,2,Width*Math.Max(0,Math.Min(100,Value))/100,6);
    }
}
class QuotaCard : Panel {
    public Label Value = new Label(), Detail = new Label(), Reset = new Label(), Countdown = new Label();
    public QuotaMeter Bar = new QuotaMeter();
    public long? ResetTimestamp;
    public QuotaCard(string title) {
        Dock = DockStyle.Fill; BackColor = Color.White; Padding = new Padding(18, 12, 18, 10); Margin = new Padding(0,0,12,0);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 6 };
        int[] heights = { 23, 48, 24, 15, 27, 22 };
        foreach (int h in heights) layout.RowStyles.Add(new RowStyle(SizeType.Absolute, h));
        var heading = new Label { Text = title, Dock = DockStyle.Fill, ForeColor = Color.FromArgb(77,94,112) };
        Value.Text = "正在查询…"; Value.Font = new Font("Microsoft YaHei UI", 32, FontStyle.Bold, GraphicsUnit.Pixel); Value.Dock = DockStyle.Fill;
        Detail.Text = "等待账号额度"; Detail.Dock = DockStyle.Fill;
        Bar.Dock = DockStyle.Fill; Bar.Margin = new Padding(0,2,0,3);
        Reset.Text = "重置时间：尚未取得"; Reset.Dock = DockStyle.Fill; Reset.TextAlign = ContentAlignment.MiddleLeft;
        Countdown.Text = ""; Countdown.Dock = DockStyle.Fill; Countdown.ForeColor = Color.FromArgb(77,94,112);
        layout.Controls.Add(heading,0,0); layout.Controls.Add(Value,0,1); layout.Controls.Add(Detail,0,2);
        layout.Controls.Add(Bar,0,3); layout.Controls.Add(Reset,0,4); layout.Controls.Add(Countdown,0,5);
        Controls.Add(layout);
    }
    protected override void OnPaint(PaintEventArgs e){base.OnPaint(e);using(var p=new Pen(Color.FromArgb(225,232,241)))e.Graphics.DrawRectangle(p,0,0,Width-1,Height-1);}
    public void UpdateQuota(object remaining, object reset) {
        if (remaining == null) { Value.Text="未提供"; Detail.Text="客户端未返回此额度"; Bar.Value=0; }
        else {
            double left=Math.Max(0,Math.Min(100,Convert.ToDouble(remaining)));
            Value.Text="剩余 " + left.ToString("0.#") + "%";
            Detail.Text="已用 " + (100-left).ToString("0.#") + "%";
            Value.ForeColor=left<=5 ? Color.FromArgb(185,61,41) : Color.FromArgb(16,114,107);
            Bar.Value=(int)Math.Round(left); Bar.Accent=Value.ForeColor; Bar.Invalidate();
        }
        ResetTimestamp=reset==null ? (long?)null : Convert.ToInt64(reset);
        Reset.Text=ResetTimestamp.HasValue ? "重置："+FromUnix(ResetTimestamp.Value).ToString("MM-dd HH:mm:ss") : "重置时间：客户端未提供";
        Tick();
    }
    public static DateTime FromUnix(long seconds) { return new DateTime(1970,1,1,0,0,0,DateTimeKind.Utc).AddSeconds(seconds).ToLocalTime(); }
    public void Tick() {
        if (!ResetTimestamp.HasValue) { Countdown.Text=""; return; }
        var wait=FromUnix(ResetTimestamp.Value)-DateTime.Now;
        Countdown.Text=wait.TotalSeconds<=0 ? "重置时间已到，等待下次查询确认" : "距重置 "+(wait.Days>0 ? wait.Days+" 天 " : "")+wait.ToString(@"hh\:mm\:ss");
    }
}

class MonitorWindow : Form {
    readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 16*1024*1024, RecursionLimit = 150 };
    readonly string stateDir, settingsPath, backendPath, checkDir, logDir;
    readonly bool smokeTest;
    readonly QuotaCard five=new QuotaCard("五小时额度"), week=new QuotaCard("周额度");
    readonly Label mode=new Label(), freshness=new Label(), counts=new Label(), cardInfo=new Label(), resetStatus=new Label(), listTitle=new Label();
    readonly NumericUpDown poll=new NumericUpDown(), threshold=new NumericUpDown(), resetThreshold=new NumericUpDown(), nearThreshold=new NumericUpDown(), nearPoll=new NumericUpDown();
    readonly CheckBox observe=new CheckBox(), resumeAll=new CheckBox(), autoReset=new CheckBox();
    readonly CheckBox stopOnFailures=new CheckBox();
    readonly CheckBox showAll=new CheckBox();
    readonly ContextMenuStrip projectMenu=new ContextMenuStrip();
    readonly NumericUpDown failureLimit=new NumericUpDown();
    readonly DataGridView chats=new DataGridView();
    readonly TextBox log=new TextBox();
    readonly Button start=new Button(), apply=new Button(), refresh=new Button();
    readonly NotifyIcon tray=new NotifyIcon();
    readonly System.Windows.Forms.Timer timer=new System.Windows.Forms.Timer();
    MonitorSettings config;
    readonly MonitorSettings initialConfig;
    Process worker;
    LogWindow viewer;
    Dictionary<string,object> lastState;
    string lastChecked="", lastRendered="";
    DateTime startedAt=DateTime.Now;
    bool loading=true, stopRequested=false, exiting=false, allowClose=false, checkConfigured=false, checkFinished=false, choicesPassed=false, quotaDisplayPassed=false;

    public MonitorWindow(string[] args) {
        smokeTest=args.Contains("--smoke-test");
        checkDir=Argument(args,"--check-directory");
        string appData=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"CodexQuotaMonitor");
        string legacy=Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"..","..","work","quota-monitor-v1","all-Auto"));
        settingsPath=Argument(args,"--settings") ?? Path.Combine(appData,"settings.json");
        config=File.Exists(settingsPath) ? json.Deserialize<MonitorSettings>(ReadShared(settingsPath)) : new MonitorSettings();
        stateDir=Argument(args,"--state-directory") ?? config.stateDirectory ?? (Directory.Exists(legacy) ? legacy : Path.Combine(appData,"state"));
        logDir=Argument(args,"--log-directory") ?? stateDir;
        config.stateDirectory=stateDir;
        Directory.CreateDirectory(stateDir); Directory.CreateDirectory(Path.GetDirectoryName(settingsPath)); Directory.CreateDirectory(appData);
        backendPath=Path.Combine(appData,smokeTest ? "backend-check.ps1" : "backend.ps1");
        using (var resource=Assembly.GetExecutingAssembly().GetManifestResourceStream("quota-monitor.ps1"))
        using (var destination=File.Create(backendPath)) { resource.CopyTo(destination); }
        if(config.resumeThreadIds==null) config.resumeThreadIds=new string[0];
        if(config.resumeExcludedThreadIds==null) config.resumeExcludedThreadIds=new string[0];
        if (smokeTest) config.observeOnly=true;
        initialConfig=json.Deserialize<MonitorSettings>(json.Serialize(config));
        Text="Codex 额度监控 · v1.2.0"; Icon=Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        ClientSize=new Size(1120,970); MinimumSize=new Size(984,924); StartPosition=FormStartPosition.CenterScreen;
        Font=new Font("Microsoft YaHei UI",9); ForeColor=Color.FromArgb(38,53,73); BackColor=Color.FromArgb(242,246,251); AutoScaleMode=AutoScaleMode.Dpi;
        BuildWindow();
        poll.Value=Math.Max(1,Math.Min(3600,config.pollSeconds)); threshold.Value=(decimal)Math.Max(0,Math.Min(99,config.pauseRemainingPercent));
        observe.Checked=config.observeOnly; resumeAll.Checked=config.resumeAll;
        autoReset.Checked=config.autoResetEnabled; resetThreshold.Value=(decimal)Math.Max(0,Math.Min(99,config.resetWeeklyRemainingPercent));
        nearThreshold.Value=(decimal)Math.Max(0,Math.Min(100,config.nearLimitRemainingPercent));nearPoll.Value=Math.Max(1,Math.Min(3600,config.nearLimitPollSeconds));
        stopOnFailures.Checked=config.maxConsecutiveFailures>0;failureLimit.Value=Math.Max(1,Math.Min(9999,config.maxConsecutiveFailures>0 ? config.maxConsecutiveFailures : 5));failureLimit.Enabled=stopOnFailures.Checked;
        showAll.Checked=config.showAllProjects;
        loading=false;
        WriteSettings();
        var trayMenu=new ContextMenuStrip();
        trayMenu.Items.Add("打开窗口",null,delegate { RestoreWindow(); });
        trayMenu.Items.Add("停止监控",null,delegate { StopWorker(); });
        trayMenu.Items.Add("退出",null,delegate { RequestExit(); });
        tray.Icon=Icon; tray.Text="Codex 额度监控"; tray.ContextMenuStrip=trayMenu; tray.Visible=true;
        tray.DoubleClick+=delegate { RestoreWindow(); };
        Resize+=delegate { if(WindowState==FormWindowState.Minimized && !smokeTest) Hide(); };
        FormClosing+=delegate(object sender,FormClosingEventArgs e) {
            if(allowClose) return;
            e.Cancel=true;
            if(e.CloseReason==CloseReason.WindowsShutDown) RequestExit();
            else { Hide(); tray.ShowBalloonTip(2500,"额度监控器仍在运行","从托盘打开窗口；彻底停止请点“退出”。",ToolTipIcon.Info); }
        };
        Shown+=delegate { StartWorker(); };
        timer.Interval=1000; timer.Tick+=delegate { UpdateScreen(); }; timer.Start();
        FormClosed+=delegate { timer.Dispose(); tray.Visible=false; tray.Dispose(); if(worker!=null) worker.Dispose(); };
    }
    static string Argument(string[] args,string key) { int i=Array.IndexOf(args,key); return i>=0 && i+1<args.Length ? args[i+1] : null; }
    static Dictionary<string,object> Obj(object value) { return value as Dictionary<string,object> ?? new Dictionary<string,object>(); }
    static object Get(Dictionary<string,object> value,string key) { object result; return value.TryGetValue(key,out result) ? result : null; }
    static string Str(object value) { return value==null ? "" : Convert.ToString(value); }
    static IEnumerable<object> Items(object value) { return value as IEnumerable<object> ?? new object[0]; }
    static string ReadShared(string path) {
        using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
        using(var reader=new StreamReader(stream,Encoding.UTF8)) return reader.ReadToEnd();
    }
    void AtomicJson(string path,object value) {
        string temp=path+".gui.tmp"; File.WriteAllText(temp,json.Serialize(value),new UTF8Encoding(false));
        for(int attempt=0;;attempt++) {
            try { if(File.Exists(path)) File.Replace(temp,path,null); else File.Move(temp,path); break; }
            catch(IOException) { if(attempt==3) throw; Thread.Sleep(30); }
        }
    }
    Button MakeButton(string text,EventHandler action) {
        var button=new Button {Text=text,AutoSize=false,Size=new Size(TextRenderer.MeasureText(text,Font).Width+20,36),FlatStyle=FlatStyle.Flat,BackColor=Color.White,Margin=new Padding(0,3,9,0)};
        button.FlatAppearance.BorderColor=Color.FromArgb(195,207,215); button.Click+=action; return button;
    }
    Label Inline(string text) { return new Label {Text=text,AutoSize=true,Margin=new Padding(0,9,8,0)}; }
    void BuildWindow() {
        var root=new TableLayoutPanel {Dock=DockStyle.Fill,Padding=new Padding(24,16,24,12),ColumnCount=1,RowCount=10};
        foreach(int h in new int[]{66,192,184,94,46,35}) root.RowStyles.Add(new RowStyle(SizeType.Absolute,h));
        root.RowStyles.Add(new RowStyle(SizeType.Percent,100)); root.RowStyles.Add(new RowStyle(SizeType.Absolute,28));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute,80)); root.RowStyles.Add(new RowStyle(SizeType.Absolute,46));
        var heading=new TableLayoutPanel {Dock=DockStyle.Fill,ColumnCount=2};
        heading.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,50)); heading.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,50));
        var title=new Label {Text="Codex 额度监控",Font=new Font("Microsoft YaHei UI",28,FontStyle.Bold,GraphicsUnit.Pixel),Dock=DockStyle.Fill,TextAlign=ContentAlignment.MiddleLeft};
        mode.Dock=DockStyle.Fill; mode.TextAlign=ContentAlignment.MiddleRight; mode.ForeColor=Color.FromArgb(16,114,107); mode.Text="正在连接客户端…";
        heading.Controls.Add(title,0,0); heading.Controls.Add(mode,1,0); root.Controls.Add(heading,0,0);
        var cards=new TableLayoutPanel {Dock=DockStyle.Fill,ColumnCount=2,Margin=new Padding(0,0,0,10)};
        cards.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,50)); cards.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,50)); week.Margin=new Padding(0);
        cards.Controls.Add(five,0,0); cards.Controls.Add(week,1,0); root.Controls.Add(cards,0,1);
        var settings=new TableLayoutPanel {Dock=DockStyle.Fill,BackColor=Color.White,Padding=new Padding(12,3,10,3),ColumnCount=1,RowCount=4,Margin=new Padding(0,0,0,8)};
        settings.RowStyles.Add(new RowStyle(SizeType.Absolute,44));settings.RowStyles.Add(new RowStyle(SizeType.Absolute,42));settings.RowStyles.Add(new RowStyle(SizeType.Absolute,44));
        settings.RowStyles.Add(new RowStyle(SizeType.Absolute,38));
        var first=new FlowLayoutPanel {Dock=DockStyle.Fill,WrapContents=false,Margin=new Padding(0)};
        poll.Minimum=1; poll.Maximum=3600; poll.Width=75; poll.Margin=new Padding(0,6,10,0);
        threshold.Minimum=0; threshold.Maximum=99; threshold.DecimalPlaces=1; threshold.Width=75; threshold.Margin=new Padding(0,6,0,0);
        first.Controls.Add(Inline("查询间隔")); first.Controls.Add(poll); first.Controls.Add(Inline("秒    五小时剩余 ≤")); first.Controls.Add(threshold); first.Controls.Add(Inline("% 时暂停"));
        apply.Text="保存并应用"; apply.AutoSize=false;apply.Size=new Size(140,36);apply.Margin=new Padding(18,3,5,0);apply.Click+=delegate { SaveAndApply(); };
        observe.Text="只读观察"; observe.AutoSize=true; observe.Margin=new Padding(15,9,0,0); observe.CheckedChanged+=delegate { if(!loading) SaveAndApply(); };
        first.Controls.Add(apply);
        var second=new FlowLayoutPanel {Dock=DockStyle.Fill,WrapContents=false,Margin=new Padding(0)};
        resumeAll.Text="新聊天默认允许继续"; resumeAll.AutoSize=true; resumeAll.Margin=new Padding(0,7,15,0);
        resumeAll.CheckedChanged+=delegate { if(!loading){
            // Keep explicit choices for known chats when changing the default for new chats.
            var ids=new HashSet<string>(config.resumeThreadIds);var excluded=new HashSet<string>(config.resumeExcludedThreadIds);
            foreach(var chat in Items(Get(lastState ?? new Dictionary<string,object>(),"chats")).Select(Obj)){
                string id=Str(Get(chat,"id"));bool selected=config.resumeAll ? !excluded.Contains(id) : ids.Contains(id);
                if(selected){ids.Add(id);excluded.Remove(id);}else{ids.Remove(id);excluded.Add(id);}
            }
            config.resumeThreadIds=ids.ToArray();config.resumeExcludedThreadIds=excluded.ToArray();SaveAndApply();RenderChats(true);
        } };
        observe.Margin=new Padding(0,7,20,0);
        second.Controls.Add(observe); second.Controls.Add(resumeAll); second.Controls.Add(Inline("逐行勾选；右键可登记空闲或已结束项目继续。"));
        var near=new FlowLayoutPanel {Dock=DockStyle.Fill,WrapContents=false,Margin=new Padding(0)};
        nearThreshold.Minimum=0;nearThreshold.Maximum=100;nearThreshold.DecimalPlaces=1;nearThreshold.Width=64;nearThreshold.Margin=new Padding(0,6,3,0);
        nearPoll.Minimum=1;nearPoll.Maximum=3600;nearPoll.Width=64;nearPoll.Margin=new Padding(0,6,3,0);
        near.Controls.Add(Inline("五小时剩余 ≤"));near.Controls.Add(nearThreshold);near.Controls.Add(Inline("% 时，每"));near.Controls.Add(nearPoll);near.Controls.Add(Inline("秒查询（暂停确认后恢复常规间隔）"));
        var failures=new FlowLayoutPanel {Dock=DockStyle.Fill,WrapContents=false,Margin=new Padding(0)};
        stopOnFailures.Text="连续失败后自动停止监控";stopOnFailures.AutoSize=true;stopOnFailures.Margin=new Padding(0,9,12,0);
        failureLimit.Minimum=1;failureLimit.Maximum=9999;failureLimit.Width=72;failureLimit.Margin=new Padding(0,6,3,0);
        stopOnFailures.CheckedChanged+=delegate {failureLimit.Enabled=stopOnFailures.Checked;if(!loading) SaveAndApply();};
        failures.Controls.Add(stopOnFailures);failures.Controls.Add(Inline("连续失败"));failures.Controls.Add(failureLimit);failures.Controls.Add(Inline("次时停止；不勾选则持续重试（默认）"));
        settings.Controls.Add(first,0,0);settings.Controls.Add(near,0,1);settings.Controls.Add(second,0,2);root.Controls.Add(settings,0,2);
        settings.Controls.Add(failures,0,3);
        var resets=new TableLayoutPanel {Dock=DockStyle.Fill,BackColor=Color.White,Padding=new Padding(12,3,10,3),RowCount=2,ColumnCount=1,Margin=new Padding(0,0,0,10)};
        resets.RowStyles.Add(new RowStyle(SizeType.Absolute,39));resets.RowStyles.Add(new RowStyle(SizeType.Absolute,32));
        var resetFirst=new FlowLayoutPanel {Dock=DockStyle.Fill,WrapContents=false};
        autoReset.Text="自动使用重置卡";autoReset.AutoSize=true;autoReset.Margin=new Padding(0,9,14,0);
        autoReset.CheckedChanged+=delegate {if(!loading) SaveAndApply();};
        resetThreshold.Minimum=0;resetThreshold.Maximum=99;resetThreshold.DecimalPlaces=1;resetThreshold.Width=64;resetThreshold.Margin=new Padding(0,6,3,0);
        resetFirst.Controls.Add(autoReset);resetFirst.Controls.Add(Inline("周剩余 ≤"));resetFirst.Controls.Add(resetThreshold);resetFirst.Controls.Add(Inline("% 触发"));
        cardInfo.AutoSize=true;cardInfo.Margin=new Padding(15,9,0,0);cardInfo.ForeColor=Color.FromArgb(30,113,158);cardInfo.Text="可用卡：查询中";resetFirst.Controls.Add(cardInfo);
        resetStatus.Dock=DockStyle.Fill;resetStatus.TextAlign=ContentAlignment.MiddleLeft;resetStatus.ForeColor=Color.FromArgb(97,112,131);resetStatus.Text="自动使用默认关闭；需服务器允许重置。";
        resets.Controls.Add(resetFirst,0,0);resets.Controls.Add(resetStatus,0,1);root.Controls.Add(resets,0,3);
        var toolbar=new FlowLayoutPanel {Dock=DockStyle.Fill,WrapContents=false,Margin=new Padding(0)};
        start.Text="停止监控";start.AutoSize=false;start.Size=new Size(120,36); start.Margin=new Padding(0,3,9,0); start.Click+=delegate { if(WorkerRunning()) StopWorker(); else StartWorker(); };
        refresh.Text="立即查询";refresh.AutoSize=false;refresh.Size=new Size(120,36); refresh.Margin=new Padding(0,3,9,0); refresh.Click+=delegate { if(WorkerRunning()) Signal("Refresh"); else AppendLog("请先启动监控，再立即查询。"); };
        toolbar.Controls.Add(start); toolbar.Controls.Add(refresh);
        toolbar.Controls.Add(MakeButton("全选列表",delegate { SelectChats(true); }));
        toolbar.Controls.Add(MakeButton("清空列表",delegate { SelectChats(false); }));
        toolbar.Controls.Add(MakeButton("查看日志",delegate { OpenLogs(); }));
        showAll.Text="显示所有项目";showAll.AutoSize=true;showAll.Margin=new Padding(4,9,8,0);
        showAll.CheckedChanged+=delegate {if(!loading){WriteSettings();RenderChats(true);}};toolbar.Controls.Add(showAll);
        listTitle.AutoSize=true;listTitle.Margin=new Padding(4,10,0,0);toolbar.Controls.Add(listTitle);root.Controls.Add(toolbar,0,4);
        counts.Dock=DockStyle.Fill;counts.TextAlign=ContentAlignment.MiddleLeft;counts.Font=new Font(Font,FontStyle.Bold);root.Controls.Add(counts,0,5);
        chats.Dock=DockStyle.Fill; chats.BackgroundColor=Color.White; chats.BorderStyle=BorderStyle.None; chats.AllowUserToAddRows=false; chats.AllowUserToDeleteRows=false;
        chats.RowHeadersVisible=false; chats.AutoSizeRowsMode=DataGridViewAutoSizeRowsMode.None; chats.RowTemplate.Height=34;
        chats.SelectionMode=DataGridViewSelectionMode.FullRowSelect; chats.MultiSelect=false; chats.EnableHeadersVisualStyles=false;
        chats.ColumnHeadersDefaultCellStyle.BackColor=Color.FromArgb(232,239,248); chats.ColumnHeadersDefaultCellStyle.ForeColor=Color.FromArgb(72,91,117);chats.ColumnHeadersHeight=38;
        chats.DefaultCellStyle.SelectionBackColor=Color.FromArgb(224,243,240); chats.DefaultCellStyle.SelectionForeColor=Color.Black;
        chats.GridColor=Color.FromArgb(231,236,241); chats.AlternatingRowsDefaultCellStyle.BackColor=Color.FromArgb(247,249,250);
        chats.Columns.Add(new DataGridViewCheckBoxColumn {Name="resume",HeaderText="自动继续",Width=105,SortMode=DataGridViewColumnSortMode.NotSortable});
        chats.Columns.Add(new DataGridViewTextBoxColumn {Name="title",HeaderText="聊天标题",ReadOnly=true,AutoSizeMode=DataGridViewAutoSizeColumnMode.Fill,MinimumWidth=190});
        chats.Columns.Add(new DataGridViewTextBoxColumn {Name="runtime",HeaderText="执行状态",ReadOnly=true,Width=125});
        chats.Columns.Add(new DataGridViewTextBoxColumn {Name="phase",HeaderText="监控状态 / 等待原因",ReadOnly=true,Width=235});
        chats.CurrentCellDirtyStateChanged+=delegate { if(chats.IsCurrentCellDirty) chats.CommitEdit(DataGridViewDataErrorContexts.Commit); };
        chats.CellValueChanged+=delegate(object sender,DataGridViewCellEventArgs e) {
            if(loading || e.RowIndex<0 || e.ColumnIndex!=0) return;
            var row=chats.Rows[e.RowIndex];string id=Str(row.Tag);if(id.Length==0)return;
            var ids=new HashSet<string>(config.resumeThreadIds);var excluded=new HashSet<string>(config.resumeExcludedThreadIds);
            if(Convert.ToBoolean(row.Cells[0].Value)){ids.Add(id);excluded.Remove(id);}else{ids.Remove(id);excluded.Add(id);}
            config.resumeThreadIds=ids.ToArray();config.resumeExcludedThreadIds=excluded.ToArray();SaveAndApply();
        };
        projectMenu.Items.Add("手动暂停（保持暂停）",null,delegate {ProjectAction("Pause");});
        projectMenu.Items.Add("手动开始 / 继续",null,delegate {ProjectAction("Start");});
        projectMenu.Items.Add("登记自动继续（空闲 / 已结束也可）",null,delegate {ProjectAction("AutoContinue");});
        projectMenu.Items.Add("取消自动继续",null,delegate {ProjectAction("CancelAuto");});
        projectMenu.Opening+=delegate(object sender,System.ComponentModel.CancelEventArgs e){e.Cancel=chats.CurrentRow==null;foreach(ToolStripItem item in projectMenu.Items)item.Enabled=!observe.Checked && !stopRequested;};
        chats.ContextMenuStrip=projectMenu;
        chats.CellMouseDown+=delegate(object sender,DataGridViewCellMouseEventArgs e){if(e.Button==MouseButtons.Right && e.RowIndex>=0){chats.ClearSelection();chats.CurrentCell=chats.Rows[e.RowIndex].Cells[1];chats.Rows[e.RowIndex].Selected=true;}};
        root.Controls.Add(chats,0,6);
        freshness.Dock=DockStyle.Fill; freshness.TextAlign=ContentAlignment.MiddleLeft; freshness.ForeColor=Color.FromArgb(77,94,112); root.Controls.Add(freshness,0,7);
        log.Dock=DockStyle.Fill; log.Multiline=true; log.ReadOnly=true; log.ScrollBars=ScrollBars.Vertical; log.BorderStyle=BorderStyle.None; log.BackColor=Color.White; log.Font=new Font("Microsoft YaHei UI",8.5f);
        root.Controls.Add(log,0,8);
        var footer=new FlowLayoutPanel {Dock=DockStyle.Fill,WrapContents=false,Margin=new Padding(0)};
        footer.Controls.Add(Inline("关闭窗口后驻留托盘；“停止监控”不停止聊天。"));
        footer.Controls.Add(MakeButton("退出程序",delegate { RequestExit(); })); root.Controls.Add(footer,0,9); Controls.Add(root);
        foreach(var b in new[]{start,refresh,apply}){b.FlatStyle=FlatStyle.Flat;b.BackColor=Color.White;b.Padding=new Padding(5,1,5,1);b.FlatAppearance.BorderColor=Color.FromArgb(195,207,215);}
        apply.BackColor=Color.FromArgb(31,114,184);apply.ForeColor=Color.White;apply.FlatAppearance.BorderSize=0;
    }
    void WriteSettings() {
        config.pollSeconds=(int)poll.Value; config.pauseRemainingPercent=(double)threshold.Value;
        config.observeOnly=observe.Checked; config.resumeAll=resumeAll.Checked;
        config.autoResetEnabled=autoReset.Checked;config.resetWeeklyRemainingPercent=(double)resetThreshold.Value;
        config.nearLimitRemainingPercent=(double)nearThreshold.Value;config.nearLimitPollSeconds=(int)nearPoll.Value;
        config.maxConsecutiveFailures=stopOnFailures.Checked ? (int)failureLimit.Value : 0;
        config.showAllProjects=showAll.Checked;
        AtomicJson(settingsPath,config);
    }
    void SaveAndApply() {
        try { WriteSettings(); Signal("Refresh"); AppendLog("设置已保存，将在下次查询时应用。"); }
        catch(Exception e) { AppendLog("设置保存失败："+e.Message); }
    }
    void SelectChats(bool selected) {
        loading=true;
        var ids=new HashSet<string>(config.resumeThreadIds);var excluded=new HashSet<string>(config.resumeExcludedThreadIds);
        foreach(DataGridViewRow row in chats.Rows){row.Cells[0].Value=selected;string id=Str(row.Tag);if(selected){ids.Add(id);excluded.Remove(id);}else{ids.Remove(id);excluded.Add(id);}}
        config.resumeThreadIds=ids.ToArray();config.resumeExcludedThreadIds=excluded.ToArray();loading=false;SaveAndApply();
    }
    string FindRuntime() {
        string bundled=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),".cache","codex-runtimes","codex-primary-runtime","dependencies","native","powershell","pwsh.exe");
        if(File.Exists(bundled)) return bundled;
        foreach(string folder in (Environment.GetEnvironmentVariable("PATH")??"").Split(';')) { try { string path=Path.Combine(folder,"pwsh.exe"); if(File.Exists(path)) return path; } catch(ArgumentException){} }
        throw new Exception("没有找到 PowerShell 7，请保留 Codex 自带的运行环境。");
    }
    static string Quote(string value) { if(value.Contains("\"")) throw new ArgumentException("路径含不支持的引号"); return "\""+value+"\""; }
    bool WorkerRunning() { return worker!=null && !worker.HasExited; }
    void StartWorker() {
        if(WorkerRunning() || exiting) return;
        try {
            WriteSettings(); stopRequested=false;
            if(worker!=null) worker.Dispose();
            worker=new Process();
            worker.StartInfo=new ProcessStartInfo(FindRuntime(),"-NoLogo -NoProfile -File "+Quote(backendPath)+" -All -Mode "+(smokeTest ? "Monitor" : "Auto")+" -StateDirectory "+Quote(stateDir)+" -SettingsPath "+Quote(settingsPath));
            worker.StartInfo.UseShellExecute=false; worker.StartInfo.CreateNoWindow=true;
            worker.StartInfo.RedirectStandardOutput=true; worker.StartInfo.RedirectStandardError=true;
            worker.StartInfo.StandardOutputEncoding=Encoding.UTF8; worker.StartInfo.StandardErrorEncoding=Encoding.UTF8;
            worker.OutputDataReceived+=WorkerOutput; worker.ErrorDataReceived+=WorkerOutput;
            worker.Start(); worker.BeginOutputReadLine(); worker.BeginErrorReadLine();
            startedAt=DateTime.Now; start.Text="停止监控"; start.Enabled=true; mode.Text="正在查询…";
            AppendLog("后台监控已启动，不会打开终端窗口。");
        } catch(Exception e) { worker=null; AppendLog("启动失败："+e.Message); mode.Text="启动失败"; start.Text="启动监控"; }
    }
    void WorkerOutput(object sender,DataReceivedEventArgs e) {
        if(String.IsNullOrWhiteSpace(e.Data) || IsDisposed || !IsHandleCreated) return;
        try { BeginInvoke(new Action(delegate { AppendLog(e.Data); })); } catch(InvalidOperationException){}
    }
    void AppendLog(string message) {
        if(IsDisposed) return;
        string[] lines=(log.Text+message+Environment.NewLine).Split(new[]{Environment.NewLine},StringSplitOptions.RemoveEmptyEntries);
        log.Text=String.Join(Environment.NewLine,lines.Skip(Math.Max(0,lines.Length-60)))+Environment.NewLine;
        log.SelectionStart=log.TextLength; log.ScrollToCaret();
    }
    void Signal(string action) {
        if(!WorkerRunning()) return;
        if(stopRequested && action!="Stop") return;
        AtomicJson(Path.Combine(stateDir,"control.json"),new {id=Guid.NewGuid().ToString(),action=action,time=DateTime.UtcNow.ToString("o")});
    }
    void ProjectAction(string action) {
        if(chats.CurrentRow==null)return;
        if(observe.Checked){AppendLog("只读观察模式不操作项目，请先取消只读观察。");return;}
        if(stopRequested){AppendLog("正在停止监控，请稍后再操作。");return;}
        string id=Str(chats.CurrentRow.Tag),title=Str(chats.CurrentRow.Cells[1].Value);
        try {
            if(action=="AutoContinue" || action=="CancelAuto"){
                chats.CurrentRow.Cells[0].Value=action=="AutoContinue";SaveAndApply();
            }
            string directory=Path.Combine(stateDir,"commands");Directory.CreateDirectory(directory);
            AtomicJson(Path.Combine(directory,DateTime.UtcNow.Ticks.ToString("D20")+"-"+Guid.NewGuid().ToString()+".json"),new {id=Guid.NewGuid().ToString(),threadId=id,title=title,action=action,time=DateTime.UtcNow.ToString("o")});
            if(!WorkerRunning())StartWorker();else Signal("Refresh");
            if((action=="Start" || action=="AutoContinue") && Str(chats.CurrentRow.Cells[2].Value)=="未加载"){
                try {Process.Start(new ProcessStartInfo("codex://threads/"+id){UseShellExecute=true});AppendLog("正在 Codex 客户端打开未加载项目「"+title+"」，加载后执行已登记操作。");}
                catch(Exception e){AppendLog("操作已登记，请在 Codex 客户端打开项目「"+title+"」；自动打开失败："+e.Message);}
            }
            AppendLog("项目「"+title+"」操作已登记；实际暂停、开始和等待原因请看状态和日志。");
        }catch(Exception e){AppendLog("项目操作登记失败："+e.Message);}
    }
    void StopWorker() {
        if(!WorkerRunning()) return;
        stopRequested=true; Signal("Stop"); start.Enabled=false; mode.Text="正在停止监控…";
        AppendLog("已请求停止监控；当前聊天照常执行，暂停记录保留。");
    }
    void RequestExit() {
        exiting=true; StopWorker();
        if(!WorkerRunning()) FinishExit(); else mode.Text="正在关闭后台监控…";
    }
    void FinishExit() { allowClose=true; Close(); }
    void RestoreWindow() { Show(); WindowState=FormWindowState.Normal; Activate(); }
    void OpenLogs() {
        if(viewer==null || viewer.IsDisposed) { viewer=new LogWindow(logDir); viewer.Show(this); }
        else { viewer.Show(); viewer.Activate(); }
    }
    string Phase(string phase) {
        switch(phase) {
            case "paused": return "已暂停"; case "pause_pending": return "确认暂停中";
            case "resume_submitting": return "确认继续中"; case "resumed": return "已继续";
            case "needs_attention": return "需要排查";case "completed":return "本轮已结束";case "failed":return "本轮失败，需排查";
            case "cancelled": return "已解除登记"; case "stopped": return "已停止登记";
            case "observing": return "正常监控"; default: return "尚未登记";
            case "queued":return "已登记，等待继续";case "held":return "保持手动暂停";
        }
    }
    void RenderChats(bool force) {
        if(lastState==null) return;
        var data=Items(Get(lastState,"chats")).Select(Obj).Where(x=>showAll.Checked || IsRelevantChat(x)).ToList();
        string revision=lastChecked+"|"+resumeAll.Checked+"|"+showAll.Checked+"|"+json.Serialize(data);
        if(!force && revision==lastRendered) return;
        string selected=chats.CurrentRow==null ? "" : Str(chats.CurrentRow.Tag);
        int scroll=chats.FirstDisplayedScrollingRowIndex;
        loading=true; chats.Rows.Clear(); var ids=new HashSet<string>(config.resumeThreadIds);var excluded=new HashSet<string>(config.resumeExcludedThreadIds);
        foreach(var chat in data) {
            string id=Str(Get(chat,"id")), why=Str(Get(chat,"waitReason"));
            string runtime=Str(Get(chat,"runtime"));if(runtime=="执行中" && Str(Get(chat,"goalStatus"))=="active")runtime="目标执行";
            int index=chats.Rows.Add(resumeAll.Checked ? !excluded.Contains(id) : ids.Contains(id),Str(Get(chat,"title")),runtime,why.Length>0 ? why : Phase(Str(Get(chat,"monitorPhase"))));
            chats.Rows[index].Tag=id; chats.Rows[index].Cells[1].ToolTipText=Str(Get(chat,"title"));
            chats.Rows[index].Cells[3].ToolTipText=why;
            chats.Rows[index].Cells[2].Style.ForeColor=runtime.Contains("执行") ? Color.FromArgb(16,114,107) : Color.FromArgb(109,118,137);
            if(id==selected) chats.CurrentCell=chats.Rows[index].Cells[1];
        }
        chats.Columns[0].ReadOnly=false;listTitle.Text=(showAll.Checked ? "全部 " : "相关 ")+data.Count+" 个";
        if(scroll>=0 && scroll<chats.Rows.Count) chats.FirstDisplayedScrollingRowIndex=scroll;
        loading=false; lastRendered=revision;
    }
    static bool IsRelevantChat(Dictionary<string,object> chat){
        string runtime=Str(Get(chat,"runtime")),phase=Str(Get(chat,"monitorPhase"));
        return runtime=="执行中" || runtime=="目标待续" || runtime=="额度中断" || runtime=="等待输入或审批" || new[]{"observing","paused","queued","held","pause_pending","resume_submitting","needs_attention"}.Contains(phase) || Str(Get(chat,"waitReason")).Length>0;
    }
    void UpdateScreen() {
        try {
            string path=Path.Combine(stateDir,"state.json");
            if(File.Exists(path)) {
                var data=Obj(json.DeserializeObject(ReadShared(path)));
                lastState=data; lastChecked=Str(Get(data,"lastCheckedAt"));
                var quota=Obj(Get(data,"lastQuota"));
                if(quota.Count>0) { five.UpdateQuota(Get(quota,"remaining"),Get(quota,"resetsAt")); week.UpdateQuota(Get(quota,"weeklyRemaining"),Get(quota,"weeklyResetsAt")); }
                var c=Obj(Get(data,"counts"));
                int total=Convert.ToInt32(Get(c,"active")),ordinary=Convert.ToInt32(Get(c,"ordinaryActive")),goals=Convert.ToInt32(Get(c,"goals"));
                counts.Text="执行中 "+total+"（普通 "+ordinary+"，目标 "+(total-ordinary)+"）    ·    已暂停 "+Str(Get(c,"paused"))+"    ·    恢复后待续 "+Convert.ToInt32(Get(c,"autoResumePending"))+(goals>total-ordinary ? "    ·    目标待续 "+(goals-total+ordinary) : "");
                var credits=Obj(Get(quota,"resetCredits"));var available=Get(credits,"availableCount");
                var expires=Items(Get(credits,"credits")).Select(Obj).Where(x=>Str(Get(x,"status"))=="available" && Get(x,"expiresAt")!=null).Select(x=>Convert.ToInt64(Get(x,"expiresAt"))).OrderBy(x=>x).ToList();
                cardInfo.Text="可用卡："+(available==null ? "未提供" : Str(available)+" 张")+(expires.Count>0 ? "   ·   最早到期 "+QuotaCard.FromUnix(expires[0]).ToString("MM-dd HH:mm") : "");
                resetStatus.Text="重置卡："+Str(Get(data,"resetStatus"))+"；每次只用一张，成功后复查额度。";
                RenderChats(false);
                DateTime checkedTime;
                if(DateTime.TryParse(lastChecked,out checkedTime)) {
                    double age=(DateTime.Now-checkedTime.ToLocalTime()).TotalSeconds;
                    int delay=Get(data,"nextPollSeconds")==null ? config.pollSeconds : Convert.ToInt32(Get(data,"nextPollSeconds"));
                    freshness.Text="上次查询 "+checkedTime.ToLocalTime().ToString("HH:mm:ss")+"   ·   "+(age>delay+20 ? "数据已过期，正在等待客户端" : "距下次查询约 "+Math.Max(0,delay-(int)age)+" 秒")+"   ·   客户端 "+Str(Get(data,"appVersion"));
                    freshness.ForeColor=age>delay+20 ? Color.FromArgb(185,61,41) : Color.FromArgb(77,94,112);
                }
                if(WorkerRunning() && !stopRequested) mode.Text=Str(Get(data,"phase"))=="needs_attention" ? "需要排查，请看下方日志" : (Convert.ToInt32(Get(data,"readFailureCount"))>0 ? "查询连续失败 "+Str(Get(data,"readFailureCount"))+" 次，正在重试" : (config.observeOnly ? "只读观察 · 不操作聊天" : "自动监控 · 阈值 "+config.pauseRemainingPercent.ToString("0.#")+"%"));
            }
        } catch(IOException) { } catch(Exception e) { mode.Text="状态读取失败："+e.Message; }
        five.Tick(); week.Tick();
        if(!WorkerRunning()) {
            start.Enabled=true; start.Text="启动监控";
            mode.Text=stopRequested ? "监控已停止" : "监控未运行，请查看日志";
            if(exiting) {FinishExit(); return;}
        }
        if(smokeTest && !checkFinished) SmokeCheck();
    }
    void SmokeCheck() {
        if(DateTime.Now-startedAt>TimeSpan.FromSeconds(75)) { SaveCheck(false,"等待实时数据超时"); RequestExit(); return; }
        if(lastState==null || chats.Rows.Count==0) return;
        DateTime checkedTime;
        if(!DateTime.TryParse(lastChecked,out checkedTime) || checkedTime.ToLocalTime()<startedAt) return;
        if(!checkConfigured) {
            loading=true; poll.Value=initialConfig.pollSeconds==3 ? 4 : 3; threshold.Value=initialConfig.pauseRemainingPercent==12 ? 13 : 12; observe.Checked=true; resumeAll.Checked=false;
            foreach(DataGridViewRow row in chats.Rows) row.Cells[0].Value=false;
            chats.Rows[0].Cells[0].Value=true; config.resumeThreadIds=new[]{Str(chats.Rows[0].Tag)};
            loading=false; SaveAndApply(); RenderChats(true); checkConfigured=true; return;
        }
        var effective=Obj(Get(lastState,"settings")); var quota=Obj(Get(lastState,"lastQuota"));
        if(Convert.ToInt32(Get(effective,"pollSeconds"))!=config.pollSeconds || Convert.ToDouble(Get(effective,"pauseRemainingPercent"))!=config.pauseRemainingPercent || !Convert.ToBoolean(Get(effective,"observeOnly"))) return;
        bool passed=config.resumeThreadIds.Length==1 && !config.resumeAll && quota.Count>0 && Get(quota,"weeklyResetsAt")!=null && WorkerRunning() && !log.Text.Contains("\uFFFD");
        if(viewer==null) { OpenLogs(); return; }
        if(!viewer.Ready) return;
        passed=passed && viewer.RowCount>0 && viewer.HasQuotaRows;
        Directory.CreateDirectory(checkDir);
        viewer.SaveScreenshot(Path.Combine(checkDir,"logs-window.png"));
        viewer.ExportCsv(Path.Combine(checkDir,"logs.csv"));
        if(logDir!=stateDir) {
            passed=passed && viewer.HasControlHistory;
            viewer.SetFilter("暂停");
            passed=passed && viewer.RowCount>0;
            viewer.SaveScreenshot(Path.Combine(checkDir,"logs-pauses-window.png"));
        }
        using(var bitmap=new Bitmap(Width,Height)) { DrawToBitmap(bitmap,new Rectangle(Point.Empty,Size)); bitmap.Save(Path.Combine(checkDir,"window.png")); }
        ClientSize=new Size(960,900); PerformLayout(); Application.DoEvents();
        using(var bitmap=new Bitmap(Width,Height)) { DrawToBitmap(bitmap,new Rectangle(Point.Empty,Size)); bitmap.Save(Path.Combine(checkDir,"window-small.png")); }
        try {CheckChoicesAndPreview();}catch(Exception e){SaveCheck(false,"界面交互检查失败："+e.Message);RequestExit();return;}
        passed=passed && choicesPassed && quotaDisplayPassed;
        SaveCheck(passed,"实时额度、重置时间、失败次数设置、项目筛选及全部列表、右键菜单、单项目选择和只读设置"); RequestExit();
    }
    void CheckChoicesAndPreview(){
        var savedState=lastState;var savedConfig=json.Serialize(config);bool savedDefault=resumeAll.Checked;
        Func<string,string,string,string,Dictionary<string,object>> chat=delegate(string id,string title,string runtime,string phase){return new Dictionary<string,object>{{"id",id},{"title",title},{"runtime",runtime},{"monitorPhase",phase},{"goalStatus",id=="demo-goal" ? "active" : ""}};};
        try {
            lastState=new Dictionary<string,object>{{"chats",new object[]{chat("demo-goal","整理项目文档","执行中","observing"),chat("demo-ordinary","核对数据记录","执行中","observing"),chat("demo-paused","生成研究报告","额度中断","paused"),chat("demo-history","历史任务（不应显示）","空闲","completed"),chat("demo-unloaded","未加载历史（不应显示）","未加载","")}}};
            loading=true;resumeAll.Checked=true;config.resumeAll=true;config.resumeExcludedThreadIds=new string[0];loading=false;RenderChats(true);
            if(chats.Rows.Count!=3 || chats.Columns[0].ReadOnly)throw new Exception("相关聊天筛选或勾选被锁住");
            chats.Rows[0].Cells[0].Value=false;
            if(!config.resumeExcludedThreadIds.Contains("demo-goal"))throw new Exception("默认允许时无法取消单行");
            RenderChats(true);if(Convert.ToBoolean(chats.Rows[0].Cells[0].Value))throw new Exception("刷新丢失取消选择");
            chats.Rows[0].Cells[0].Value=true;
            if(config.resumeExcludedThreadIds.Contains("demo-goal"))throw new Exception("默认允许时无法重新勾选");
            resumeAll.Checked=false;
            if(!Convert.ToBoolean(chats.Rows[0].Cells[0].Value))throw new Exception("切换新聊天默认值覆盖已有选择");
            chats.Rows[0].Cells[0].Value=false;RenderChats(true);
            if(Convert.ToBoolean(chats.Rows[0].Cells[0].Value))throw new Exception("逐项模式无法取消");
            chats.Rows[0].Cells[0].Value=true;RenderChats(true);
            if(!Convert.ToBoolean(chats.Rows[0].Cells[0].Value))throw new Exception("逐项模式无法开启");
            var persisted=json.Deserialize<MonitorSettings>(ReadShared(settingsPath));
            if(!persisted.resumeThreadIds.Contains("demo-goal") || persisted.resumeExcludedThreadIds.Contains("demo-goal"))throw new Exception("逐项选择没有保存");
            choicesPassed=true;
            showAll.Checked=true;RenderChats(true);if(chats.Rows.Count!=5)throw new Exception("显示所有项目遗漏空闲或未加载项目");
            showAll.Checked=false;RenderChats(true);if(chats.Rows.Count!=3 || projectMenu.Items.Count!=4)throw new Exception("项目筛选或右键菜单错误");
            if(json.Deserialize<MonitorSettings>(ReadShared(settingsPath)).showAllProjects)throw new Exception("全部列表开关没有保存");
            failureLimit.Value=7;stopOnFailures.Checked=true;SaveAndApply();
            if(json.Deserialize<MonitorSettings>(ReadShared(settingsPath)).maxConsecutiveFailures!=7 || !failureLimit.Enabled)throw new Exception("失败次数设置没有保存");
            stopOnFailures.Checked=false;SaveAndApply();
            if(json.Deserialize<MonitorSettings>(ReadShared(settingsPath)).maxConsecutiveFailures!=0 || failureLimit.Enabled)throw new Exception("无法关闭连续失败自动停止");
            long resetAt=(long)(DateTime.UtcNow.AddHours(2)-new DateTime(1970,1,1)).TotalSeconds;
            five.UpdateQuota(65,resetAt);if(five.Value.Text!="剩余 65%")throw new Exception("额度 65% 未显示");
            five.UpdateQuota(7,resetAt);if(five.Value.Text!="剩余 7%" || five.Bar.Value!=7 || five.Detail.Text!="已用 93%")throw new Exception("额度变化未刷新");
            five.UpdateQuota(0,resetAt);if(five.Value.Text!="剩余 0%" || five.Bar.Value!=0)throw new Exception("额度归零未刷新");
            quotaDisplayPassed=true;
            five.UpdateQuota(65,resetAt);week.UpdateQuota(80,resetAt+6*86400);
            ClientSize=new Size(1120,970);PerformLayout();
            counts.Text="执行中 2（普通 1，目标 1）    ·    已暂停 1    ·    恢复后待续 1";mode.Text="自动监控 · 暂停阈值 5%";
            loading=true;observe.Checked=false;autoReset.Checked=false;poll.Value=180;threshold.Value=5;nearThreshold.Value=10;nearPoll.Value=10;resetThreshold.Value=1;failureLimit.Value=5;loading=false;
            cardInfo.Text="可用卡：2 张   ·   最早到期 01-31 12:00";resetStatus.Text="重置卡：自动使用已关闭；每次只用一张，成功后复查额度。";
            freshness.Text="上次查询 12:00:00   ·   常规 180 秒，低额度 10 秒   ·   示例界面";
            log.Text="[12:00:00] 五小时余 65% | 周余 80% | 执行中 2（普通 1，目标 1） | 已暂停 1\r\n[11:59:30] 聊天「生成研究报告」因额度不足中断，等待额度恢复。";
            using(var bitmap=new Bitmap(Width,Height)){DrawToBitmap(bitmap,new Rectangle(Point.Empty,Size));bitmap.Save(Path.Combine(checkDir,"preview.png"));}
            ClientSize=new Size(960,900);PerformLayout();
            using(var bitmap=new Bitmap(Width,Height)){DrawToBitmap(bitmap,new Rectangle(Point.Empty,Size));bitmap.Save(Path.Combine(checkDir,"preview-small.png"));}
            projectMenu.Show(chats,new Point(260,30));projectMenu.Refresh();
            using(var bitmap=new Bitmap(projectMenu.Width,projectMenu.Height)){projectMenu.DrawToBitmap(bitmap,new Rectangle(Point.Empty,projectMenu.Size));bitmap.Save(Path.Combine(checkDir,"project-menu.png"));}projectMenu.Close();
        }finally {
            loading=true;lastState=savedState;config=json.Deserialize<MonitorSettings>(savedConfig);resumeAll.Checked=savedDefault;
            observe.Checked=config.observeOnly;autoReset.Checked=config.autoResetEnabled;poll.Value=config.pollSeconds;threshold.Value=(decimal)config.pauseRemainingPercent;nearThreshold.Value=(decimal)config.nearLimitRemainingPercent;nearPoll.Value=config.nearLimitPollSeconds;resetThreshold.Value=(decimal)config.resetWeeklyRemainingPercent;
            stopOnFailures.Checked=config.maxConsecutiveFailures>0;failureLimit.Value=config.maxConsecutiveFailures>0 ? config.maxConsecutiveFailures : 5;failureLimit.Enabled=stopOnFailures.Checked;
            showAll.Checked=config.showAllProjects;
            loading=false;WriteSettings();
        }
    }
    void SaveCheck(bool passed,string detail) {
        checkFinished=true; Directory.CreateDirectory(checkDir);
        AtomicJson(Path.Combine(checkDir,"ui-check-result.json"),new {passed=passed,detail=detail,checkedAt=DateTime.Now.ToString("o"),initialSettings=initialConfig,settings=config,chats=chats.Rows.Count,choicesPassed=choicesPassed,quotaDisplayPassed=quotaDisplayPassed,logRows=viewer==null ? 0 : viewer.RowCount,quota=lastState==null ? null : Get(lastState,"lastQuota"),stateDirectory=stateDir});
    }
}
