param(
    [string]$VivadoHome = 'E:\Vivado\2018.3',
    [string]$GccBin = "$env:LOCALAPPDATA\CodexFPGA\tools\xpack-riscv-none-elf-gcc-15.2.0-1\bin",
    [switch]$PrepareOnly,
    [switch]$ProjectOnly,
    [switch]$SynthesisOnly,
    [switch]$FullMemoryTest
)

$ErrorActionPreference = 'Stop'
$prepareArgs = @((Join-Path $PSScriptRoot 'tools\prepare.py'), '--gcc-bin', $GccBin)
if ($FullMemoryTest) { $prepareArgs += '--full-memory-test' }
& python @prepareArgs
if ($LASTEXITCODE -ne 0) { throw 'Project preparation failed' }
if ($PrepareOnly) { return }
$variant = if ($FullMemoryTest) { 'vision_full_memory' } else { 'vision' }
$outputDir = Join-Path $PSScriptRoot "build\$variant"
$vivado = Join-Path $VivadoHome 'bin\vivado.bat'
if (!(Test-Path -LiteralPath $vivado)) { throw "Vivado not found: $vivado" }
$mode = if ($ProjectOnly) { 'project' } elseif ($SynthesisOnly) { 'synth' } else { 'bitstream' }
Push-Location $outputDir
try {
    & $vivado -mode batch -nojournal -log (Join-Path $outputDir 'vivado.log') -source (Join-Path $PSScriptRoot 'build.tcl') -tclargs $mode $outputDir
    if ($LASTEXITCODE -ne 0) { throw 'Vivado failed; inspect build output and reports' }
} finally { Pop-Location }
if ($mode -eq 'bitstream') {
    & python (Join-Path $PSScriptRoot 'tools\summarize.py') $outputDir
    if ($LASTEXITCODE -ne 0) { throw 'Build summary generation failed' }
}
