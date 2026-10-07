#requires -Version 7.0
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$directory=Join-Path $PSScriptRoot '..\assets';[void][IO.Directory]::CreateDirectory($directory)
$images=[Collections.Generic.List[byte[]]]::new()
$sizes=@(16,24,32,48,64,128,256)
foreach($size in $sizes){
    $bitmap=[Drawing.Bitmap]::new($size,$size)
    $g=[Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode='AntiAlias';$g.PixelOffsetMode='HighQuality';$g.ScaleTransform($size/256.0,$size/256.0)
    $path=[Drawing.Drawing2D.GraphicsPath]::new()
    foreach($arc in @(@(8,8,56,56,180),@(192,8,56,56,270),@(192,192,56,56,0),@(8,192,56,56,90))){$path.AddArc($arc[0],$arc[1],$arc[2],$arc[3],$arc[4],90)}
    $path.CloseFigure()
    $background=[Drawing.Drawing2D.LinearGradientBrush]::new([Drawing.Point]::new(10,10),[Drawing.Point]::new(240,240),[Drawing.Color]::FromArgb(16,42,71),[Drawing.Color]::FromArgb(16,114,122))
    $g.FillPath($background,$path)
    $track=[Drawing.Pen]::new([Drawing.Color]::FromArgb(85,126,146),18)
    $accent=[Drawing.Pen]::new([Drawing.Color]::FromArgb(104,234,208),18)
    $needle=[Drawing.Pen]::new([Drawing.Color]::White,12)
    foreach($pen in @($track,$accent,$needle)){$pen.StartCap='Round';$pen.EndCap='Round'}
    $g.DrawArc($track,48,48,160,160,135,270);$g.DrawArc($accent,48,48,160,160,135,192)
    $g.DrawLine($needle,128,128,169,91)
    $white=[Drawing.SolidBrush]::new([Drawing.Color]::White);$g.FillEllipse($white,114,114,28,28)
    $g.FillRectangle($white,100,188,12,25);$g.FillRectangle($white,124,188,12,25);$g.FillRectangle($white,148,188,12,25)
    $stream=[IO.MemoryStream]::new();$bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Png);$images.Add($stream.ToArray())
    if($size -eq 256){$bitmap.Save((Join-Path $directory 'quota-monitor.png'),[Drawing.Imaging.ImageFormat]::Png)}
    foreach($resource in @($g,$path,$background,$track,$accent,$needle,$white,$stream,$bitmap)){$resource.Dispose()}
}
$stream=[IO.File]::Create((Join-Path $directory 'quota-monitor.ico'));$writer=[IO.BinaryWriter]::new($stream)
try {
    $writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]$sizes.Count)
    $offset=6+16*$sizes.Count
    for($i=0;$i -lt $sizes.Count;$i++){
        $dimension=[byte]$(if($sizes[$i] -eq 256){0}else{$sizes[$i]})
        $writer.Write($dimension);$writer.Write($dimension);$writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]32)
        $writer.Write([uint32]$images[$i].Length);$writer.Write([uint32]$offset);$offset+=$images[$i].Length
    }
    foreach($bytes in $images){$writer.Write($bytes)}
}finally{$writer.Dispose()}
