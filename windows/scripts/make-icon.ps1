param([string]$OutputPath = (Join-Path $PSScriptRoot '../FusionPlay.Windows/Assets/AppIcon.ico'))
$ErrorActionPreference = 'Stop'
$taskSource = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../FusionPlay.Windows/Assets/AppIcon.png'))
$taskDestination = [IO.Path]::GetFullPath($OutputPath)
if ((Test-Path -LiteralPath $taskDestination) -and (Get-Item -LiteralPath $taskDestination).LastWriteTimeUtc -ge (Get-Item -LiteralPath $taskSource).LastWriteTimeUtc) { return }
New-Item -ItemType Directory -Path (Split-Path $taskDestination -Parent) -Force | Out-Null
Add-Type -AssemblyName System.Drawing
$taskSourceImage = [Drawing.Bitmap]::FromFile($taskSource)
try {
    $taskImages = [Collections.Generic.List[byte[]]]::new()
    $taskSizes = @(16, 20, 24, 32, 48, 64, 128, 256)
    foreach ($taskSize in $taskSizes) {
        $taskBitmap = [Drawing.Bitmap]::new($taskSize, $taskSize)
        $taskGraphics = [Drawing.Graphics]::FromImage($taskBitmap)
        $taskStream = [IO.MemoryStream]::new()
        try {
            $taskGraphics.Clear([Drawing.Color]::Transparent)
            $taskGraphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
            $taskGraphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $taskGraphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $taskGraphics.DrawImage($taskSourceImage, 0, 0, $taskSize, $taskSize)
            $taskBitmap.Save($taskStream, [Drawing.Imaging.ImageFormat]::Png)
            $taskImages.Add($taskStream.ToArray())
        } finally { $taskGraphics.Dispose(); $taskBitmap.Dispose(); $taskStream.Dispose() }
    }
    $taskFile = [IO.File]::Create($taskDestination)
    $taskWriter = [IO.BinaryWriter]::new($taskFile)
    try {
        $taskWriter.Write([uint16]0); $taskWriter.Write([uint16]1); $taskWriter.Write([uint16]$taskImages.Count)
        $taskOffset = 6 + 16 * $taskImages.Count
        for ($taskIndex = 0; $taskIndex -lt $taskImages.Count; $taskIndex++) {
            $taskWriter.Write([byte]($taskSizes[$taskIndex] % 256)); $taskWriter.Write([byte]($taskSizes[$taskIndex] % 256))
            $taskWriter.Write([byte]0); $taskWriter.Write([byte]0); $taskWriter.Write([uint16]1); $taskWriter.Write([uint16]32)
            $taskWriter.Write([uint32]$taskImages[$taskIndex].Length); $taskWriter.Write([uint32]$taskOffset)
            $taskOffset += $taskImages[$taskIndex].Length
        }
        foreach ($taskImage in $taskImages) { $taskWriter.Write($taskImage) }
    } finally { $taskWriter.Dispose(); $taskFile.Dispose() }
} finally { $taskSourceImage.Dispose() }
