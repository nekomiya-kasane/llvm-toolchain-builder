#Requires -Version 7.0
# =============================================================================
# Verify Windows LLVM toolchain portability.
#
# This script validates that a built LLVM toolchain package can function
# correctly on a clean Windows machine (no Visual Studio required for usage).
# It checks binary execution, C/C++ compilation, linking, and runtime deps.
#
# Environment variables:
#   TOOLCHAIN_DIR — path to the unpacked toolchain directory
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TOOLCHAIN_DIR = if ($env:TOOLCHAIN_DIR) { $env:TOOLCHAIN_DIR } else { 'C:\coca-toolchain' }
$pass = 0
$fail = 0
$skip = 0

function Log($msg) {
    Write-Host "===> $msg" -ForegroundColor Cyan
}

function Test-ToolOutput {
    param([string]$Label, [string]$Exe, [string[]]$Arguments)

    try {
        $null = & $Exe @Arguments 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  PASS: $Label" -ForegroundColor Green
            $script:pass++
            return $true
        } else {
            Write-Host "  FAIL: $Label (exit code $LASTEXITCODE)" -ForegroundColor Red
            $script:fail++
            return $false
        }
    } catch {
        Write-Host "  FAIL: $Label (exception: $_)" -ForegroundColor Red
        $script:fail++
        return $false
    }
}

function Test-PathExists {
    param([string]$Label, [string]$FilePath)

    if (Test-Path $FilePath) {
        Write-Host "  PASS: $Label (exists)" -ForegroundColor Green
        $script:pass++
        return $true
    } else {
        Write-Host "  FAIL: $Label (missing: $FilePath)" -ForegroundColor Red
        $script:fail++
        return $false
    }
}

# ── 1. Binary execution tests ────────────────────────────────────────────────
function Test-BinaryExecution {
    Log "--- Binary execution tests ---"

    $binDir = Join-Path $TOOLCHAIN_DIR 'bin'

    $tools = @(
        @('clang --version',       'clang.exe',       '--version'),
        @('clang++ --version',     'clang++.exe',     '--version'),
        @('clang-cl --version',    'clang-cl.exe',    '--version'),
        @('lld-link --version',    'lld-link.exe',    '--version'),
        @('ld.lld --version',      'ld.lld.exe',      '--version'),
        @('llvm-ar --version',     'llvm-ar.exe',     '--version'),
        @('llvm-nm --version',     'llvm-nm.exe',     '--version'),
        @('llvm-objdump --version','llvm-objdump.exe','--version'),
        @('llvm-readelf --version','llvm-readelf.exe','--version'),
        @('llvm-strip --version',  'llvm-strip.exe',  '--version'),
        @('llvm-profdata --version','llvm-profdata.exe','--version'),
        @('llvm-cov --version',    'llvm-cov.exe',    '--version'),
        @('clang-format --version','clang-format.exe','--version'),
        @('clang-tidy --version',  'clang-tidy.exe',  '--version'),
        @('clangd --version',      'clangd.exe',      '--version'),
        @('lldb --version',        'lldb.exe',        '--version')
    )

    foreach ($t in $tools) {
        $exe = Join-Path $binDir $t[1]
        if (Test-Path $exe) {
            Test-ToolOutput -Label $t[0] -Exe $exe -Arguments @($t[2])
        } else {
            Write-Host "  SKIP: $($t[0]) (not installed)" -ForegroundColor Yellow
            $script:skip++
        }
    }

    # Optional tools (may not be in all variants)
    $optionalTools = @(
        @('flang --version',       'flang.exe',       '--version'),
        @('mlir-opt --version',    'mlir-opt.exe',    '--version'),
        @('mlir-translate --version','mlir-translate.exe','--version'),
        @('mlir-lsp-server --version','mlir-lsp-server.exe','--version')
    )

    foreach ($t in $optionalTools) {
        $exe = Join-Path $binDir $t[1]
        if (Test-Path $exe) {
            Test-ToolOutput -Label $t[0] -Exe $exe -Arguments @($t[2])
        } else {
            Write-Host "  SKIP: $($t[0]) (not in this variant)" -ForegroundColor Yellow
            $script:skip++
        }
    }
}

# ── 2. Compilation tests ─────────────────────────────────────────────────────
function Test-Compilation {
    Log "--- Compilation tests ---"

    $binDir = Join-Path $TOOLCHAIN_DIR 'bin'
    $clang = Join-Path $binDir 'clang.exe'
    $clangcl = Join-Path $binDir 'clang-cl.exe'

    # Add toolchain bin/ to PATH so lld-link.exe / ld.lld.exe are discoverable
    $env:PATH = "$binDir;$env:PATH"

    $tmpDir = Join-Path $env:TEMP 'llvm-verify'

    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    # 2a. C compilation (clang)
    $helloC = Join-Path $tmpDir 'hello.c'
    $helloExe = Join-Path $tmpDir 'hello.exe'
    @'
#include <stdio.h>
int main(void) {
    printf("Hello from COCA toolchain (C)\n");
    return 0;
}
'@ | Set-Content $helloC

    & $clang $helloC -o $helloExe --target=x86_64-pc-windows-msvc -fuse-ld=lld 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $helloExe)) {
        $out = & $helloExe 2>&1
        if ($out -match 'Hello from COCA') {
            Write-Host "  PASS: C compilation (clang)" -ForegroundColor Green
            $script:pass++
        } else {
            Write-Host "  FAIL: C compilation — output mismatch" -ForegroundColor Red
            $script:fail++
        }
    } else {
        Write-Host "  FAIL: C compilation (clang)" -ForegroundColor Red
        $script:fail++
    }

    # 2b. C++ compilation (clang++)
    $helloCpp = Join-Path $tmpDir 'hello.cpp'
    $helloCppExe = Join-Path $tmpDir 'hellocpp.exe'
    @'
#include <iostream>
#include <vector>
#include <algorithm>
#include <string>
int main() {
    std::vector<std::string> v = {"Hello", "from", "COCA", "toolchain", "(C++)"};
    std::sort(v.begin(), v.end());
    for (const auto& s : v) std::cout << s << " ";
    std::cout << std::endl;
    return 0;
}
'@ | Set-Content $helloCpp

    $clangpp = Join-Path $binDir 'clang++.exe'
    & $clangpp $helloCpp -o $helloCppExe --target=x86_64-pc-windows-msvc -fuse-ld=lld -std=c++20 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $helloCppExe)) {
        $out = & $helloCppExe 2>&1
        if ($out -match 'COCA') {
            Write-Host "  PASS: C++ compilation (clang++, C++20)" -ForegroundColor Green
            $script:pass++
        } else {
            Write-Host "  FAIL: C++ compilation — output mismatch" -ForegroundColor Red
            $script:fail++
        }
    } else {
        Write-Host "  FAIL: C++ compilation (clang++)" -ForegroundColor Red
        $script:fail++
    }

    # 2c. C++23 features
    $cpp23 = Join-Path $tmpDir 'cpp23.cpp'
    $cpp23Exe = Join-Path $tmpDir 'cpp23.exe'
    @'
#include <expected>
#include <print>
#include <ranges>
#include <string>
#include <vector>

std::expected<int, std::string> divide(int a, int b) {
    if (b == 0) return std::unexpected("division by zero");
    return a / b;
}

int main() {
    auto result = divide(42, 7);
    if (result) {
        std::println("C++23 std::expected: 42/7 = {}", *result);
    }

    std::vector<int> v = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10};
    auto even_squares = v
        | std::views::filter([](int n) { return n % 2 == 0; })
        | std::views::transform([](int n) { return n * n; });

    std::print("Even squares: ");
    for (auto x : even_squares) std::print("{} ", x);
    std::println("");

    return 0;
}
'@ | Set-Content $cpp23

    & $clangpp $cpp23 -o $cpp23Exe --target=x86_64-pc-windows-msvc -fuse-ld=lld -std=c++23 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $cpp23Exe)) {
        $out = & $cpp23Exe 2>&1
        if ($out -match 'C\+\+23 std::expected') {
            Write-Host "  PASS: C++23 features (std::expected, std::print, ranges)" -ForegroundColor Green
            $script:pass++
        } else {
            Write-Host "  FAIL: C++23 — output mismatch" -ForegroundColor Red
            $script:fail++
        }
    } else {
        Write-Host "  FAIL: C++23 compilation" -ForegroundColor Red
        $script:fail++
    }

    # 2d. clang-cl compilation (requires MSVC headers/libs from environment)
    # On a blank machine this will fail — that's expected. clang-cl always needs
    # a Windows SDK + MSVC sysroot. We test it here only if vcvarsall was run.
    if ($env:INCLUDE -and $env:LIB) {
        $clangclTest = Join-Path $tmpDir 'clangcl.cpp'
        $clangclExe = Join-Path $tmpDir 'clangcl.exe'
        @'
#include <stdio.h>
int main() {
    printf("Hello from clang-cl\n");
    return 0;
}
'@ | Set-Content $clangclTest

        & $clangcl /nologo $clangclTest "/Fe$clangclExe" /link /SUBSYSTEM:CONSOLE 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $clangclExe)) {
            Write-Host "  PASS: clang-cl compilation" -ForegroundColor Green
            $script:pass++
        } else {
            Write-Host "  FAIL: clang-cl compilation" -ForegroundColor Red
            $script:fail++
        }
    } else {
        Write-Host "  SKIP: clang-cl compilation (MSVC environment not set)" -ForegroundColor Yellow
        $script:skip++
    }

    # Cleanup
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ── 3. DLL dependency analysis ────────────────────────────────────────────────
function Test-DllDependencies {
    Log "--- DLL dependency analysis ---"

    $binDir = Join-Path $TOOLCHAIN_DIR 'bin'

    # Check that critical DLLs are not missing (dumpbin analysis)
    $dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
    if (-not $dumpbin) {
        Write-Host "  SKIP: DLL dependency analysis (dumpbin not available)" -ForegroundColor Yellow
        $script:skip++
        return
    }

    $criticalExes = @('clang.exe', 'lld-link.exe', 'lldb.exe', 'clangd.exe')
    foreach ($exe in $criticalExes) {
        $exePath = Join-Path $binDir $exe
        if (-not (Test-Path $exePath)) { continue }

        $deps = & dumpbin /dependents $exePath 2>&1 | Select-String '\.dll' | ForEach-Object { $_.Line.Trim() }
        $systemDlls = @('KERNEL32.dll', 'ADVAPI32.dll', 'SHELL32.dll', 'USER32.dll',
                        'ole32.dll', 'OLEAUT32.dll', 'WS2_32.dll', 'PSAPI.DLL',
                        'DBGHELP.DLL', 'ntdll.dll', 'VERSION.dll', 'RPCRT4.dll',
                        'api-ms-win-*', 'VCRUNTIME140.dll', 'VCRUNTIME140_1.dll',
                        'MSVCP140.dll', 'ucrtbase.dll')

        $nonSystemDeps = @()
        foreach ($dep in $deps) {
            $isSystem = $false
            foreach ($sysDll in $systemDlls) {
                if ($dep -like "*$sysDll*" -or $dep -match '^api-ms-win-') {
                    $isSystem = $true
                    break
                }
            }
            # Check if we bundle it
            if (-not $isSystem) {
                $bundled = Join-Path $binDir $dep
                if (-not (Test-Path $bundled)) {
                    $nonSystemDeps += $dep
                }
            }
        }

        if ($nonSystemDeps.Count -eq 0) {
            Write-Host "  PASS: $exe — all dependencies resolved" -ForegroundColor Green
            $script:pass++
        } else {
            Write-Host "  FAIL: $exe — missing dependencies: $($nonSystemDeps -join ', ')" -ForegroundColor Red
            $script:fail++
        }
    }
}

# ── 4. Runtime library presence ───────────────────────────────────────────────
function Test-RuntimeLibraries {
    Log "--- Runtime library checks ---"

    $libDir = Join-Path $TOOLCHAIN_DIR 'lib'
    $clangRtDir = Join-Path $libDir 'clang'

    # Check compiler-rt builtins
    $builtinsLib = Get-ChildItem -Path $clangRtDir -Recurse -Filter 'clang_rt.builtins*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($builtinsLib) {
        Write-Host "  PASS: compiler-rt builtins found ($($builtinsLib.Name))" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  FAIL: compiler-rt builtins not found" -ForegroundColor Red
        $script:fail++
    }

    # Check sanitizer libraries
    $asanLib = Get-ChildItem -Path $clangRtDir -Recurse -Filter '*asan*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($asanLib) {
        Write-Host "  PASS: ASan library found ($($asanLib.Name))" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  SKIP: ASan library not found (may not be built)" -ForegroundColor Yellow
        $script:skip++
    }

    # Check OpenMP runtime
    $ompDll = Join-Path $TOOLCHAIN_DIR 'bin\libomp.dll'
    if (Test-Path $ompDll) {
        Write-Host "  PASS: OpenMP runtime (libomp.dll)" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  SKIP: OpenMP runtime not found" -ForegroundColor Yellow
        $script:skip++
    }

    # Check flang-rt
    $flangRt = Get-ChildItem -Path $clangRtDir -Recurse -Filter 'flang_rt*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($flangRt) {
        Write-Host "  PASS: flang-rt found ($($flangRt.Name))" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  SKIP: flang-rt not found (may not be in this variant)" -ForegroundColor Yellow
        $script:skip++
    }
}

# ── 5. LLDB Python integration ───────────────────────────────────────────────
function Test-LLDBPython {
    Log "--- LLDB Python integration ---"

    $lldb = Join-Path $TOOLCHAIN_DIR 'bin\lldb.exe'
    if (-not (Test-Path $lldb)) {
        Write-Host "  SKIP: lldb.exe not found" -ForegroundColor Yellow
        $script:skip++
        return
    }

    # Check Python DLL presence
    $pyDlls = Get-ChildItem (Join-Path $TOOLCHAIN_DIR 'bin') -Filter 'python*.dll' -ErrorAction SilentlyContinue
    if ($pyDlls.Count -gt 0) {
        Write-Host "  PASS: Python DLLs found in bin/ ($($pyDlls.Name -join ', '))" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  SKIP: No Python DLLs in bin/ (Python bindings disabled)" -ForegroundColor Yellow
        $script:skip++
        return
    }

    # Check tools/python exists
    $pyToolsDir = Join-Path $TOOLCHAIN_DIR 'tools\python'
    if (Test-Path $pyToolsDir) {
        Write-Host "  PASS: tools/python directory exists" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  FAIL: tools/python directory missing" -ForegroundColor Red
        $script:fail++
    }
}

# ── 6. Toolchain layout consistency ──────────────────────────────────────────
function Test-ToolchainLayout {
    Log "--- Toolchain layout consistency ---"

    $expected = @(
        'bin',
        'lib',
        'lib\clang',
        'include',
        'share'
    )

    foreach ($dir in $expected) {
        $path = Join-Path $TOOLCHAIN_DIR $dir
        if (Test-Path $path) {
            Write-Host "  PASS: $dir/ exists" -ForegroundColor Green
            $script:pass++
        } else {
            Write-Host "  FAIL: $dir/ missing" -ForegroundColor Red
            $script:fail++
        }
    }

    # Count executables in bin/
    $exeCount = (Get-ChildItem (Join-Path $TOOLCHAIN_DIR 'bin') -Filter '*.exe' -ErrorAction SilentlyContinue).Count
    Log "  Found $exeCount executables in bin/"
    if ($exeCount -ge 50) {
        Write-Host "  PASS: bin/ has $exeCount executables (>= 50)" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  WARN: bin/ has only $exeCount executables (expected >= 50)" -ForegroundColor Yellow
    }
}

# ── Main ─────────────────────────────────────────────────────────────────────
function Main {
    Log "LLVM Windows toolchain portability verification"
    Log "TOOLCHAIN_DIR: $TOOLCHAIN_DIR"

    if (-not (Test-Path $TOOLCHAIN_DIR)) {
        Write-Host "ERROR: Toolchain directory not found: $TOOLCHAIN_DIR" -ForegroundColor Red
        exit 1
    }

    Test-BinaryExecution
    Test-Compilation
    Test-DllDependencies
    Test-RuntimeLibraries
    Test-LLDBPython
    Test-ToolchainLayout

    Log "==============================================="
    Log "Results: $pass passed, $fail failed, $skip skipped"
    Log "==============================================="

    if ($fail -gt 0) {
        Write-Host "VERIFICATION FAILED" -ForegroundColor Red
        exit 1
    } else {
        Write-Host "VERIFICATION PASSED" -ForegroundColor Green
        exit 0
    }
}

Main
