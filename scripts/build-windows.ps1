param([switch]$Bundle, [switch]$Test)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$env:Path = $env:Path + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = if (Test-Path $vswhere) { & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath } elseif (Test-Path 'C:\BuildTools\VC\Auxiliary\Build\vcvars64.bat') { 'C:\BuildTools' } else { $env:VSINSTALLDIR }
if (!$vs) { throw 'Install Visual Studio C++ Build Tools and Windows SDK first.' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
& cmd.exe /d /c "call `"$vcvars`" >nul && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') }
}
if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize the MSVC environment.' }
$clang = Join-Path $vs 'VC\Tools\Llvm\x64\bin'
if (Test-Path (Join-Path $clang 'libclang.dll')) { $env:LIBCLANG_PATH = $clang }
$cmake = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin'
if (Test-Path $cmake) { $env:Path = "$cmake;$env:Path" }
foreach ($tool in @('cargo', 'node', 'npm.cmd', 'perl', 'cmake', 'cl')) {
    if (!(Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Missing development tool: $tool" }
}
if ($Bundle -and !$env:TAURI_SIGNING_PRIVATE_KEY) { throw 'TAURI_SIGNING_PRIVATE_KEY is required for signed Windows installers.' }
Push-Location (Join-Path $root 'orbit-windows')
try {
    & npm.cmd ci
    if ($LASTEXITCODE -ne 0) { throw 'npm ci failed.' }
    if ($Test) {
        & cargo test --locked --release --target-dir src-tauri/target --manifest-path ../orbit-rs/Cargo.toml --lib
        if ($LASTEXITCODE -ne 0) { throw 'Rust tests failed.' }
    }
    & cargo build --locked --release --manifest-path src-tauri/Cargo.toml --bin orbit-cli
    if ($LASTEXITCODE -ne 0) { throw 'Windows CLI build failed.' }
    if ($Bundle) { & npm.cmd run tauri -- build --config src-tauri/bundle.windows.json -- --locked } else { & npm.cmd run tauri -- build --no-bundle -- --locked }
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
} finally { Pop-Location }
