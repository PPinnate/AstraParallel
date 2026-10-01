# Source for the double-click installer. The media builder encodes this fixed
# script into its CMD launcher; no Windows execution policy is changed.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = $env:ASTRA_TOOLS_ROOT
$checkOnly = $env:ASTRA_TOOLS_CHECK_ONLY -eq '1'
if (!$root -or !(Test-Path -LiteralPath (Join-Path $root 'payload-manifest.json'))) {
    throw 'Open the installer from the Astra Guest Tools disc.'
}
$manifest = Get-Content -LiteralPath (Join-Path $root 'payload-manifest.json') -Raw | ConvertFrom-Json
if ($manifest.schema -ne 1 -or $manifest.graphics_build -ne 'resource-convert-v1') { throw 'Unsupported tools package.' }
$base = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
foreach ($entry in $manifest.files) {
    $file = [IO.Path]::GetFullPath((Join-Path $base $entry.path))
    if (!$file.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid package path.' }
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256) {
        throw ('Package verification failed: ' + $entry.path)
    }
}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'Drivers') -Recurse -File | Where-Object { $_.Extension -in @('.cat', '.sys') }) {
    if ((Get-AuthenticodeSignature -LiteralPath $file.FullName).Status -ne 'Valid') { throw ('Driver signature is not trusted: ' + $file.Name) }
}
$adapter = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -like 'PCI\VEN_1AF4&DEV_1050*' })
if ($adapter.Count -ne 1) { throw 'This installer requires Astra''s VirtIO graphics device.' }
if ($checkOnly) {
    [pscustomobject]@{result='PASS';mode='validation_only';files=$manifest.files.Count;driver_signatures='Valid';graphics_build=$manifest.graphics_build;settings_changed=$false} | ConvertTo-Json -Compress
    exit 0
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (!$admin) {
    $launcher = Join-Path $root 'Install Astra Tools.cmd'
    $arguments = '/d /c ""' + $launcher + '" --elevated"'
    $process = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\cmd.exe') -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    exit $process.ExitCode
}
if (Get-Process -Name GenshinImpact,HYP,HoYoPlay -ErrorAction SilentlyContinue) {
    throw 'Close games and launchers before installing the display driver.'
}
Write-Host 'Verified Astra Guest Tools. Installing signed device drivers...'
foreach ($relative in @('Drivers\Network\netkvm.inf','Drivers\Serial\vioser.inf','Drivers\Display\viogpu3d.inf')) {
    & "$env:WINDIR\System32\pnputil.exe" /add-driver (Join-Path $root $relative) /install
    if ($LASTEXITCODE -notin @(0,3010)) { throw ('Device driver installation failed: ' + $relative + ', exit ' + $LASTEXITCODE) }
}
$destination = Join-Path $env:ProgramFiles 'Astra Guest Tools'
New-Item -ItemType Directory -Path $destination -Force | Out-Null
foreach ($part in @('Agents','AstraGraphics')) {
    foreach ($entry in $manifest.files | Where-Object { $_.path.StartsWith($part + '/') }) {
        $target = Join-Path $destination $entry.path
        New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
        if (Test-Path -LiteralPath $target) {
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256) {
                throw ('A different tools version is present: ' + $target)
            }
        } else { Copy-Item -LiteralPath (Join-Path $root $entry.path) -Destination $target }
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256) { throw 'Installed file verification failed.' }
    }
}
# Discover the adapter's class key; never assume a particular 0000/0001 slot.
$adapter = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -like 'PCI\VEN_1AF4&DEV_1050*' })
$driverKey = (Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Enum\' + $adapter[0].PNPDeviceID)).Driver
if ($driverKey -notmatch '^\{4d36e968-e325-11ce-bfc1-08002be10318\}\\\d{4}$') { throw 'Restart Windows, then run Astra Guest Tools again to finish graphics setup.' }
$key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Class\' + $driverKey, $true)
try {
    if ($key.GetValue('DriverDesc') -ne 'Red Hat VirtIO GPU 3D controller') { throw 'Restart Windows, then run Astra Guest Tools again to finish installing the display driver.' }
    $before = @($key.GetValue('UserModeDriverName'))
    if ($before.Count -ne 4) { throw 'Unexpected graphics driver registration.' }
    $package = Join-Path $destination 'AstraGraphics\resource-convert-v1\neptune_umd.dll'
    $wanted = [string[]]@($package,$package,$package,$package)
    $recordFolder = Join-Path $env:ProgramData 'Astra Parallel\Install'
    New-Item -ItemType Directory -Path $recordFolder -Force | Out-Null
    if (!(Test-Path -LiteralPath (Join-Path $recordFolder 'previous-graphics.json'))) {
        @{key=$driverKey;values=$before} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $recordFolder 'previous-graphics.json') -Encoding UTF8
    }
    try {
        $key.SetValue('UserModeDriverName',$wanted,[Microsoft.Win32.RegistryValueKind]::MultiString)
        if ((@($key.GetValue('UserModeDriverName')) -join "`n") -cne ($wanted -join "`n")) { throw 'Graphics registration readback failed.' }
    } catch { $key.SetValue('UserModeDriverName',[string[]]$before,[Microsoft.Win32.RegistryValueKind]::MultiString); throw }
} finally { if ($key) { $key.Dispose() } }
if (!(Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue)) {
    & (Join-Path $destination 'Agents\Qemu-ga\qemu-ga.exe') -s install --retry-path
    if ($LASTEXITCODE -ne 0) { throw 'Guest control service installation failed.' }
}
if (!(Get-Service -Name 'vdservice' -ErrorAction SilentlyContinue)) {
    & (Join-Path $destination 'Agents\Spice\vdservice.exe') install
    if ($LASTEXITCODE -ne 0) { throw 'Display integration service installation failed.' }
}
Start-Service 'QEMU-GA' -ErrorAction SilentlyContinue
Start-Service 'vdservice' -ErrorAction SilentlyContinue
@{result='installed_restart_required';graphics_build='resource-convert-v1';security_policy_changed=$false;game_files_changed=$false} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $recordFolder 'result.json') -Encoding UTF8
Write-Host ''
Write-Host 'Astra Guest Tools installed. Restart Windows to activate the graphics driver.' -ForegroundColor Green
