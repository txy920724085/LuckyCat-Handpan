param([string]$GowinShell='gw_sh.exe',[switch]$SynthesisOnly)
$ErrorActionPreference='Stop'
$taskTool=(Get-Command $GowinShell -ErrorAction Stop).Source
$taskRoot=$PSScriptRoot
$taskBuild=Join-Path $taskRoot 'project\build'
New-Item -ItemType Directory -Force -Path $taskBuild | Out-Null
Push-Location -LiteralPath $taskRoot
try {
    if($SynthesisOnly){$env:HANDPAN_SYNTH_ONLY='1'}else{Remove-Item Env:\HANDPAN_SYNTH_ONLY -ErrorAction SilentlyContinue}
    & $taskTool (Join-Path $taskRoot 'project\build_hdmi.tcl') 2>&1 | Tee-Object -FilePath (Join-Path $taskBuild 'build.log')
    if($LASTEXITCODE -ne 0){throw 'Gowin failed; inspect project/build/build.log'}
    if($SynthesisOnly){Write-Host 'Synthesis finished; firmware was not updated.';return}
    $taskPnr=Join-Path $taskBuild 'handpan_visual\impl\pnr'
    $taskReport=Get-Content -LiteralPath (Join-Path $taskPnr 'handpan_visual.tr') -Raw
    foreach($taskKind in @('Setup','Hold')){
        $taskMatch=[regex]::Match($taskReport,'<Numbers of '+$taskKind+' Violated Endpoints>:(\d+)')
        if(!$taskMatch.Success -or [int]$taskMatch.Groups[1].Value -ne 0){throw "$taskKind check failed"}
    }
    foreach($taskKind in @('Recovery','Removal')){
        $taskSection=[regex]::Match($taskReport,'(?ms)^3\.1\.\d '+$taskKind+' Paths Table\s*\n(.*?)(?=\n3\.)')
        $taskValues=[regex]::Matches($taskSection.Groups[1].Value,'(?m)^\s*\d+\s+(-?\d+\.\d+)\s')
        if(!$taskValues.Count){throw "Missing $taskKind timing paths"}
        foreach($taskValue in $taskValues){if([double]$taskValue.Groups[1].Value -lt 0){throw "$taskKind slack is negative"}}
    }
    $taskPulse=[regex]::Match($taskReport,'(?s)\n3\.2 Minimum Pulse Width Table\s*\n(.*?)\n3\.3')
    $taskWidths=[regex]::Matches($taskPulse.Groups[1].Value,'(?m)^\s*\d+\s+(-?\d+\.\d+)\s')
    if(!$taskWidths.Count){throw 'Missing pulse width report'}
    foreach($taskWidth in $taskWidths){if([double]$taskWidth.Groups[1].Value -lt 0){throw 'Pulse width slack is negative'}}
    $taskFirmware=Join-Path $taskRoot 'firmware\handpan_hdmi_visual_B.fs'
    Copy-Item -LiteralPath (Join-Path $taskPnr 'handpan_visual.fs') -Destination $taskFirmware -Force
    $taskHash=(Get-FileHash -LiteralPath $taskFirmware -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $taskRoot 'firmware\SHA256SUMS'),$taskHash+'  handpan_hdmi_visual_B.fs'+[Environment]::NewLine,[Text.Encoding]::ASCII)
    Write-Host 'Build and timing checks passed. Inspect the pin report before programming.'
} finally {Pop-Location;Remove-Item Env:\HANDPAN_SYNTH_ONLY -ErrorAction SilentlyContinue}
