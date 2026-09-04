# Install Microsoft Edge policy templates
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$downloadPage = 'https://www.microsoft.com/en-us/edge/business/download'
$policyDefinitions = Join-Path $env:WINDIR 'PolicyDefinitions'
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$currentIdentity

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    exit
}

$tempRoot = Join-Path $env:TEMP ('PastPolicy-EdgeTemplates-' + [guid]::NewGuid().ToString('N'))
$cabPath = Join-Path $tempRoot 'MicrosoftEdgePolicyTemplates.cab'
$extractPath = Join-Path $tempRoot 'Extracted'

try {
    New-Item -ItemType Directory -Path $tempRoot, $extractPath -Force | Out-Null
    Write-Host 'Finding the official Microsoft Edge policy template download...' -ForegroundColor Cyan
    $page = Invoke-WebRequest -Uri $downloadPage -UseBasicParsing
    $link = @($page.Links | Where-Object { $_.href -match '(?i)(policy|template).*(\.cab|\.zip)' } | Select-Object -First 1).href
    if (-not $link) {
        throw "Microsoft's download page did not expose a policy template link. Open $downloadPage to download it manually."
    }
    if ($link -notmatch '^https?://') { $link = [uri]::new([uri]$downloadPage, $link).AbsoluteUri }

    Write-Host "Downloading $link" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $link -OutFile $cabPath -UseBasicParsing
    if ([IO.Path]::GetExtension($link) -ieq '.zip') {
        $zipPath = Join-Path $tempRoot 'MicrosoftEdgePolicyTemplates.zip'
        Move-Item -LiteralPath $cabPath -Destination $zipPath -Force
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
    } else {
        & expand.exe -F:* $cabPath $extractPath | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Windows could not extract the Edge policy template archive.' }
    }

    $admx = Get-ChildItem -LiteralPath $extractPath -Filter 'msedge.admx' -File -Recurse | Select-Object -First 1
    if (-not $admx) { throw 'The downloaded archive did not contain msedge.admx.' }
    Copy-Item -LiteralPath $admx.FullName -Destination (Join-Path $policyDefinitions 'msedge.admx') -Force

    $languageFiles = @(Get-ChildItem -LiteralPath $extractPath -Filter 'msedge.adml' -File -Recurse)
    foreach ($languageFile in $languageFiles) {
        $languageDirectory = Split-Path -Leaf (Split-Path -Parent $languageFile.FullName)
        $destinationDirectory = Join-Path $policyDefinitions $languageDirectory
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath $languageFile.FullName -Destination (Join-Path $destinationDirectory 'msedge.adml') -Force
    }

    Write-Host "Installed msedge.admx and $($languageFiles.Count) language file(s) to $policyDefinitions." -ForegroundColor Green
    Write-Host 'Restart Local Group Policy Editor to load the new Edge policies.' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
