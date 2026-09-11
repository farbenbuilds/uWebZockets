param(
    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory
)

$ErrorActionPreference = "Stop"

$vcpkgRoot = $env:VCPKG_INSTALLATION_ROOT
if (!$vcpkgRoot) {
    throw "VCPKG_INSTALLATION_ROOT is not set"
}

$vcpkg = Join-Path $vcpkgRoot "vcpkg.exe"
$temporaryRoot = $env:RUNNER_TEMP
if (!$temporaryRoot) {
    $temporaryRoot = $env:TEMP
}
if (!$temporaryRoot) {
    throw "no temporary directory is configured"
}
$installRoot = Join-Path $temporaryRoot "uwebzockets-vcpkg"
git -C $vcpkgRoot fetch --depth=1 origin 2026.07.29

Push-Location $PSScriptRoot
try {
    & $vcpkg install --triplet x64-mingw-static `
        "--x-install-root=$installRoot"
    if ($LASTEXITCODE -ne 0) {
        throw "vcpkg failed to install MinGW zlib"
    }
} finally {
    Pop-Location
}

$targetRoot = Join-Path $installRoot "x64-mingw-static"
$zlibHeader = Join-Path $targetRoot "include\zlib.h"
$zconfHeader = Join-Path $targetRoot "include\zconf.h"
$zlibArchive = Join-Path $targetRoot "lib\libzs.a"
if (!(Test-Path $zlibHeader) -or !(Test-Path $zconfHeader)) {
    throw "vcpkg did not install the MinGW zlib headers"
}
if (!(Test-Path $zlibArchive)) {
    throw "vcpkg did not install the MinGW static zlib archive"
}

$includeDirectory = Join-Path $OutputDirectory "include"
$libraryDirectory = Join-Path $OutputDirectory "lib"
New-Item -ItemType Directory -Force -Path @(
    $includeDirectory
    $libraryDirectory
)
Copy-Item -Path @($zlibHeader, $zconfHeader) `
    -Destination $includeDirectory -Force
Copy-Item $zlibArchive (Join-Path $libraryDirectory "libz.a") -Force
