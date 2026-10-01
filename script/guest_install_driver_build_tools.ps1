$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$resultPath='C:\AstraLab\driver-build-tools-install-result.json'
$result=[ordered]@{started_at=(Get-Date).ToString('o');status='starting';install_path='C:\AstraLab\BuildTools'}
try {
    $bootstrap='C:\AstraLab\vs_buildtools.exe'
    $signature=Get-AuthenticodeSignature -LiteralPath $bootstrap
    if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw 'Microsoft bootstrapper signature verification failed'
    }
    if(Test-Path -LiteralPath 'C:\AstraLab\BuildTools\Common7\Tools\VsDevCmd.bat') {
        throw 'BuildTools already exists; inspect it before modifying an existing installation'
    }
    $arguments=@('--quiet','--wait','--norestart','--nocache',
        '--installPath','C:\AstraLab\BuildTools','--addProductLang','en-US',
        '--add','Microsoft.VisualStudio.Workload.VCTools',
        '--add','Microsoft.VisualStudio.Component.VC.Tools.ARM64',
        '--add','Microsoft.VisualStudio.Component.VC.Tools.ARM64EC',
        '--add','Microsoft.VisualStudio.Component.Windows11SDK.26100')
    $result.status='installing'
    $result.arguments=$arguments
    $result|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $resultPath -Encoding UTF8
    $process=Start-Process -FilePath $bootstrap -ArgumentList $arguments -PassThru -Wait
    $result.exit_code=$process.ExitCode
    $result.reboot_required=($process.ExitCode -eq 3010)
    if($process.ExitCode -notin @(0,3010)){throw "Build Tools installer exit code $($process.ExitCode)"}
    if(!(Test-Path -LiteralPath 'C:\AstraLab\BuildTools\Common7\Tools\VsDevCmd.bat')) {
        throw 'Installer returned but the build environment is missing'
    }
    $result.status='complete'
} catch {
    $result.status='failed';$result.error=$_.Exception.Message
} finally {
    $result.finished_at=(Get-Date).ToString('o')
    $result|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $resultPath -Encoding UTF8
    $result|ConvertTo-Json -Depth 4 -Compress
}
if($result.status -eq 'failed'){exit 1}
