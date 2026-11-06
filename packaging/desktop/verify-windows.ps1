param([Parameter(Mandatory = $true)][string]$FileList)
$ErrorActionPreference = 'Stop'
$files = Get-Content -LiteralPath $FileList -Raw | ConvertFrom-Json
foreach ($file in $files) {
    $signature = Get-AuthenticodeSignature -LiteralPath $file
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or -not $signature.TimeStamperCertificate) {
        throw "A trusted, timestamped Authenticode signature is required: $file ($($signature.Status))"
    }
}
Write-Output "Verified trusted, timestamped signatures on $($files.Count) Windows binaries."
