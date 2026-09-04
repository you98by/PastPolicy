# PastPolicy Bootstrapper
$ErrorActionPreference = 'Stop'
$installDir = "$env:LOCALAPPDATA\PastPolicy"
$repoUrl = "https://github.com/you98by/PastPolicy/archive/refs/heads/main.zip"

if (!(Test-Path "$installDir\src\PastPolicy-App.ps1")) {
    Write-Host "Installing PastPolicy to $installDir..." -ForegroundColor Cyan
    $zipPath = "$env:TEMP\PastPolicy.zip"
    $extractPath = "$env:TEMP\PastPolicy_Extract"
    
    Invoke-WebRequest -Uri $repoUrl -OutFile $zipPath -UseBasicParsing
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
    
    $sourceDir = Get-ChildItem -Path $extractPath | Select-Object -First 1
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Copy-Item -Path "$($sourceDir.FullName)\*" -Destination $installDir -Recurse -Force
    
    Remove-Item $zipPath, $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Installation complete!" -ForegroundColor Green
}

# Launch the App
& "$installDir\src\PastPolicy-App.ps1"
