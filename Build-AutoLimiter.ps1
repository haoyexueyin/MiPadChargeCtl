param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "x64\Release")
)

$ErrorActionPreference = "Stop"
$compiler = Join-Path $env:SystemRoot "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$source = Join-Path $PSScriptRoot "ChargeLimiterService.cs"
$output = Join-Path $OutputDirectory "MiPadChargeLimiter.exe"

if (-not (Test-Path -LiteralPath $compiler)) {
    throw ".NET Framework x64 C# compiler was not found."
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

& $compiler `
    /nologo `
    /target:exe `
    /platform:x64 `
    /optimize+ `
    /warn:4 `
    /warnaserror+ `
    /reference:System.Management.dll `
    /reference:System.ServiceProcess.dll `
    "/out:$output" `
    $source

if ($LASTEXITCODE -ne 0) {
    throw "Charge limiter build failed with exit code $LASTEXITCODE."
}

& $output --self-test
if ($LASTEXITCODE -ne 0) {
    throw "Charge limiter self-tests failed with exit code $LASTEXITCODE."
}

Write-Host "Charge limiter build and self-tests succeeded: $output"
