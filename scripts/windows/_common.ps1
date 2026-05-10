Set-StrictMode -Version Latest

function Resolve-CMakePath {
  $cmd = Get-Command cmake -ErrorAction SilentlyContinue
  if ($cmd -ne $null) {
    return $cmd.Source
  }

  $candidates = @(
    "E:\DevSoftWare\VisualStudio2026\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
    "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
    "D:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
    "D:\Program Files\Microsoft Visual Studio\17\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
  )

  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) {
      return $candidate
    }
  }

  throw "cmake not found. Install CMake or Visual Studio CMake workload first."
}
