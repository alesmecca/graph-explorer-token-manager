#requires -Version 7.4
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
& (Join-Path $PSHOME 'pwsh') -NoProfile -File (Join-Path $PSScriptRoot 'Test.ps1')
if ($LASTEXITCODE -ne 0) {throw 'Tests failed; package not built'}
$manifest=Import-PowerShellDataFile (Join-Path $root 'src/GraphExplorerToken/GraphExplorerToken.psd1')
$name='graph-explorer-token-manager-'+$manifest.ModuleVersion
$output=Join-Path $root 'artifacts'
$null=New-Item -ItemType Directory -Path $output -Force
$archive=Join-Path $output ($name+'.zip')
$files=@('README.md','LICENSE','SECURITY.md','CHANGELOG.md','CONTRIBUTING.md','Start-GraphExplorerTokenManager.cmd')
foreach ($folder in @('src','scripts','tests','docs','examples')) {
    $files+=Get-ChildItem -LiteralPath (Join-Path $root $folder) -File -Recurse | ForEach-Object { [IO.Path]::GetRelativePath($root,$_.FullName) }
}
if ($files | Where-Object { $_ -match '(?i)\.local\.|\.(?:log|pfx|pem|key|bin|lock|tmp)$|[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\.json$' }) {throw 'Local or sensitive file in package inputs'}
$stream=[IO.File]::Open($archive,[IO.FileMode]::Create)
$zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in $files | Sort-Object -Unique) {
        $entryName=($name+'/'+$file.Replace('\','/'))
        $null=[IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,(Join-Path $root $file),$entryName)
    }
} finally {$zip.Dispose();$stream.Dispose()}
$hash=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $name.zip" | Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS.txt') -Encoding utf8
Write-Host "Built $name.zip with SHA-256 checksum."
