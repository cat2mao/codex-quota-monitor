#requires -Version 7.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'quota-monitor.ps1') -Library
$checkDirectory=Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\work\quota-monitor-concurrency-check'))) ([guid]::NewGuid().ToString())
[void][IO.Directory]::CreateDirectory($checkDirectory)
$path=Join-Path $checkDirectory 'control.json'
Write-JsonAtomic $path @{sequence=0;check=0}
Add-Type -TypeDefinition @'
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public static class MonitorAtomicWriter {
    public static Task Start(string path) {
        return Task.Run(() => {
            for(int i=1;i<=1000;i++) {
                string temp=path+".gui.tmp";
                File.WriteAllText(temp,"{\"sequence\":"+i+",\"check\":"+(i*2)+"}",new UTF8Encoding(false));
                File.Replace(temp,path,null);
                Thread.Sleep(1);
            }
        });
    }
}
'@
$writer=[MonitorAtomicWriter]::Start($path)
$reads=0
while(!$writer.IsCompleted -or $reads -lt 1000){
    $record=Read-Json $path
    if($record.check -ne $record.sequence*2){throw 'Read a partial or inconsistent control file'}
    $reads++
}
$writer.GetAwaiter().GetResult()
if((Read-Json $path).sequence -ne 1000){throw 'Writer did not finish'}
Write-Host "PASS concurrent GUI replacement and backend reads ($reads reads, 1000 writes)"
