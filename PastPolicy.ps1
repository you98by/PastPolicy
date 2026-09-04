# PastPolicy Bootstrapper
$ErrorActionPreference = 'Stop'
$repoUrl = "https://github.com/you98by/PastPolicy/archive/refs/heads/main.zip"
$bootstrapUrl = 'https://raw.githubusercontent.com/you98by/PastPolicy/main/PastPolicy.ps1'
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$currentIdentity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($PSCommandPath) {
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    } else {
        $elevatedCommand = "& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing -Uri '$bootstrapUrl').Content))"
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $elevatedCommand)
    }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments
    exit
}

$installDir = 'C:\PastPolicy'

if (!(Test-Path "$installDir\src\PastPolicy-App.ps1")) {
    Write-Host "Installing PastPolicy App to $installDir..." -ForegroundColor Cyan
    $zipPath = "$env:TEMP\PastPolicy.zip"
    $extractPath = "$env:TEMP\PastPolicy_Extract"
    
    Invoke-WebRequest -Uri $repoUrl -OutFile $zipPath -UseBasicParsing
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
    
    $sourceDir = Get-ChildItem -Path $extractPath | Select-Object -First 1
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Copy-Item -Path "$($sourceDir.FullName)\*" -Destination $installDir -Recurse -Force
    
    Remove-Item $zipPath, $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Installation complete! Launching..." -ForegroundColor Green
}

# Launch the App
& "$installDir\src\PastPolicy-App.ps1"
