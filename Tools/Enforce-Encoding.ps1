#Requires -Version 5.1
$targetDir = "C:\PostInstall"
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

$files = Get-ChildItem -Path $targetDir -Include "*.ps1", "*.json" -Recurse | Where-Object { $_.FullName -notlike "*\.git*" }

foreach ($f in $files) {
    try {
        $content = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($f.FullName, $content, $utf8Bom)
        
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        Write-Host "File: $($f.Name) | HasBOM: $hasBom | Bytes: $($bytes.Length)"
    } catch {}
}
