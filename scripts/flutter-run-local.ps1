param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $FlutterArgs
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $repoRoot '.env'
$tempPath = Join-Path $repoRoot '.env.build.json'

if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
    throw 'Missing .env. Copy .env.example to .env and set the client-safe values locally.'
}

$settings = @{}
foreach ($line in [IO.File]::ReadAllLines($envPath)) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
    $separator = $trimmed.IndexOf('=')
    if ($separator -lt 1) { throw 'Invalid .env line; expected NAME=value.' }
    $name = $trimmed.Substring(0, $separator).Trim()
    $value = $trimmed.Substring($separator + 1).Trim().Trim('"').Trim("'")
    if ($name -notin @('SUPABASE_URL', 'SUPABASE_PUBLISHABLE_KEY')) {
        throw "Unsupported .env setting '$name'. Only client-safe Supabase settings are allowed."
    }
    $settings[$name] = $value
}

foreach ($required in @('SUPABASE_URL', 'SUPABASE_PUBLISHABLE_KEY')) {
    if (-not $settings.ContainsKey($required) -or [string]::IsNullOrWhiteSpace($settings[$required])) {
        throw "Missing required local setting: $required"
    }
}

$json = $settings | ConvertTo-Json -Compress
$utf8NoBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($tempPath, $json, $utf8NoBom)
try {
    Push-Location $repoRoot
    try {
        & flutter run "--dart-define-from-file=$tempPath" @FlutterArgs
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    finally {
        Pop-Location
    }
}
finally {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
}
