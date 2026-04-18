#Requires -Version 7.0
# =============================================================================
# LLVM Windows Build — full self-hosted toolchain for distribution.
#
# Builds a portable LLVM toolchain on Windows using MSVC (cl.exe or clang-cl)
# as the bootstrap compiler. Produces a self-contained package that runs on
# any Windows 10/11 x64 machine without Visual Studio installed.
#
# Supports two variants:
#   VARIANT=main   — official LLVM release (all projects + runtimes)
#   VARIANT=p2996  — Bloomberg clang-p2996 fork (C++ reflection)
#
# Environment variables:
#   LLVM_VERSION   — LLVM version to build (default: 21.1.1)
#   VARIANT        — main or p2996 (default: main)
#   INSTALL_PREFIX — installation directory
#   NPROC          — parallel build jobs
#   PYTHON_DIR     — Python installation for LLDB bindings
#   SWIG_DIR       — SWIG installation directory
# =============================================================================
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Configuration ─────────────────────────────────────────────────────────────
$LLVM_VERSION   = if ($env:LLVM_VERSION)   { $env:LLVM_VERSION }   else { '21.1.1' }
$VARIANT        = if ($env:VARIANT)        { $env:VARIANT }        else { 'main' }
$INSTALL_PREFIX = if ($env:INSTALL_PREFIX)  { $env:INSTALL_PREFIX } else { 'C:\coca-toolchain' }
$NPROC          = if ($env:NPROC)          { [int]$env:NPROC }     else { $env:NUMBER_OF_PROCESSORS }
$LLVM_SRC       = if ($env:LLVM_SRC)       { $env:LLVM_SRC }      else { 'C:\llvm-src' }
$P2996_SRC      = if ($env:P2996_SRC)      { $env:P2996_SRC }     else { 'C:\llvm-p2996' }
$BUILD_DIR      = if ($env:BUILD_DIR)      { $env:BUILD_DIR }     else { 'C:\b' }  # Short path to avoid MAX_PATH
$PYTHON_DIR     = if ($env:PYTHON_DIR)     { $env:PYTHON_DIR }    else { '' }
$SWIG_DIR       = if ($env:SWIG_DIR)       { $env:SWIG_DIR }     else { '' }

function Log($msg) {
    Write-Host "===> $(Get-Date -Format 'HH:mm:ss') $msg" -ForegroundColor Cyan
}

function LogError($msg) {
    Write-Host "===> $(Get-Date -Format 'HH:mm:ss') ERROR: $msg" -ForegroundColor Red
}

# ── 0. Validate MSVC environment ─────────────────────────────────────────────
function Invoke-VsDevShell {
    Log "Setting up MSVC environment..."

    # Find vswhere to locate VS installation
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "vswhere.exe not found — Visual Studio is not installed"
    }

    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vsPath) {
        throw "No Visual Studio installation with C++ tools found"
    }

    Log "Found Visual Studio at: $vsPath"

    # Import VS environment into current PowerShell session
    $vcvarsall = Join-Path $vsPath "VC\Auxiliary\Build\vcvarsall.bat"
    if (-not (Test-Path $vcvarsall)) {
        throw "vcvarsall.bat not found at $vcvarsall"
    }

    # Execute vcvarsall.bat and capture environment variables
    $envBefore = @{}
    Get-ChildItem env: | ForEach-Object { $envBefore[$_.Name] = $_.Value }

    $tempFile = [System.IO.Path]::GetTempFileName()
    cmd /c "`"$vcvarsall`" x64 >nul 2>&1 && set > `"$tempFile`""

    Get-Content $tempFile | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') {
            $name = $matches[1]
            $value = $matches[2]
            if ($envBefore[$name] -ne $value) {
                Set-Item -Path "env:$name" -Value $value
            }
        }
    }
    Remove-Item $tempFile -ErrorAction SilentlyContinue

    # Verify critical tools
    $ml64 = Get-Command ml64.exe -ErrorAction SilentlyContinue
    if (-not $ml64) { throw "ml64.exe not found after vcvarsall.bat — MASM is required" }
    Log "ml64.exe: $($ml64.Source)"

    $rc = Get-Command rc.exe -ErrorAction SilentlyContinue
    if (-not $rc) { throw "rc.exe not found after vcvarsall.bat — Windows SDK RC is required" }
    Log "rc.exe: $($rc.Source)"

    # Detect MSVC version for log
    $clExe = Get-Command cl.exe -ErrorAction SilentlyContinue
    if ($clExe) { Log "cl.exe: $($clExe.Source)" }
}

# ── 1. Obtain source code ────────────────────────────────────────────────────
function Get-LLVMSource {
    switch ($VARIANT) {
        'main' {
            if (Test-Path (Join-Path $LLVM_SRC 'llvm')) {
                Log "Using existing LLVM source at $LLVM_SRC"
            } else {
                Log "Downloading LLVM $LLVM_VERSION source..."
                $tarball = "C:\llvm-project-$LLVM_VERSION.src.tar.xz"
                if (-not (Test-Path $tarball)) {
                    $url = "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVM_VERSION/llvm-project-$LLVM_VERSION.src.tar.xz"
                    Log "Downloading from $url"
                    Invoke-WebRequest -Uri $url -OutFile $tarball -UseBasicParsing -RetryIntervalSec 5 -MaximumRetryCount 3
                }
                New-Item -ItemType Directory -Path $LLVM_SRC -Force | Out-Null
                Log "Extracting LLVM source (this takes a while)..."
                & 7z x $tarball -so | & 7z x -aoa -si -ttar "-o$LLVM_SRC" -y
                # Move contents up from nested dir
                $nested = Get-ChildItem $LLVM_SRC -Directory | Where-Object { $_.Name -like 'llvm-project-*' } | Select-Object -First 1
                if ($nested) {
                    Get-ChildItem $nested.FullName | Move-Item -Destination $LLVM_SRC -Force
                    Remove-Item $nested.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            return $LLVM_SRC
        }
        'p2996' {
            if (Test-Path (Join-Path $P2996_SRC 'llvm')) {
                Log "Using existing p2996 source at $P2996_SRC"
            } else {
                Log "Cloning Bloomberg clang-p2996..."
                & git clone --depth 1 --branch p2996 "https://github.com/bloomberg/clang-p2996.git" $P2996_SRC
                if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
            }
            return $P2996_SRC
        }
        default {
            throw "Unknown variant '$VARIANT'. Use 'main' or 'p2996'."
        }
    }
}

# ── 2. Configure Python & SWIG for LLDB ─────────────────────────────────────
function Find-PythonForLLDB {
    if ($PYTHON_DIR -and (Test-Path (Join-Path $PYTHON_DIR 'python.exe'))) {
        return $PYTHON_DIR
    }
    # Try to find Python 3.14 from GitHub Actions cached tools
    $pyExe = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($pyExe) {
        $pyDir = Split-Path $pyExe.Source
        Log "Found Python at: $pyDir"
        return $pyDir
    }
    Log "WARNING: Python not found — LLDB Python bindings will be disabled"
    return $null
}

function Find-SWIG {
    if ($SWIG_DIR -and (Test-Path (Join-Path $SWIG_DIR 'swig.exe'))) {
        return (Join-Path $SWIG_DIR 'swig.exe')
    }
    $swigExe = Get-Command swig.exe -ErrorAction SilentlyContinue
    if ($swigExe) {
        Log "Found SWIG at: $($swigExe.Source)"
        return $swigExe.Source
    }
    Log "WARNING: SWIG not found — LLDB Python bindings will be disabled"
    return $null
}

# ── 3. Build LLVM ────────────────────────────────────────────────────────────
function Build-LLVM {
    param([string]$SourceDir)

    Log "Configuring LLVM (variant=$VARIANT)..."

    New-Item -ItemType Directory -Path $BUILD_DIR -Force | Out-Null

    # Projects and runtimes based on variant
    $projects = 'clang;lld;clang-tools-extra;lldb;mlir;polly'
    $runtimes = 'compiler-rt;flang-rt;openmp'
    $targets  = 'X86;AArch64;ARM;WebAssembly;RISCV;NVPTX;AMDGPU;BPF'

    if ($VARIANT -eq 'p2996') {
        $projects = 'clang;lld;clang-tools-extra;lldb'
        $runtimes = 'compiler-rt'
        $targets  = 'X86;AArch64;WebAssembly'
    }

    # Add flang for main variant
    if ($VARIANT -eq 'main') {
        $projects = "flang;$projects"
    }

    # Detect Python & SWIG for LLDB
    $pyDir = Find-PythonForLLDB
    $swigExe = Find-SWIG
    $enablePython = ($null -ne $pyDir) -and ($null -ne $swigExe)

    $cmakeArgs = @(
        '-G', 'Ninja',
        '-S', (Join-Path $SourceDir 'llvm'),
        '-B', $BUILD_DIR,
        "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_INSTALL_PREFIX=$INSTALL_PREFIX",
        # Use clang-cl from the runner's LLVM 20 if available, otherwise MSVC cl.exe
        "-DCMAKE_C_COMPILER=cl.exe",
        "-DCMAKE_CXX_COMPILER=cl.exe",
        "-DCMAKE_AR=lib.exe",
        "-DLLVM_USE_LINKER=lld",
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL",
        # Projects
        "-DLLVM_ENABLE_PROJECTS=$projects",
        "-DLLVM_ENABLE_RUNTIMES=$runtimes",
        "-DLLVM_TARGETS_TO_BUILD=$targets",
        # Feature flags
        '-DLLVM_INSTALL_UTILS=ON',
        '-DLLVM_ENABLE_ASSERTIONS=OFF',
        '-DLLVM_INCLUDE_TESTS=OFF',
        '-DLLVM_INCLUDE_BENCHMARKS=OFF',
        '-DLLVM_INCLUDE_EXAMPLES=OFF',
        '-DLLVM_INCLUDE_DOCS=OFF',
        '-DLLVM_ENABLE_BINDINGS=ON',
        '-DLLVM_INSTALL_TOOLCHAIN_ONLY=OFF',
        # Optional deps — OFF for maximum portability
        '-DLLVM_ENABLE_ZLIB=OFF',
        '-DLLVM_ENABLE_ZSTD=OFF',
        '-DLLVM_ENABLE_LIBXML2=OFF',
        '-DLLVM_ENABLE_TERMINFO=OFF',
        '-DLLVM_ENABLE_LIBEDIT=OFF',
        # DIA SDK requires atlbase.h which may not be available
        '-DLLVM_ENABLE_DIA_SDK=OFF',
        # Clang defaults — portable tools should not assume host's runtime
        '-DCLANG_ENABLE_STATIC_ANALYZER=ON',
        '-DCLANG_ENABLE_ARCMT=ON',
        # LLDB
        "-DLLDB_ENABLE_CURSES=OFF",
        "-DLLDB_ENABLE_LIBEDIT=OFF",
        "-DLLDB_ENABLE_LZMA=OFF",
        "-DLLDB_ENABLE_LIBXML2=OFF",
        "-DLLDB_ENABLE_LUA=OFF",
        "-DLLDB_ENABLE_FBSDVMCORE=OFF",
        # Polly — no GPU offload
        '-DPOLLY_ENABLE_GPGPU_CODEGEN=OFF',
        # compiler-rt — full suite on Windows
        '-DCOMPILER_RT_BUILD_SANITIZERS=ON',
        '-DCOMPILER_RT_BUILD_XRAY=OFF',  # XRay is Linux/macOS only
        '-DCOMPILER_RT_BUILD_LIBFUZZER=ON',
        '-DCOMPILER_RT_BUILD_PROFILE=ON',
        '-DCOMPILER_RT_BUILD_MEMPROF=OFF',  # MemProf is Linux-only
        '-DCOMPILER_RT_BUILD_ORC=ON',
        # OpenMP RTM fix (critical — see llvm-full-build-guide.md §5.3)
        '-DRUNTIMES_CMAKE_ARGS=-DLIBOMP_HAVE_RTM_INTRINSICS=TRUE;-DLIBOMP_HAVE_IMMINTRIN_H=TRUE;-DLIBOMP_HAVE_ATTRIBUTE_RTM=TRUE'
    )

    # LLDB Python bindings
    if ($enablePython) {
        $pyExe = Join-Path $pyDir 'python.exe'
        $pyVer = & $pyExe -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
        $pyVerMajMin = $pyVer.Trim()
        $pyInclude = & $pyExe -c "import sysconfig; print(sysconfig.get_path('include'))"
        $pyInclude = $pyInclude.Trim()
        $pyLibDir = & $pyExe -c "import sysconfig; print(sysconfig.get_config_var('installed_base'))"
        $pyLibDir = $pyLibDir.Trim()
        $pyLib = Join-Path $pyLibDir "libs\python$($pyVerMajMin.Replace('.',''))`.lib"
        $pyPureVer = $pyVerMajMin.Replace('.','')

        Log "LLDB Python: $pyExe (version $pyVerMajMin)"
        Log "LLDB Python include: $pyInclude"
        Log "LLDB Python lib: $pyLib"

        $cmakeArgs += @(
            '-DLLDB_ENABLE_PYTHON=ON',
            "-DPython3_EXECUTABLE=$pyExe",
            "-DPython3_INCLUDE_DIR=$pyInclude",
            "-DPython3_LIBRARY=$pyLib",
            "-DSWIG_EXECUTABLE=$swigExe",
            "-DLLDB_PYTHON_HOME=../tools/python",
            "-DLLDB_PYTHON_EXT_SUFFIX=.cp${pyPureVer}-win_amd64.pyd"
        )
    } else {
        $cmakeArgs += '-DLLDB_ENABLE_PYTHON=OFF'
    }

    # Configure
    Log "Running cmake configure with $($cmakeArgs.Count) arguments..."
    & cmake @cmakeArgs
    if ($LASTEXITCODE -ne 0) { throw "CMake configure failed with exit code $LASTEXITCODE" }

    # Build
    Log "Building LLVM (this will take a long time, -j$NPROC)..."
    & cmake --build $BUILD_DIR -- "-j$NPROC"
    if ($LASTEXITCODE -ne 0) { throw "CMake build failed with exit code $LASTEXITCODE" }

    # Install
    Log "Installing LLVM to $INSTALL_PREFIX..."
    & cmake --install $BUILD_DIR
    if ($LASTEXITCODE -ne 0) { throw "CMake install failed with exit code $LASTEXITCODE" }

    Log "Build and install complete"
}

# ── 4. Post-install: bundle dependencies for portability ─────────────────────
function Invoke-PostInstall {
    Log "Post-install: bundling dependencies for portability..."

    $binDir = Join-Path $INSTALL_PREFIX 'bin'

    # 4a. Bundle MSVC Runtime DLLs (vcruntime140.dll, msvcp140.dll, etc.)
    # These are required when building with /MD (dynamic CRT).
    # On a blank machine without VS Redistributable, these must be present.
    $vcRedistDlls = @(
        'vcruntime140.dll',
        'vcruntime140_1.dll',
        'msvcp140.dll',
        'msvcp140_1.dll',
        'msvcp140_2.dll',
        'concrt140.dll',
        'vccorlib140.dll'
    )

    # Find the VC redist directory
    $vcToolsRedist = $env:VCToolsRedistDir
    if ($vcToolsRedist) {
        $redistX64 = Join-Path $vcToolsRedist 'x64\Microsoft.VC143.CRT'
        if (-not (Test-Path $redistX64)) {
            # Try VC142
            $redistX64 = Join-Path $vcToolsRedist 'x64\Microsoft.VC142.CRT'
        }
        if (Test-Path $redistX64) {
            foreach ($dll in $vcRedistDlls) {
                $src = Join-Path $redistX64 $dll
                if (Test-Path $src) {
                    Copy-Item $src -Destination $binDir -Force
                    Log "  Bundled: $dll"
                }
            }
        } else {
            Log "WARNING: VC redist directory not found at $redistX64"
        }
    } else {
        Log "WARNING: VCToolsRedistDir not set — VC runtime DLLs not bundled"
    }

    # 4b. Bundle Universal CRT DLLs (ucrtbase.dll) — usually present on Win10+
    # but for Win10 LTSC/IoT, it's safer to bundle them.
    $ucrtDlls = @('ucrtbase.dll')
    $winSdkBin = "${env:WindowsSdkVerBinPath}x64\ucrt"
    if (-not (Test-Path $winSdkBin)) {
        $winSdkBin = "C:\Windows\System32"
    }
    foreach ($dll in $ucrtDlls) {
        $src = Join-Path $winSdkBin $dll
        if (Test-Path $src) {
            Copy-Item $src -Destination $binDir -Force
            Log "  Bundled: $dll (UCRT)"
        }
    }

    # 4c. Bundle Python for LLDB (if enabled)
    $pyDir = Find-PythonForLLDB
    if ($pyDir) {
        Log "Bundling Python for LLDB..."
        $pyDest = Join-Path $INSTALL_PREFIX 'tools\python'
        New-Item -ItemType Directory -Path $pyDest -Force | Out-Null

        # Copy Python installation (trimmed)
        $pyExe = Join-Path $pyDir 'python.exe'
        $pyVer = & $pyExe -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
        $pyVerMajMin = $pyVer.Trim()
        $pyPureVer = $pyVerMajMin.Replace('.','')

        # Copy core files
        Copy-Item (Join-Path $pyDir 'python.exe') -Destination $pyDest -Force
        Copy-Item (Join-Path $pyDir 'pythonw.exe') -Destination $pyDest -Force -ErrorAction SilentlyContinue
        Copy-Item (Join-Path $pyDir "python${pyPureVer}.dll") -Destination $pyDest -Force
        Copy-Item (Join-Path $pyDir 'python3.dll') -Destination $pyDest -Force -ErrorAction SilentlyContinue

        # Also copy python DLLs to bin/ for liblldb.dll
        Copy-Item (Join-Path $pyDir "python${pyPureVer}.dll") -Destination $binDir -Force
        Copy-Item (Join-Path $pyDir 'python3.dll') -Destination $binDir -Force -ErrorAction SilentlyContinue

        # Copy standard library
        $pyLibSrc = Join-Path $pyDir 'Lib'
        if (Test-Path $pyLibSrc) {
            $pyLibDest = Join-Path $pyDest 'Lib'
            Copy-Item $pyLibSrc -Destination $pyLibDest -Recurse -Force

            # Remove unnecessary directories to save space
            $removeDirs = @('test', 'unittest\test', 'lib2to3\tests', 'tkinter',
                            'turtledemo', 'idlelib', 'ensurepip\_bundled', '__pycache__')
            foreach ($d in $removeDirs) {
                $path = Join-Path $pyLibDest $d
                if (Test-Path $path) {
                    Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # Copy DLLs directory (compiled C extensions)
        $pyDllsSrc = Join-Path $pyDir 'DLLs'
        if (Test-Path $pyDllsSrc) {
            Copy-Item $pyDllsSrc -Destination (Join-Path $pyDest 'DLLs') -Recurse -Force
        }

        Log "Python bundled to $pyDest"
    }

    Log "Post-install complete"
}

# ── 5. Create archive ────────────────────────────────────────────────────────
function New-Archive {
    $archiveName = switch ($VARIANT) {
        'main'  { 'coca-toolchain-win-x86_64' }
        'p2996' { 'coca-toolchain-p2996-win-x86_64' }
    }

    $archivePath = "C:\$archiveName.zip"
    Log "Creating archive: $archivePath"

    # Rename install dir to match archive name so the zip root has a good name.
    # Rename-Item takes a leaf-name, not a full path.
    $archiveDir = "C:\$archiveName"
    $renamed = $false
    if ($INSTALL_PREFIX -ne $archiveDir) {
        if (Test-Path $archiveDir) {
            Remove-Item $archiveDir -Recurse -Force
        }
        Rename-Item -Path $INSTALL_PREFIX -NewName $archiveName
        $renamed = $true
    }

    # Use 7z for compression — Compress-Archive has a 2 GB limit and is slow.
    # 7z is pre-installed on GitHub Actions Windows runners.
    $sevenZip = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($sevenZip) {
        if (Test-Path $archivePath) { Remove-Item $archivePath -Force }
        # Run from parent dir so zip root entry is just the dir name, not the full path
        $parentDir = Split-Path $archiveDir -Parent
        $leafName = Split-Path $archiveDir -Leaf
        Push-Location $parentDir
        try {
            & 7z a -tzip -mx=5 -mmt=on $archivePath ".\$leafName" | Select-Object -Last 5
            if ($LASTEXITCODE -ne 0) { throw "7z archive creation failed" }
        } finally {
            Pop-Location
        }
    } else {
        Log "WARNING: 7z not found, falling back to Compress-Archive (slow, 2GB limit)"
        Compress-Archive -Path $archiveDir -DestinationPath $archivePath -Force -CompressionLevel Optimal
    }

    # Restore original name
    if ($renamed) {
        Rename-Item -Path $archiveDir -NewName (Split-Path $INSTALL_PREFIX -Leaf)
    }

    Log "Archive created: $archivePath"
    $size = (Get-Item $archivePath).Length / 1MB
    Log "Archive size: $([math]::Round($size, 1)) MB"
}

# ── Main ─────────────────────────────────────────────────────────────────────
function Main {
    Log "LLVM Windows build starting"
    Log "  VARIANT:          $VARIANT"
    Log "  LLVM_VERSION:     $LLVM_VERSION"
    Log "  INSTALL_PREFIX:   $INSTALL_PREFIX"
    Log "  BUILD_DIR:        $BUILD_DIR"
    Log "  NPROC:            $NPROC"

    # Step 0: Setup MSVC environment
    Invoke-VsDevShell

    # Step 1: Get source
    $sourceDir = Get-LLVMSource
    Log "Source directory: $sourceDir"

    # Step 2: Build
    Build-LLVM -SourceDir $sourceDir

    # Step 3: Post-install
    Invoke-PostInstall

    # Step 4: Create archive
    New-Archive

    # Step 5: Quick verification
    Log "Quick verification:"
    $clang = Join-Path $INSTALL_PREFIX 'bin\clang.exe'
    if (Test-Path $clang) {
        & $clang --version
    }
    $lld = Join-Path $INSTALL_PREFIX 'bin\lld-link.exe'
    if (Test-Path $lld) {
        & $lld --version 2>&1 | Select-Object -First 1
    }
    $lldb = Join-Path $INSTALL_PREFIX 'bin\lldb.exe'
    if (Test-Path $lldb) {
        & $lldb --version
    }

    Log "LLVM Windows build complete!"
}

Main
