# Bundle Microsoft's signed bootstrapper for installer and portable users.
param([switch]$Install)

$ErrorActionPreference = 'Stop'
$cache = Join-Path $PSScriptRoot '../.dart_tool/webview2'
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$installer = Join-Path $cache 'MicrosoftEdgeWebview2Setup.exe'
if (-not (Test-Path $installer)) {
    Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile $installer
}
$signature = Get-AuthenticodeSignature $installer
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    Remove-Item $installer
    throw 'WebView2 bootstrapper does not have a valid Microsoft signature.'
}
if ($Install) {
    $client = 'Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    $installed = @(
        "HKLM:\SOFTWARE\WOW6432Node\$client",
        "HKLM:\SOFTWARE\$client",
        "HKCU:\SOFTWARE\$client"
    ) | ForEach-Object { (Get-ItemProperty -Path $_ -Name pv -ErrorAction SilentlyContinue).pv } |
        Where-Object { $_ -and $_ -ne '0.0.0.0' }
    if (-not $installed) {
        $process = Start-Process -FilePath $installer -ArgumentList '/silent', '/install' -Wait -PassThru
        if ($process.ExitCode -notin @(0, 1641, 3010)) { throw "WebView2 installation failed: $($process.ExitCode)" }
    }
} else {
    $bundle = Join-Path $PSScriptRoot '../build/windows/x64/runner/Release'
    if (-not (Test-Path (Join-Path $bundle 'aijiance.exe'))) {
        throw 'Build the Windows release before preparing WebView2.'
    }
    Copy-Item $installer $bundle -Force
    Write-Host 'Verified Microsoft WebView2 bootstrapper bundled.'
}
