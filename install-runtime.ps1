param(
  # Renders a representative, side-effect-free installer run. This lets the
  # Linux PowerShell container verify presentation behavior without pretending
  # it can test UAC, Scheduled Tasks, or Windows ACLs.
  [switch]$Preview,
  [string]$Component = ""
)

$ErrorActionPreference = "Stop"

# Component bootstraps are published as standalone copies of this file. Infer
# the component from the filename so a downloaded `hubbound-install-cli.ps1`
# remains self-contained and does not need to fetch/execute another script.
# When PowerShell evaluates a script from stdin, MyCommand.Path is empty; reject
# that mode because there is no local source the user can inspect.
$scriptPath = $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($scriptPath)) {
  throw "Hubbound installer: download the installer, inspect it, then run the local file; piped execution is disabled."
}
$scriptName = [IO.Path]::GetFileName($scriptPath)
$inferredComponent = if ($scriptName -match "install-cli\.ps1$") { "cli" } elseif ($scriptName -match "install-runtime\.ps1$") { "runtime" } elseif ($scriptName -match "install\.ps1$") { "suite" } else { $null }
if ([string]::IsNullOrWhiteSpace($inferredComponent)) {
  throw "Hubbound installer: expected a file named install.ps1, install-cli.ps1 or install-runtime.ps1; piped execution is disabled."
}
if ([string]::IsNullOrWhiteSpace($Component)) { $Component = $inferredComponent }
if (@("cli", "runtime", "suite") -notcontains $Component) {
  throw "Hubbound installer: Component must be cli, runtime or suite"
}

# The Windows bootstrap has the same trust boundary as install.sh: HTTPS plus
# a release checksum before one UAC-elevated helper invocation.

# Windows PowerShell 5.1 consoles often use an OEM code page that cannot render
# Unicode arrows/checkmarks. ASCII markers keep the installer from looking like
# a broken/malware script ("???" glyphs).
$UseColor = -not [Console]::IsOutputRedirected -and -not $env:NO_COLOR
function Write-Color([string]$Text, [ConsoleColor]$Color) {
  if ($UseColor) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
}
function Write-Title([string]$Text) { Write-Host ""; Write-Color $Text Cyan; Write-Host "----------------------------------------------------" }
function Write-Step([string]$Text) { Write-Color "  > $Text" Cyan }
function Write-Ok([string]$Text) { Write-Color "  + $Text" Green }
function Write-Warn([string]$Text) { Write-Color "  ! $Text" Yellow }
function Write-Fail([string]$Text) { Write-Color "  x $Text" Red }

function Get-HubboundWindowsArchitecture {
  $hostArchitecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
  switch ($hostArchitecture) {
    "AMD64" { return "amd64" }
    "ARM64" { return "arm64" }
    default { throw "Unsupported architecture: $hostArchitecture" }
  }
}

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-HubboundProgramData {
  # On Windows, resolve the machine-wide known folder instead of trusting a
  # process environment variable that an unprivileged caller can override.
  # The environment fallback keeps Linux PowerShell preview/harness tests
  # deterministic; it is not used by a real Windows process.
  if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $known = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if (-not [string]::IsNullOrWhiteSpace($known)) { return $known }
    return "C:\ProgramData"
  }
  if ($env:ProgramData) { return $env:ProgramData }
  return "C:\ProgramData"
}

# Start-Process -ArgumentList array quoting is unreliable on Windows PowerShell
# 5.1 (extra embedded quotes become literal characters in argv). Build one
# properly escaped command line instead.
function ConvertTo-SingleQuotedPsLiteral([string]$Value) {
  return "'" + ($Value -replace "'", "''") + "'"
}

function Get-HubboundAgentStartupCommand([string]$AgentExe) {
  # hubbound-agent is built with -H=windowsgui (see .goreleaser.yaml), so
  # Windows never allocates a console for it no matter which terminal host
  # (conhost/Windows Terminal) is active. That lets the scheduled task/Run-key
  # launch the executable directly instead of routing through a hidden
  # PowerShell wrapper, which Windows Terminal ignored -WindowStyle Hidden on
  # anyway. Agent diagnostics are persisted to the normal Hubbound log file.
  $command = '"{0}" run' -f $AgentExe
  # HKCU Run accepts at most 260 characters and schtasks /TR at most 262.
  # Enforce the stricter bound before attempting either registration path.
  if ($command.Length -gt 260) {
    throw "Hubbound agent startup command exceeds the Windows startup command limit"
  }
  return $command
}

# Windows PowerShell 5.1 turns redirected native stderr (2>$null or 2>&1) into
# error records. With the installer's ErrorActionPreference=Stop, the expected
# "task not found" from best-effort cleanup can abort before /Create. Keep
# native diagnostics as data and request HRESULT exit codes where supported so
# "file not found" and "access denied" do not both collapse into exit code 1.
function Invoke-SchtasksCommand {
  param([string]$FilePath, [string[]]$ArgumentList)

  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $rawOutput = @(& $FilePath @ArgumentList 2>&1)
    $exitCode = [int]$LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }

  $unsignedExitCode = [BitConverter]::ToUInt32([BitConverter]::GetBytes($exitCode), 0)
  $output = (($rawOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
  return [pscustomobject]@{
    ExitCode = $exitCode
    ExitCodeHex = ("0x{0:X8}" -f $unsignedExitCode)
    Output = $output
  }
}

function Get-HelperFailureDetail([string]$LogPath, [int]$ExitCode) {
  $detail = "System installation or daemon health check failed (exit code $ExitCode)"
  if (-not (Test-Path -LiteralPath $LogPath)) {
    return $detail
  }
  $raw = (Get-Content -LiteralPath $LogPath -Raw -ErrorAction SilentlyContinue)
  if (-not $raw) {
    return "$detail. See $LogPath"
  }
  # Windows PowerShell 5.1 appends ErrorRecord metadata after native stderr.
  # The final line is commonly only "FullyQualifiedErrorId :
  # NativeCommandError", which hid the helper's real filesystem/service error.
  # hubbound-helper emits its authoritative error first; ignore the wrapper
  # metadata and surface that diagnostic instead.
  $line = (($raw -split "`r?`n") | Where-Object {
    $value = $_.Trim()
    $value -ne "" -and
      $value -notmatch '^At .+\.ps1:\d+ char:\d+$' -and
      $value -notmatch '^\+\s*(CategoryInfo|FullyQualifiedErrorId)\s*:' -and
      $value -notmatch '^\+\s*[~&]'
  } | Select-Object -First 1)
  if ($line) {
    return "$detail. Helper: $line (full log: $LogPath)"
  }
  return "$detail. See $LogPath"
}

function Expand-HubboundArchiveMember {
  param(
    [string]$ArchivePath,
    [string]$DestinationPath,
    [string]$MemberName
  )

  if ([IO.Path]::GetFileName($MemberName) -ne $MemberName -or $MemberName.Contains('/') -or $MemberName.Contains('\')) {
    throw "Hubbound archive member must be a top-level file: $MemberName"
  }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
  try {
    $entries = @($zip.Entries | Where-Object { $_.FullName -eq $MemberName })
    if ($entries.Count -ne 1 -or [string]::IsNullOrWhiteSpace($entries[0].Name)) {
      throw "Archive must contain exactly one top-level $MemberName"
    }
    $destination = Join-Path $DestinationPath $MemberName
    $source = $entries[0].Open()
    try {
      $target = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
      try {
        $source.CopyTo($target)
      }
      finally {
        $target.Dispose()
      }
    }
    finally {
      $source.Dispose()
    }
    return $destination
  }
  finally {
    $zip.Dispose()
  }
}

function Invoke-InitialToolRepair {
  param(
    [string]$HubboundExe,
    [string]$WorkDir,
    [int]$TimeoutSeconds = 300
  )

  if ($TimeoutSeconds -le 0) {
    throw "Hubbound tool repair timeout must be greater than zero"
  }

  # Windows PowerShell 5.1 turns native stderr redirected with 2>&1 into
  # ErrorRecord objects. With this installer's ErrorActionPreference=Stop, the
  # first slog line ("doctor started") terminates the pipeline before repair
  # can install provider assets. Keep native stdout/stderr outside PowerShell's
  # streams so the child can finish, then inspect both its exit code and JSON.
  $stdoutPath = Join-Path $WorkDir "hubbound-doctor.stdout.json"
  # Persist the latest provider trace after WorkDir cleanup so a timeout still
  # reveals which provider/subprocess failed to return.
  $stderrPath = Join-Path $env:TEMP "hubbound-doctor-repair.log"
  Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

  $process = Start-Process -FilePath $HubboundExe `
    -ArgumentList @("doctor", "repair", "--output", "json") `
    -NoNewWindow -PassThru `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath
  if ($null -eq $process) {
    throw "Could not start Hubbound tool repair"
  }
  if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    # doctor may currently be waiting on another provider child.
    # Process.Kill() in Windows PowerShell 5.1 only terminates the direct
    # process, so ask taskkill to close the full tree before using Kill as a
    # portable fallback.
    if ($env:OS -eq "Windows_NT") {
      $taskkill = Join-Path $env:SystemRoot "System32\taskkill.exe"
      $previousErrorActionPreference = $ErrorActionPreference
      try {
        $ErrorActionPreference = "Continue"
        $null = @(& $taskkill /PID $process.Id /T /F 2>&1)
      }
      finally {
        $ErrorActionPreference = $previousErrorActionPreference
      }
    }
    try { if (-not $process.HasExited) { $process.Kill() } } catch {}
    try { $process.WaitForExit() } catch {}
    $lastLog = (Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -ne "" } | Select-Object -Last 1)
    if ($lastLog) {
      throw "Hubbound tool repair timed out after $TimeoutSeconds seconds. Last log: $lastLog (full log: $stderrPath)"
    }
    throw "Hubbound tool repair timed out after $TimeoutSeconds seconds (full log: $stderrPath)"
  }
  # Flush asynchronous redirected streams before reading the report files.
  $process.WaitForExit()

  $stdout = Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue
  $stderr = Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
  if ($process.ExitCode -ne 0) {
    $detail = if ($stderr) { $stderr.Trim() } elseif ($stdout) { $stdout.Trim() } else { "no diagnostic output" }
    throw "Hubbound tool repair exited with code $($process.ExitCode): $detail"
  }
  if (-not $stdout) {
    $detail = if ($stderr) { $stderr.Trim() } else { "no diagnostic output" }
    throw "Hubbound tool repair returned no JSON report: $detail"
  }

  try {
    $report = $stdout | ConvertFrom-Json
  }
  catch {
    throw "Hubbound tool repair returned invalid JSON: $($_.Exception.Message)"
  }

  $issues = @($report.providers | Where-Object { $_.status -eq "failed" -or $_.status -eq "degraded" })
  if ($issues.Count -gt 0) {
    $detail = ($issues | ForEach-Object { "$($_.provider): $($_.reason)" }) -join "; "
    throw "Hubbound tool repair did not converge: $detail"
  }
  return $report
}

function Invoke-SystemInstall {
  param(
    [string]$ArchivePath,
    [string]$ExpectedSHA256,
    [string]$Version,
    [string]$SystemRoot,
    [string]$Component = "suite"
  )

  $alreadyElevated = Test-IsAdministrator
  if (-not $alreadyElevated) {
    Write-Warn "Windows will request administrator permission once to install the system daemon."
  }

  # Never elevate a helper executable extracted into the caller's writable
  # temp directory. A same-user process could replace that helper between the
  # checksum step and UAC approval. The elevated command below copies the
  # archive into a fresh ProgramData directory, hashes that protected copy,
  # extracts the helper from the protected copy, and only then runs it.
  #
  # Use -EncodedCommand instead of a generated .ps1 file: the latter would be
  # another user-writable file executed with administrator rights. The base64
  # payload contains only code plus single-quoted, escaped data values.
  $nonce = [guid]::NewGuid().ToString("N")
  $bootstrapRoot = Join-Path (Get-HubboundProgramData) ("HubBoundBootstrap-" + $nonce)
  $logPath = Join-Path $bootstrapRoot "install.log"
  $archiveLit = ConvertTo-SingleQuotedPsLiteral $ArchivePath
  $expectedLit = ConvertTo-SingleQuotedPsLiteral $ExpectedSHA256.ToLowerInvariant()
  $versionLit = ConvertTo-SingleQuotedPsLiteral $Version
  $rootLit = ConvertTo-SingleQuotedPsLiteral $SystemRoot
  $componentLit = ConvertTo-SingleQuotedPsLiteral $Component
  $bootstrapRootLit = ConvertTo-SingleQuotedPsLiteral $bootstrapRoot
  $logPathLit = ConvertTo-SingleQuotedPsLiteral $logPath
  $scriptLines = @(
    '$ErrorActionPreference = "Stop"'
    '$exitCode = 1'
    "`$bootstrapRoot = $bootstrapRootLit"
    "`$logPath = $logPathLit"
    "New-Item -ItemType Directory -Force -Path `$bootstrapRoot | Out-Null"
    'try {'
    "  `$stagedArchive = Join-Path `$bootstrapRoot 'release.zip'"
    "  Copy-Item -LiteralPath $archiveLit -Destination `$stagedArchive -Force"
    "  `$actual = (Get-FileHash -LiteralPath `$stagedArchive -Algorithm SHA256).Hash.ToLowerInvariant()"
    "  if (`$actual -ne $expectedLit) { throw `"protected archive checksum mismatch: got `$actual want $expectedLit`" }"
    "  `$payloadRoot = Join-Path `$bootstrapRoot 'payload'"
    "  New-Item -ItemType Directory -Force -Path `$payloadRoot | Out-Null"
    "  Add-Type -AssemblyName System.IO.Compression.FileSystem"
    "  `$zip = [IO.Compression.ZipFile]::OpenRead(`$stagedArchive)"
    "  try {"
    "    `$entries = @(`$zip.Entries | Where-Object { `$_.FullName -eq 'hubbound-helper.exe' })"
    "    if (`$entries.Count -ne 1 -or [string]::IsNullOrWhiteSpace(`$entries[0].Name)) { throw 'Archive must contain exactly one top-level hubbound-helper.exe' }"
    "    `$helperPath = Join-Path `$payloadRoot 'hubbound-helper.exe'"
    "    `$source = `$entries[0].Open()"
    "    try {"
    "      `$target = [IO.File]::Open(`$helperPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)"
    "      try { `$source.CopyTo(`$target) } finally { `$target.Dispose() }"
    "    } finally { `$source.Dispose() }"
    "  } finally { `$zip.Dispose() }"
    "  `$helper = Get-Item -LiteralPath `$helperPath"
    "  `$helperArgs = @('system', 'install', '--component', $componentLit, '--archive', `$stagedArchive, '--sha256', `$actual, '--version', $versionLit, '--system-root', $rootLit)"
    "  & `$helper.FullName @helperArgs *> `$logPath"
    '  $exitCode = $LASTEXITCODE'
    '} catch {'
    "  `$_.Exception.Message | Out-File -LiteralPath `$logPath -Encoding utf8"
    '  $exitCode = 1'
    '} finally {'
    '  if ($exitCode -eq 0) {'
    '    Remove-Item -LiteralPath $bootstrapRoot -Recurse -Force -ErrorAction SilentlyContinue'
    '  } else {'
    '    Remove-Item -LiteralPath (Join-Path $bootstrapRoot "release.zip"), (Join-Path $bootstrapRoot "payload") -Recurse -Force -ErrorAction SilentlyContinue'
    '  }'
    '}'
    'exit $exitCode'
  )
  $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($scriptLines -join [Environment]::NewLine)))

  $startProcessParameters = @{
    FilePath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    ArgumentList = @("-NoProfile", "-EncodedCommand", $encodedCommand)
    Wait = $true
    PassThru = $true
  }
  if ($alreadyElevated) {
    # No second UAC process and no transient console window when the parent is
    # already elevated. All useful diagnostics remain in $logPath.
    $startProcessParameters["WindowStyle"] = "Hidden"
  }
  else {
    $startProcessParameters["Verb"] = "RunAs"
  }

  $process = Start-Process @startProcessParameters
  if ($null -eq $process) {
    throw "Administrator permission was not granted"
  }
  if ($process.ExitCode -ne 0) {
    throw (Get-HelperFailureDetail -LogPath $logPath -ExitCode $process.ExitCode)
  }
}

function Remove-StaleHubboundAgentTask {
  param([string]$TaskName)

  $schtasks = Join-Path $env:SystemRoot "System32\schtasks.exe"
  [void](Invoke-SchtasksCommand -FilePath $schtasks -ArgumentList @("/End", "/TN", $TaskName))
  [void](Invoke-SchtasksCommand -FilePath $schtasks -ArgumentList @("/Delete", "/TN", $TaskName, "/F"))

  # A task from a previous elevated/partial installation may be owned by a
  # different SID. If it survived the user-scope delete, retry exactly this
  # cleanup through UAC before creating the new user task. Do not treat every
  # nonzero result as "absent": access denied means the task may merely be
  # hidden from the current unelevated token.
  $queryResult = Invoke-SchtasksCommand -FilePath $schtasks -ArgumentList @("/Query", "/TN", $TaskName, "/HResult")
  if ($queryResult.ExitCodeHex -eq "0x80070002") { return }
  if ($queryResult.ExitCode -ne 0 -and $queryResult.ExitCodeHex -ne "0x80070005") {
    throw "Could not inspect existing task '$TaskName' (exit $($queryResult.ExitCode), $($queryResult.ExitCodeHex)): $($queryResult.Output)"
  }

  $taskLit = ConvertTo-SingleQuotedPsLiteral $TaskName
  $schtasksLit = ConvertTo-SingleQuotedPsLiteral $schtasks
  $cleanupLines = @(
    '$ErrorActionPreference = "Continue"'
    "`$taskName = $taskLit"
    "`$schtasks = $schtasksLit"
    '& $schtasks /End /TN $taskName 2>$null | Out-Null'
    '& $schtasks /Delete /TN $taskName /F 2>$null | Out-Null'
    '& $schtasks /Query /TN $taskName 2>$null | Out-Null'
    'if ($LASTEXITCODE -eq 0) { exit 1 }'
    'exit 0'
  )
  $encodedCleanup = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($cleanupLines -join [Environment]::NewLine)))

  Write-Warn "Removing stale HubboundAgent task with administrator permission."
  $startProcessParameters = @{
    FilePath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    ArgumentList = @("-NoProfile", "-EncodedCommand", $encodedCleanup)
    Wait = $true
    PassThru = $true
  }
  if (Test-IsAdministrator) {
    $startProcessParameters["WindowStyle"] = "Hidden"
  } else {
    $startProcessParameters["Verb"] = "RunAs"
  }
  $process = Start-Process @startProcessParameters
  if ($null -eq $process -or $process.ExitCode -ne 0) {
    throw "Could not remove stale scheduled task '$TaskName'"
  }
}

function Start-HubboundAgentTask {
  param([string]$TaskName, [string]$AgentExe)

  if (-not (Test-Path -LiteralPath $AgentExe)) {
    throw "Hubbound agent executable is missing: $AgentExe"
  }

  $schtasks = Join-Path $env:SystemRoot "System32\schtasks.exe"
  Remove-StaleHubboundAgentTask -TaskName $TaskName

  # /IT makes this a user-session process; leaving /RU unspecified deliberately
  # binds it to the current user without ever asking for or persisting a password.
  $taskCommand = Get-HubboundAgentStartupCommand $AgentExe
  $createResult = Invoke-SchtasksCommand -FilePath $schtasks -ArgumentList @(
    "/Create", "/TN", $TaskName, "/TR", $taskCommand,
    "/SC", "ONLOGON", "/IT", "/RL", "LIMITED", "/F", "/HResult"
  )
  if ($createResult.ExitCode -ne 0) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $scheduleService = Get-Service -Name "Schedule" -ErrorAction SilentlyContinue
    $scheduleStatus = if ($null -eq $scheduleService) { "not-found" } else { $scheduleService.Status.ToString() }
    throw "schtasks /Create failed (exit $($createResult.ExitCode), $($createResult.ExitCodeHex)): $($createResult.Output); agent_exists=$((Test-Path -LiteralPath $AgentExe)); scheduler=$scheduleStatus; identity=$($identity.Name); sid=$($identity.User.Value)"
  }
  $queryResult = Invoke-SchtasksCommand -FilePath $schtasks -ArgumentList @("/Query", "/TN", $TaskName, "/HResult")
  if ($queryResult.ExitCode -ne 0) {
    [void](Invoke-SchtasksCommand -FilePath $schtasks -ArgumentList @("/Delete", "/TN", $TaskName, "/F"))
    throw "Task Scheduler accepted '$TaskName' but query failed (exit $($queryResult.ExitCode), $($queryResult.ExitCodeHex)): $($queryResult.Output)"
  }
  $runResult = Invoke-SchtasksCommand -FilePath $schtasks -ArgumentList @("/Run", "/TN", $TaskName)
  if ($runResult.ExitCode -ne 0) {
    # Registration already converged, so do not add the Run-key fallback and
    # accidentally launch two agents at the next logon. This session can work
    # without the updater agent; Task Scheduler will retry on the next logon.
    Write-Warn "Task '$TaskName' was registered but could not be started in this session (exit $($runResult.ExitCode), $($runResult.ExitCodeHex)): $($runResult.Output)"
  }
}

function Remove-HubboundAgentRunKey {
  $runKeyPath = "Software\Microsoft\Windows\CurrentVersion\Run"
  $runKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runKeyPath, $true)
  if ($null -eq $runKey) { return }
  try {
    $runKey.DeleteValue("HubboundAgent", $false)
  }
  finally {
    $runKey.Dispose()
  }
}

function Start-HubboundAgentRunKey {
  param([string]$AgentExe)

  if (-not (Test-Path -LiteralPath $AgentExe)) {
    throw "Hubbound agent executable is missing: $AgentExe"
  }

  # HKCU Run is the compatibility fallback when Task Scheduler registration is
  # unavailable (for example because of local/domain policy or account lookup
  # failures). It has the same user-logon scope, needs no password/admin token,
  # and SetValue makes repeated installs idempotent. Keep the command pointed at
  # `current` so the next logon follows an atomically activated suite update.
  $runKeyPath = "Software\Microsoft\Windows\CurrentVersion\Run"
  $command = Get-HubboundAgentStartupCommand $AgentExe
  $runKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($runKeyPath)
  if ($null -eq $runKey) {
    throw "Could not open the current-user startup registry key"
  }
  try {
    $runKey.SetValue("HubboundAgent", $command, [Microsoft.Win32.RegistryValueKind]::String)
    if ($runKey.GetValue("HubboundAgent", "") -ne $command) {
      throw "Windows did not persist the HubboundAgent startup command"
    }
  }
  finally {
    $runKey.Dispose()
  }

  # The Run key applies at the next logon; start this session now as the same
  # unelevated user. -WindowStyle Hidden prevents a persistent console window.
  Start-Process -FilePath $AgentExe -ArgumentList "run" -WindowStyle Hidden | Out-Null
}

if ($Preview) {
  Write-Title "Hubbound Installer"
  Write-Host ""
  $previewArch = Get-HubboundWindowsArchitecture
  Write-Color "Installing v0.0.0-preview  (windows-$previewArch, $Component)" Yellow
  Write-Host ""
  Write-Step "Downloading the Hubbound $Component"
  $previewArchive = if ($Component -eq "cli") { "hubbound-cli_windows_$previewArch.zip" } elseif ($Component -eq "runtime") { "hubbound-runtime_windows_$previewArch.zip" } else { "hubbound_windows_$previewArch.zip" }
  Write-Ok "Downloaded $previewArchive"
  Write-Step "Verifying the SHA-256 checksum"
  Write-Ok "Checksum verified"
  if ($Component -eq "cli") {
    Write-Step "Installing the CLI in your user account"
    Write-Ok "Installed the standalone CLI without administrator permission"
  } else {
    Write-Step "Preparing the protected system installation"
    Write-Warn "Windows will request administrator permission once to install the system daemon."
    Write-Ok "Installed protected binaries and started hubboundd"
    $sessionLabel = if ($Component -eq "suite") { "Configuring your user session" } else { "Configuring the user agent" }
    Write-Step $sessionLabel
    Write-Ok "Installed your Hubbound user agent"
    Write-Ok "Daemon health check passed"
  }
  Write-Host ""
  $previewName = if ($Component -eq "cli") { "Hubbound CLI" } else { "Hubbound $Component" }
  Write-Color "$previewName v0.0.0-preview is ready!" Green
  Write-Host ""
  Write-Host "Get started:"
  if ($Component -eq "cli") {
    Write-Color "  hubbound auth login       connect your Hubbound account" Cyan
  } elseif ($Component -eq "suite") {
    Write-Color "  hubbound auth login       connect your Hubbound account" Cyan
    Write-Color "  hubbound daemon status    check the system daemon" Cyan
    Write-Color "  hubbound update status    view update state" Cyan
  } else {
    Write-Color "  hubboundd status          check the system daemon" Cyan
    Write-Color "  hubbound-agent run        run the user agent manually" Cyan
  }
  exit 0
}

$Repo = if ($env:HUBBOUND_REPO) { $env:HUBBOUND_REPO } else { "hubbound/hubbound" }
$Version = $env:HUBBOUND_VERSION
$Arch = Get-HubboundWindowsArchitecture
$Archive = switch ($Component) {
  "cli" { "hubbound-cli_windows_$Arch.zip" }
  "runtime" { "hubbound-runtime_windows_$Arch.zip" }
  default { "hubbound_windows_$Arch.zip" }
}
$UserBin = if ($env:HUBBOUND_USER_BIN) { $env:HUBBOUND_USER_BIN } else { Join-Path $env:LOCALAPPDATA "Hubbound\bin" }

Write-Title "Hubbound Installer"
if (-not $Version) {
  Write-Step "Finding the latest Hubbound release"
  $Version = (Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest").tag_name
}
if (-not $Version) { throw "Could not determine the release version" }
$DataDirName = if ($Version -like "*-dev.*") { "hubbound-lab" } else { "hubbound" }
if ($env:HUBBOUND_SYSTEM_ROOT) {
  throw "Custom Windows system roots are not supported by the trusted bootstrap; use the machine-wide ProgramData root"
}
$Root = Join-Path (Get-HubboundProgramData) $DataDirName
Write-Host ""
Write-Color "Installing $Version  (windows-$Arch, $Component)" Yellow
Write-Host ""

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
New-Item -ItemType Directory -Path $Tmp | Out-Null
try {
  $Base = if ($env:HUBBOUND_RELEASE_BASE_URL) { $env:HUBBOUND_RELEASE_BASE_URL } else { "https://github.com/$Repo/releases/download/$Version" }
  $Base = $Base.TrimEnd('/')
  if ($Base -notmatch '(?i)^https://') {
    if ($Base -match '(?i)^http://' -and $env:HUBBOUND_ALLOW_INSECURE_HTTP -eq "1") {
      # HTTP is only useful for an explicitly opted-in local test mirror.
    }
    elseif ($Base -match '(?i)^http://') {
      throw "Insecure HTTP release mirrors require HUBBOUND_ALLOW_INSECURE_HTTP=1"
    }
    else {
      throw "Release mirror must use HTTPS"
    }
  }

  Write-Step "Downloading the Hubbound $Component"
  Invoke-WebRequest "$Base/$Archive" -OutFile (Join-Path $Tmp $Archive)
  Write-Ok "Downloaded $Archive"
  Invoke-WebRequest "$Base/checksums.txt" -OutFile (Join-Path $Tmp "checksums.txt")

  Write-Step "Verifying the SHA-256 checksum"
  $checksumPattern = "^\s*[0-9A-Fa-f]{64}\s+\*?$([regex]::Escape($Archive))$"
  $checksumLines = @(Get-Content (Join-Path $Tmp "checksums.txt") | Where-Object { $_ -match $checksumPattern })
  if ($checksumLines.Count -ne 1) { throw "Expected exactly one valid checksum entry for $Archive" }
  $Expected = ($checksumLines[0] -split '\s+')[0].ToLowerInvariant()
  $Actual = (Get-FileHash (Join-Path $Tmp $Archive) -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($Expected -ne $Actual) { throw "Checksum verification failed - installation stopped" }
  Write-Ok "Checksum verified"

  if ($Component -eq "cli") {
    $Cli = Expand-HubboundArchiveMember -ArchivePath (Join-Path $Tmp $Archive) -DestinationPath $Tmp -MemberName "hubbound.exe"
    Write-Step "Installing the CLI in your user account"
    New-Item -ItemType Directory -Force -Path $UserBin | Out-Null
    Copy-Item $Cli (Join-Path $UserBin "hubbound.exe") -Force
    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($null -eq $UserPath) { $UserPath = "" }
    if (($UserPath -split ';') -notcontains $UserBin) {
      [Environment]::SetEnvironmentVariable("Path", ($UserPath.TrimEnd(';') + ";" + $UserBin), "User")
      Write-Ok "Added $UserBin to your user PATH"
    }
    Write-Ok "Installed the standalone CLI at $(Join-Path $UserBin 'hubbound.exe')"
    Write-Host ""
    Write-Color "Hubbound CLI $Version is ready!" Green
    exit 0
  }

  Write-Step "Preparing the protected system installation"
  $ArchivePath = Join-Path $Tmp $Archive
  Invoke-SystemInstall -ArchivePath $ArchivePath -ExpectedSHA256 $Expected -Version $Version -SystemRoot $Root -Component $Component
  Write-Ok "Installed protected binaries and started hubboundd"

  if ($Component -eq "suite") {
    Write-Step "Configuring your user session"
    New-Item -ItemType Directory -Force -Path $UserBin | Out-Null
    foreach ($Binary in @("hubbound.exe", "hubbound-agent.exe", "hubbound-helper.exe")) {
      Copy-Item (Join-Path $Root "current\$Binary") (Join-Path $UserBin $Binary) -Force
    }
    Write-Ok "Installed Hubbound commands at $UserBin"

    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($null -eq $UserPath) { $UserPath = "" }
    $PathAdded = ($UserPath -split ';') -notcontains $UserBin
    if ($PathAdded) {
      [Environment]::SetEnvironmentVariable("Path", ($UserPath.TrimEnd(';') + ";" + $UserBin), "User")
      Write-Ok "Added $UserBin to your user PATH"
    }
  }

  $taskName = "HubboundAgent"
  $agentExe = Join-Path $Root "current\hubbound-agent.exe"
  try {
    Start-HubboundAgentTask -TaskName $taskName -AgentExe $agentExe
    # A previous install may have needed the compatibility fallback. Never keep
    # both registrations or Windows would launch two agents at the next logon.
    Remove-HubboundAgentRunKey
    Write-Ok "Installed your Hubbound user agent"
  }
  catch {
    Write-Warn "Could not register scheduled task '$taskName': $($_.Exception.Message)"
    Write-Warn "Falling back to the current-user Windows startup registry."
    try {
      Start-HubboundAgentRunKey -AgentExe $agentExe
      Write-Ok "Installed your Hubbound user agent via current-user startup"
    }
    catch {
      Write-Warn "Could not register the fallback user agent: $($_.Exception.Message)"
      Write-Warn "Daemon is installed. Start the agent manually with:"
      Write-Warn "  & '$agentExe' run"
    }
  }

  # hubboundd is a system service and cannot reliably resolve the desktop
  # user's Windows profile. Run the first provider repair from this user
  # session so every eligible editor gets its hooks/scripts immediately.
  if ($Component -eq "suite") {
    Write-Step "Repairing eligible tool integrations"
    Write-Color "    First-time provider setup may take a few minutes (maximum 5 minutes)." DarkGray
    $hubboundExe = Join-Path $UserBin "hubbound.exe"
    try {
      $null = Invoke-InitialToolRepair -HubboundExe $hubboundExe -WorkDir $Tmp
      Write-Ok "Eligible tool integrations repaired"
    }
    catch {
      Write-Warn "Initial tool repair was incomplete: $($_.Exception.Message)"
      Write-Warn "Run 'hubbound doctor repair' after restarting any affected IDEs."
    }
  }
  Write-Ok "Daemon health check passed"

  # Restore telemetry parked by uninstall.ps1 -KeepData into the new system root.
  $dataDirName = Split-Path -Leaf $Root
  $preservedAnalytics = Join-Path (Join-Path $env:APPDATA $dataDirName) "analytics"
  $systemAnalytics = Join-Path $Root "analytics"
  if (Test-Path -LiteralPath $preservedAnalytics) {
    Write-Step "Restoring preserved telemetry into the system analytics spool"
    $systemHasData = (Test-Path -LiteralPath $systemAnalytics) -and
      (Get-ChildItem -LiteralPath $systemAnalytics -Force -ErrorAction SilentlyContinue)
    if ($systemHasData) {
      Write-Warn "System analytics already present; leaving $preservedAnalytics in place"
    } else {
      $restoreLog = Join-Path $env:TEMP "hubbound-restore-analytics.log"
      $srcLit = ConvertTo-SingleQuotedPsLiteral $preservedAnalytics
      $destLit = ConvertTo-SingleQuotedPsLiteral $systemAnalytics
      $logLit = ConvertTo-SingleQuotedPsLiteral $restoreLog
      $restoreLines = @(
        '$ErrorActionPreference = "Continue"'
        "New-Item -ItemType Directory -Path (Split-Path -Parent $destLit) -Force | Out-Null"
        "Remove-Item -LiteralPath $destLit -Recurse -Force -ErrorAction SilentlyContinue"
        "Copy-Item -LiteralPath $srcLit -Destination $destLit -Recurse -Force *>> $logLit"
        "if (-not (Test-Path -LiteralPath $destLit)) { exit 1 }"
        "exit 0"
      )
      $encodedRestore = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($restoreLines -join [Environment]::NewLine)))
      $startProcessParameters = @{
        FilePath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        ArgumentList = @("-NoProfile", "-EncodedCommand", $encodedRestore)
        Wait = $true
        PassThru = $true
      }
      if (Test-IsAdministrator) {
        $startProcessParameters["WindowStyle"] = "Hidden"
      } else {
        $startProcessParameters["Verb"] = "RunAs"
      }
      $process = Start-Process @startProcessParameters
      if ($null -ne $process -and $process.ExitCode -eq 0) {
        Remove-Item -LiteralPath $preservedAnalytics -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "Restored telemetry to $systemAnalytics"
      } else {
        $code = if ($null -eq $process) { "uac-denied" } else { $process.ExitCode }
        Write-Warn "Could not restore preserved telemetry (exit $code)"
      }
    }
  }

  Write-Host ""
  Write-Color "Hubbound $Version is ready!" Green
  Write-Host ""
  Write-Host "Get started:"
  if ($Component -eq "suite") {
    Write-Color "  hubbound auth login       connect your Hubbound account" Cyan
    Write-Color "  hubbound daemon status    check the system daemon" Cyan
    Write-Color "  hubbound update status    view update state" Cyan
  } else {
    Write-Color "  hubboundd status          check the system daemon" Cyan
    Write-Color "  hubbound-agent run        run the user agent manually" Cyan
  }
  if ($PathAdded) {
    Write-Host ""
    Write-Host "Open a new terminal to activate Hubbound."
  }
}
catch {
  Write-Fail $_.Exception.Message
  exit 1
}
finally {
  Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}
