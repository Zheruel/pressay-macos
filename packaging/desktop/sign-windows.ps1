param([Parameter(Mandatory = $true)][string]$Binary)
$ErrorActionPreference = 'Stop'
foreach ($name in @('PRESSAY_AZURE_SIGNING_ENDPOINT', 'PRESSAY_AZURE_SIGNING_ACCOUNT', 'PRESSAY_AZURE_CERTIFICATE_PROFILE')) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { throw "Missing $name" }
}
# Installed by the pinned official Azure action before Tauri bundles the app.
# Tauri invokes this for its main executable, NSIS uninstaller and installer.
Import-Module ArtifactSigning -RequiredVersion 0.1.8 -ErrorAction Stop
Invoke-ArtifactSigning -Endpoint $env:PRESSAY_AZURE_SIGNING_ENDPOINT `
    -CodeSigningAccountName $env:PRESSAY_AZURE_SIGNING_ACCOUNT `
    -CertificateProfileName $env:PRESSAY_AZURE_CERTIFICATE_PROFILE `
    -Files (Resolve-Path -LiteralPath $Binary).Path -FileDigest SHA256 `
    -TimestampRfc3161 'http://timestamp.acs.microsoft.com' -TimestampDigest SHA256 `
    -ExcludeInteractiveBrowserCredential $true
$signature = Get-AuthenticodeSignature -LiteralPath $Binary
if ($signature.Status -ne 'Valid' -or -not $signature.TimeStamperCertificate) {
    throw "Trusted timestamped Authenticode signature was not produced: $Binary"
}
