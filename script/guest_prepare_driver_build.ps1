$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$resultPath='C:\AstraLab\driver-build-environment-result.json'
$result=[ordered]@{started_at=(Get-Date).ToString('o');status='preparing_source'}
function Save-Stage([string]$stage) {
    $result.status=$stage
    $result|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $resultPath -Encoding UTF8
}
try {
    $build='C:\AstraLab\DriverBuild'
    if(Test-Path -LiteralPath "$build\mesa-src"){throw 'Source directory already exists; inspect before reusing'}
    New-Item -ItemType Directory -Path $build -Force|Out-Null
    & 'C:\Windows\System32\tar.exe' -xzf 'C:\AstraLab\astra-neptune-candidate-source.tar.gz' -C $build
    if($LASTEXITCODE -ne 0){throw "Source extraction failed: $LASTEXITCODE"}
    Expand-Archive -LiteralPath 'C:\AstraLab\build-wheels.zip' -DestinationPath "$build\wheels"
    $manifest=Get-Content -LiteralPath 'C:\AstraLab\build-wheels-manifest.json' -Raw|ConvertFrom-Json
    foreach($entry in $manifest) {
        $file=Join-Path "$build\wheels" $entry.filename
        if((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.sha256){throw "Wheel hash mismatch: $($entry.filename)"}
    }
    Save-Stage 'waiting_for_cpp_installer'
    $deadline=(Get-Date).AddMinutes(40)
    while((Get-Date) -lt $deadline) {
        $vs=Get-Content -LiteralPath 'C:\AstraLab\driver-build-tools-install-result.json' -Raw|ConvertFrom-Json
        if($vs.status -eq 'failed'){throw "Compiler installation failed: $($vs.error)"}
        if($vs.status -eq 'complete'){break}
        Start-Sleep -Seconds 10
    }
    if($vs.status -ne 'complete'){throw 'Compiler installation did not finish within the bounded wait'}
    $result.compiler_reboot_required=$vs.reboot_required
    Save-Stage 'installing_python'
    $installer='C:\AstraLab\python-3.13.15-arm64.exe'
    $sig=Get-AuthenticodeSignature -LiteralPath $installer
    if($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Python Software Foundation'){throw 'Python signature verification failed'}
    if(Test-Path -LiteralPath 'C:\AstraLab\Python\python.exe'){throw 'Build Python already exists; inspect before replacement'}
    $args=@('/quiet','InstallAllUsers=1','TargetDir=C:\AstraLab\Python','Include_test=0',
        'Include_doc=0','Include_launcher=0','InstallLauncherAllUsers=0','Shortcuts=0',
        'PrependPath=0','AssociateFiles=0','Include_pip=1')
    $p=Start-Process -FilePath $installer -ArgumentList $args -Wait -PassThru
    $result.python_installer_exit=$p.ExitCode
    if($p.ExitCode -notin @(0,3010)){throw "Python installer failed: $($p.ExitCode)"}
    Save-Stage 'installing_offline_build_dependencies'
    & 'C:\AstraLab\Python\python.exe' -m pip install --no-index --find-links "$build\wheels" meson mako packaging PyYAML ninja
    if($LASTEXITCODE -ne 0){throw 'Offline build dependency installation failed'}
    $result.python_version=(& 'C:\AstraLab\Python\python.exe' -c 'import sys,platform;print(sys.version);print(platform.machine())') -join ' '
    $result.meson_version=(& 'C:\AstraLab\Python\python.exe' -m mesonbuild.mesonmain --version) -join ' '
    Save-Stage 'ready'
} catch {
    $result.error=$_.Exception.Message;Save-Stage 'failed'
} finally {
    $result.finished_at=(Get-Date).ToString('o')
    $result|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $resultPath -Encoding UTF8
    $result|ConvertTo-Json -Depth 5 -Compress
}
if($result.status -eq 'failed'){exit 1}
