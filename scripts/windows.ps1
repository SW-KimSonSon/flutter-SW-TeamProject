param(
    [ValidateSet('build', 'run')][string]$Action = 'build',
    [string]$FlutterPath = 'flutter'
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
# Flutter/MSBuild can corrupt Korean paths. A temporary drive exposes the same
# files through an ASCII path, without copying or modifying the project sources.
$drive = $null
foreach ($letter in 'Z','Y','X','W','V','U','T','S','R','Q','P') {
    if (!(Test-Path "${letter}:\")) { $drive = "${letter}:"; break }
}
if (!$drive) { throw 'No free temporary drive letter (P: through Z:).' }
$flutterCommand = (Get-Command $FlutterPath -ErrorAction Stop).Source
$projectParent = Split-Path $projectRoot
$projectName = Split-Path $projectRoot -Leaf
$mappedRoot = "$drive\$projectName"
& subst.exe $drive $projectParent
if ($LASTEXITCODE -ne 0) { throw 'Unable to create temporary project drive.' }
try {
    # Reconfigure a build copied from a different folder or temporary drive.
    $cache = Join-Path $projectRoot 'build\windows\x64\CMakeCache.txt'
    if (Test-Path -LiteralPath $cache) {
        $expected = "CMAKE_HOME_DIRECTORY:INTERNAL=$drive/$projectName/windows"
        if (!(Select-String -LiteralPath $cache -SimpleMatch $expected -Quiet)) {
            $source = [IO.Path]::GetFullPath((Join-Path $projectRoot 'build\windows'))
            $destination = [IO.Path]::GetFullPath((Join-Path $projectRoot ('.merge-backup\windows-' + [Guid]::NewGuid().ToString('N'))))
            $prefix = $projectRoot + [IO.Path]::DirectorySeparatorChar
            if (!$source.StartsWith($prefix) -or !$destination.StartsWith($prefix)) { throw 'Invalid build paths.' }
            New-Item -ItemType Directory -Force (Split-Path $destination) | Out-Null
            Move-Item -LiteralPath $source -Destination $destination
        }
    }
    Push-Location $mappedRoot
    try {
        & $flutterCommand pub get
        if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed.' }
        if ($Action -eq 'run') { & $flutterCommand run -d windows --no-pub }
        else { & $flutterCommand build windows --no-pub }
        if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows command failed.' }
    } finally { Pop-Location }
} finally {
    & subst.exe $drive /d
}
