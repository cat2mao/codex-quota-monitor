using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

class LogRecord {
    public DateTime Time;
    public string Type, Category, Chat, Five, Week, Message, QuotaTime;
}

class LogWindow : Form {
    readonly string directory;
    readonly DataGridView table=new DataGridView();
    readonly DateTimePicker date=new DateTimePicker();
    readonly CheckBox allDates=new CheckBox();
    readonly ComboBox kind=new ComboBox();
    readonly TextBox search=new TextBox();
    readonly Label summary=new Label();
    readonly Button reload=new Button();
    List<LogRecord> records=new List<LogRecord>(), filtered=new List<LogRecord>();
    bool loading;
    int invalidLines;
    public bool Ready {get; private set;}
    public int RowCount {get{return table.Rows.Count;}}
    public bool HasQuotaRows {get{return records.Any(r=>r.Five!="未记录" && r.Week!="未记录");}}
    public bool HasControlHistory {get{return records.Any(r=>r.Category=="暂停") && records.Any(r=>r.Category=="继续");}}

    public LogWindow(string stateDirectory) {
        directory=stateDirectory; Text="运行日志 · Codex 额度监控";
        ClientSize=new Size(1280,680); MinimumSize=new Size(980,560); StartPosition=FormStartPosition.CenterParent;
        Font=new Font("Microsoft YaHei UI",9); BackColor=Color.FromArgb(241,245,248);
        var layout=new TableLayoutPanel {Dock=DockStyle.Fill,Padding=new Padding(14),ColumnCount=1,RowCount=3};
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute,84)); layout.RowStyles.Add(new RowStyle(SizeType.Percent,100)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute,32));
        var toolbar=new TableLayoutPanel {Dock=DockStyle.Fill,ColumnCount=1,RowCount=2};
        toolbar.RowStyles.Add(new RowStyle(SizeType.Absolute,42)); toolbar.RowStyles.Add(new RowStyle(SizeType.Absolute,40));
        var filters=new FlowLayoutPanel {Dock=DockStyle.Fill,WrapContents=false};
        var actions=new FlowLayoutPanel {Dock=DockStyle.Fill,WrapContents=false};
        allDates.Text="全部日期"; allDates.Checked=true; allDates.AutoSize=true; allDates.Margin=new Padding(0,9,10,0);
        date.Format=DateTimePickerFormat.Custom; date.CustomFormat="yyyy-MM-dd"; date.Width=170; date.Enabled=false; date.Margin=new Padding(0,6,12,0);
        kind.DropDownStyle=ComboBoxStyle.DropDownList; kind.Items.AddRange(new object[]{"全部事件","暂停","继续","额度","重置卡","错误","启停","完成","设置"}); kind.SelectedIndex=0; kind.Width=130; kind.Margin=new Padding(0,6,12,0);
        search.Width=195; search.Margin=new Padding(0,6,12,0);
        var searchLabel=new Label {Text="聊天 / 内容",AutoSize=true,Margin=new Padding(0,10,8,0)};
        reload.Text="刷新日志"; reload.AutoSize=true; reload.Margin=new Padding(0,4,10,0); reload.Click+=delegate {Reload();};
        var export=new Button {Text="导出 CSV",AutoSize=true,Margin=new Padding(0,4,0,0)}; export.Click+=delegate {Export();};
        filters.Controls.Add(allDates); filters.Controls.Add(date); filters.Controls.Add(kind); filters.Controls.Add(searchLabel); filters.Controls.Add(search);
        actions.Controls.Add(reload); actions.Controls.Add(export);
        actions.Controls.Add(new Label {Text="显示本机时间 · 按确认事件判断暂停或继续 · 鼠标停在文字上可看完整内容",AutoSize=true,Margin=new Padding(18,10,0,0)});
        toolbar.Controls.Add(filters,0,0); toolbar.Controls.Add(actions,0,1);
        allDates.CheckedChanged+=delegate {date.Enabled=!allDates.Checked; Filter();}; date.ValueChanged+=delegate {Filter();};
        kind.SelectedIndexChanged+=delegate {Filter();}; search.TextChanged+=delegate {Filter();};
        table.Dock=DockStyle.Fill; table.ReadOnly=true; table.AllowUserToAddRows=false; table.AllowUserToDeleteRows=false;
        table.RowHeadersVisible=false; table.BackgroundColor=Color.White; table.BorderStyle=BorderStyle.None;
        table.SelectionMode=DataGridViewSelectionMode.FullRowSelect; table.MultiSelect=false; table.RowTemplate.Height=33;
        table.ColumnHeadersHeight=36; table.EnableHeadersVisualStyles=false; table.ColumnHeadersDefaultCellStyle.BackColor=Color.FromArgb(226,234,240);
        table.DefaultCellStyle.SelectionBackColor=Color.FromArgb(224,243,240); table.DefaultCellStyle.SelectionForeColor=Color.Black;
        table.GridColor=Color.FromArgb(231,236,241); table.AlternatingRowsDefaultCellStyle.BackColor=Color.FromArgb(247,249,250);
        string[] names={"时间","事件","聊天","五小时额度","周额度","说明"}; int[] widths={245,105,240,180,180,300};
        for(int i=0;i<names.Length;i++) table.Columns.Add(new DataGridViewTextBoxColumn {HeaderText=names[i],Width=widths[i],AutoSizeMode=i==5 ? DataGridViewAutoSizeColumnMode.Fill : DataGridViewAutoSizeColumnMode.None,MinimumWidth=i==5 ? 180 : 40,SortMode=DataGridViewColumnSortMode.NotSortable});
        summary.Dock=DockStyle.Fill; summary.TextAlign=ContentAlignment.MiddleLeft; summary.ForeColor=Color.FromArgb(77,94,112);
        layout.Controls.Add(toolbar,0,0); layout.Controls.Add(table,0,1); layout.Controls.Add(summary,0,2); Controls.Add(layout);
        Shown+=delegate {Reload();};
    }
    static object Get(Dictionary<string,object> data,string name) {object value; return data.TryGetValue(name,out value) ? value : null;}
    static string Str(object value) {return value==null ? "" : Convert.ToString(value);}
    static Dictionary<string,object> Obj(object value) {return value as Dictionary<string,object> ?? new Dictionary<string,object>();}
    static string Percentage(object value) {
        if(value==null) return "未记录";
        double remaining=Convert.ToDouble(value);
        return "余 "+remaining.ToString("0.#")+"% / 用 "+(100-remaining).ToString("0.#")+"%";
    }
    static string EventType(string name,out string category) {
        category="";
        switch(name) {
            case "pause_pending": category="暂停"; return "请求暂停";
            case "paused": category="暂停"; return "确认暂停";
            case "quota-interrupted":category="暂停";return "额度中断登记";
            case "manual-held":category="暂停";return "保持手动暂停";
            case "manual-registered":category="继续";return "登记自动继续";
            case "manual-command-queued":category="设置";return "项目操作登记";
            case "manual-start":category="继续";return "手动开始";
            case "manual-already-active":category="继续";return "已有执行，无重复开始";
            case "manual-rejected":category="错误";return "项目操作未执行";
            case "interrupt-response": category="暂停"; return "暂停回复";
            case "resume_submitting": category="继续"; return "提交继续";
            case "resumed": category="继续"; return "确认继续";
            case "resume-response": category="继续"; return "继续回复";
            case "all-monitor": category="额度"; return "额度查询";
            case "completed": category="完成"; return "本轮结束";
            case "failed":category="错误";return "本轮失败";
            case "settings-updated": category="设置"; return "设置变更";
            case "reset-requested": category="重置卡";return "请求使用卡";
            case "reset-result": category="重置卡";return "服务器结果";
            case "reset-refreshed": category="重置卡";return "重置后额度";
            case "reset-error": category="重置卡";return "使用待核实";
            case "all-started": case "started": category="启停"; return "开始监控";
            case "stopped": category="启停"; return "停止监控";
            case "cancelled": case "removed-chat": category="启停"; return "解除登记";
            case "needs_attention": case "fatal-error": case "all-read-error": case "connection-or-read-error": case "thread-control-error": category="错误"; return "异常";
            default: return null;
        }
    }
    async void Reload() {
        if(loading) return;
        loading=true; Ready=false; reload.Enabled=false; summary.Text="正在读取历史日志…";
        try {
            int bad=0;
            var result=await Task.Run(delegate {
                var parsed=new List<LogRecord>(); var parser=new JavaScriptSerializer {MaxJsonLength=16*1024*1024,RecursionLimit=100};
                var titles=new Dictionary<string,string>();
                string state=Path.Combine(directory,"state.json");
                if(File.Exists(state)) {
                    using(var stream=new FileStream(state,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
                    using(var reader=new StreamReader(stream,Encoding.UTF8)) {
                        var data=Obj(parser.DeserializeObject(reader.ReadToEnd()));
                        foreach(var entry in Obj(Get(data,"threads"))) titles[entry.Key]=Str(Get(Obj(entry.Value),"displayTitle"));
                    }
                }
                foreach(string path in Directory.GetFiles(directory,"events.jsonl",SearchOption.AllDirectories)) {
                    using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
                    using(var reader=new StreamReader(stream,Encoding.UTF8)) {
                        string line;
                        while((line=reader.ReadLine())!=null) {
                            try {
                                var data=Obj(parser.DeserializeObject(line)); string category;
                                string type=EventType(Str(Get(data,"event")),out category); if(type==null) continue;
                                DateTime time; if(!DateTime.TryParse(Str(Get(data,"time")),out time)){bad++;continue;}
                                string message=Str(Get(data,"message")),chat=Str(Get(data,"chatTitle")),id=Str(Get(data,"threadId"));
                                if(chat.Length==0) {
                                    var match=Regex.Match(message,"聊天「(.*?)」");
                                    if(match.Success) chat=match.Groups[1].Value;
                                    else if(id=="all") chat="全部聊天";
                                    else if(titles.ContainsKey(id)) chat=titles[id];
                                    else chat="历史聊天";
                                }
                                var quota=Obj(Get(data,"quota")); var details=Obj(Get(data,"details"));
                                object five=Get(quota,"remaining") ?? Get(details,"remaining"),week=Get(quota,"weeklyRemaining") ?? Get(details,"weeklyRemaining");
                                string quotaWhen=Str(Get(data,"quotaCheckedAt")); DateTime quotaTime;
                                if(DateTime.TryParse(quotaWhen,out quotaTime)) quotaWhen=quotaTime.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss");
                                parsed.Add(new LogRecord {Time=time.ToLocalTime(),Type=type,Category=category,Chat=chat,Five=Percentage(five),Week=Percentage(week),Message=message.Length>0 ? message : type+"（旧日志未记录详细说明）",QuotaTime=quotaWhen});
                            } catch(ArgumentException){bad++;} catch(InvalidOperationException){bad++;} catch(FormatException){bad++;}
                        }
                    }
                }
                return parsed.OrderByDescending(r=>r.Time).ToList();
            });
            if(IsDisposed) return;
            records=result; invalidLines=bad; Ready=true; Filter();
        } catch(Exception e) {if(!IsDisposed){summary.Text="日志读取失败："+e.Message; Ready=true;}}
        finally {loading=false; if(!IsDisposed) reload.Enabled=true;}
    }
    void Filter() {
        if(table.Columns.Count==0) return;
        string filter=Str(kind.SelectedItem),text=search.Text.Trim();
        filtered=records.Where(r=>(allDates.Checked || r.Time.Date==date.Value.Date) && (filter=="全部事件" || r.Category==filter) && (text.Length==0 || (r.Chat+" "+r.Message).IndexOf(text,StringComparison.OrdinalIgnoreCase)>=0)).ToList();
        table.Rows.Clear();
        foreach(var record in filtered.Take(2000)) {
            int i=table.Rows.Add(record.Time.ToString("yyyy-MM-dd HH:mm:ss"),record.Type,record.Chat,record.Five,record.Week,record.Message);
            table.Rows[i].Cells[2].ToolTipText=record.Chat; table.Rows[i].Cells[5].ToolTipText=record.Message;
            string tooltip=record.QuotaTime.Length==0 ? "旧日志未记录额度更新时间" : "额度对应的查询时间："+record.QuotaTime;
            table.Rows[i].Cells[3].ToolTipText=tooltip; table.Rows[i].Cells[4].ToolTipText=tooltip;
        }
        summary.Text="匹配 "+filtered.Count+" 条，显示最近 "+table.Rows.Count+" 条 · 暂停/继续以客户端确认事件为准 · 旧字段缺失显示“未记录”"+(invalidLines>0 ? " · 跳过 "+invalidLines+" 条不完整记录" : "");
    }
    static string Csv(string value) {return "\""+(value??"").Replace("\"","\"\"")+"\"";}
    void Export() {
        using(var dialog=new SaveFileDialog {Filter="CSV 文件|*.csv",FileName="额度监控日志-"+DateTime.Now.ToString("yyyyMMdd-HHmmss")+".csv"}) {
            if(dialog.ShowDialog(this)!=DialogResult.OK) return;
            try {
                ExportCsv(dialog.FileName);
                summary.Text="已导出全部 "+filtered.Count+" 条筛选结果："+dialog.FileName;
            } catch(Exception e) {MessageBox.Show(this,"导出失败："+e.Message,"运行日志");}
        }
    }
    public void SetFilter(string category) {kind.SelectedItem=category;}
    public void ExportCsv(string path) {
        using(var output=new StreamWriter(path,false,new UTF8Encoding(true))) {
            output.WriteLine("时间,事件,聊天,五小时额度,周额度,说明,额度查询时间");
            foreach(var r in filtered) output.WriteLine(String.Join(",",new[]{r.Time.ToString("yyyy-MM-dd HH:mm:ss"),r.Type,r.Chat,r.Five,r.Week,r.Message,r.QuotaTime}.Select(Csv)));
        }
    }
    public void SaveScreenshot(string path) {using(var image=new Bitmap(Width,Height)){DrawToBitmap(image,new Rectangle(Point.Empty,Size));image.Save(path);}}
}
