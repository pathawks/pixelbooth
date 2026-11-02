param(
    [ValidateRange(8, 240)] [int] $Frames = 60,
    [string] $Root = (Join-Path $env:LOCALAPPDATA 'PixelBooth\UvcProbes')
)

$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'USBPcap capture requires an elevated PowerShell window. No capture was started.'
}

$usbPcap = Join-Path $env:ProgramFiles 'USBPcap\USBPcapCMD.exe'
$dotnet = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$testProject = Join-Path $repo 'Windows\PixelBooth.Tests\PixelBooth.Tests.csproj'
$testExe = Join-Path $repo 'Windows\PixelBooth.Tests\bin\Debug\net10.0-windows10.0.19041.0\PixelBooth.Tests.exe'
if (-not (Test-Path -LiteralPath $usbPcap)) { throw "USBPcapCMD was not found at $usbPcap." }
if (-not (Test-Path -LiteralPath $dotnet)) { throw "The .NET SDK was not found at $dotnet." }

# Locate the physical BRIO device, not every device on its USB root hub.
$deviceCandidates = @()
foreach ($line in (& $usbPcap --extcap-interfaces | ForEach-Object { $_ })) {
    if ($line -match '^interface \{value=(?<path>[^}]+)\}') { $interface = $Matches.path }
    else { continue }
    foreach ($item in (& $usbPcap --extcap-interface $interface --extcap-config | ForEach-Object { $_ })) {
        if ($item -match '^value \{arg=99\}\{value=(?<address>\d+)_\d+\}\{display=Logitech BRIO\}') {
            $deviceCandidates += [PSCustomObject]@{ Interface = $interface; Address = [int]$Matches.address }
        }
    }
}
$deviceCandidates = @($deviceCandidates | Sort-Object Interface, Address -Unique)
if ($deviceCandidates.Count -ne 1) { throw "Expected one BRIO USB device; found $($deviceCandidates.Count). Reconnect it and retry." }
$target = $deviceCandidates[0]

& $dotnet build $testProject -c Debug --no-restore
if ($LASTEXITCODE -ne 0) { throw 'The reference probe did not build; no capture was started.' }

$directory = Join-Path $Root ('brio-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $directory)
$pcapPath = Join-Path $directory 'brio-usb.pcap'
$referencePath = Join-Path $directory 'media-foundation-hashes.txt'
$logPath = Join-Path $directory 'capture-log.txt'
Write-Output "Capturing BRIO USB device $($target.Address) on $($target.Interface)."
Write-Output 'This device-level capture may include BRIO microphone and other interface traffic. Close other apps using the BRIO first.'
Write-Output "Output directory: $directory"

$usbStart = [Diagnostics.ProcessStartInfo]::new()
$usbStart.FileName = $usbPcap
$usbStart.Arguments = '-d "{0}" --devices {1} --inject-descriptors -s 16777216 -b 67108864 -o "{2}"' -f $target.Interface, $target.Address, $pcapPath
$usbStart.UseShellExecute = $false
$usbStart.CreateNoWindow = $true
$usbStart.RedirectStandardOutput = $true
$usbStart.RedirectStandardError = $true
$usbProcess = [Diagnostics.Process]::new()
$usbProcess.StartInfo = $usbStart
$referenceProcess = $null
$usbStarted = $false
$referenceStarted = $false
try {
    if (-not $usbProcess.Start()) { throw 'Could not start USBPcap.' }
    $usbStarted = $true
    $usbStdout = $usbProcess.StandardOutput.ReadToEndAsync()
    $usbStderr = $usbProcess.StandardError.ReadToEndAsync()
    $ready = $false
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        if ($usbProcess.HasExited) { throw "USBPcap exited before capture began: $($usbStderr.Result)" }
        if ((Test-Path -LiteralPath $pcapPath) -and (Get-Item -LiteralPath $pcapPath).Length -ge 24) { $ready = $true; break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) { throw 'USBPcap did not create a capture header within 10 seconds.' }

    $referenceStart = [Diagnostics.ProcessStartInfo]::new()
    $referenceStart.FileName = $testExe
    $referenceStart.Arguments = '--uvc-reference --brio --frames {0}' -f $Frames
    $referenceStart.WorkingDirectory = $repo
    $referenceStart.UseShellExecute = $false
    $referenceStart.CreateNoWindow = $true
    $referenceStart.RedirectStandardOutput = $true
    $referenceStart.RedirectStandardError = $true
    $referenceProcess = [Diagnostics.Process]::new()
    $referenceProcess.StartInfo = $referenceStart
    if (-not $referenceProcess.Start()) { throw 'Could not start the Media Foundation reference probe.' }
    $referenceStarted = $true
    $referenceStdout = $referenceProcess.StandardOutput.ReadToEndAsync()
    $referenceStderr = $referenceProcess.StandardError.ReadToEndAsync()
    if (-not $referenceProcess.WaitForExit(30000)) { throw 'The Media Foundation reference probe timed out.' }
    [IO.File]::WriteAllText($referencePath, $referenceStdout.Result)
    if ($referenceProcess.ExitCode -ne 0) { throw "The reference probe failed: $($referenceStderr.Result)" }
    # USBPcapCMD reads console key events, not redirected stdin. Stop the
    # dedicated child process and inspect the pcap framing afterwards; its
    # final record may be incomplete and buffered transfers may be lost.
    if ($usbProcess.HasExited) { throw "USBPcap stopped before the reference probe finished: $($usbStderr.Result)" }
    $usbProcess.Kill()
    $usbProcess.WaitForExit()
    [IO.File]::WriteAllText($logPath, "USBPcap stdout:`r`n$($usbStdout.Result)`r`nUSBPcap stderr:`r`n$($usbStderr.Result)")
    $length = (Get-Item -LiteralPath $pcapPath).Length
    if ($length -le 24) { throw 'USBPcap produced no transfer records; inspect the capture before drawing conclusions.' }
    $file = [IO.File]::OpenRead($pcapPath)
    $reader = [IO.BinaryReader]::new($file)
    try {
        if ($reader.ReadUInt32() -ne [uint32]2712847316) { throw 'The capture does not have the expected little-endian PCAP header.' }
        $file.Position = 24
        $records = 0
        $incompleteTail = $false
        $truncatedRecords = 0
        while ($file.Position -lt $file.Length) {
            if ($file.Length - $file.Position -lt 16) { $incompleteTail = $true; break }
            [void]$reader.ReadUInt32()
            [void]$reader.ReadUInt32()
            $included = $reader.ReadUInt32()
            $original = $reader.ReadUInt32()
            if ($included -gt $original) { throw 'The capture contains an invalid PCAP record length.' }
            if ($included -lt $original) { $truncatedRecords++ }
            if ($included -gt $file.Length - $file.Position) { $incompleteTail = $true; break }
            $file.Position += $included
            $records++
        }
    } finally { $reader.Dispose(); $file.Dispose() }
    if ($records -eq 0) { throw 'The capture contains no complete PCAP records.' }
    Write-Output "Capture file: $length bytes and $records complete PCAP records (which may include injected descriptors); $Frames Media Foundation frame hashes."
    Write-Output "Truncated packet records: $truncatedRecords; incomplete final record: $incompleteTail."
    Write-Output 'USBPcap was stopped after the reference run; buffered transfers may have been lost.'
    Write-Output "Trace: $pcapPath"
    Write-Output "Reference hashes: $referencePath"
    Write-Output 'This is a capture only. A USB frame must still be reconstructed and matched to a reference hash.'
} finally {
    if ($null -ne $referenceProcess) {
        if ($referenceStarted -and -not $referenceProcess.HasExited) { $referenceProcess.Kill() }
        $referenceProcess.Dispose()
    }
    if ($usbStarted -and -not $usbProcess.HasExited) { $usbProcess.Kill() }
    $usbProcess.Dispose()
}
