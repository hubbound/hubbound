param(
  # Side-effect-free presentation check (same contract as install.ps1 -Preview).
  [switch]$Preview,
  # Remove binaries/services only; keep AppData state/cache + telemetry spool.
  [switch]$KeepData,
  # Also delete user state/cache and any preserved telemetry (full wipe).
  [switch]$PurgeData
)

$ErrorActionPreference = "Stop"

# Windows PowerShell 5.1 consoles often use an OEM code page that cannot render
# Unicode arrows/checkmarks. ASCII markers keep the script readable.
$UseColor = -not [Console]::IsOutputRedirected -and -not $env:NO_COLOR
function Write-Color([string]$Text, [ConsoleColor]$Color) {
  if ($UseColor) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
}
function Write-Title([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Red) {
  Write-Host ""
  Write-Color $Text $Color
  Write-Host "----------------------------------------------------"
}
function Write-Step([string]$Text) { Write-Color "==> $Text" Cyan }
function Write-Ok([string]$Text) { Write-Color "  + $Text" Green }
function Write-Warn([string]$Text) { Write-Color "  ! $Text" Yellow }
function Write-Detail([string]$Text) { Write-Color "    > $Text" Cyan }
function Write-Fail([string]$Text) { Write-Color "  x $Text" Red }

$ReinstallCommand = "Download https://raw.githubusercontent.com/hubbound/hubbound/main/install.ps1, inspect it, then run: powershell -NoProfile -File .\\install.ps1"

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-HubboundProgramData {
  # Resolve the machine-wide known folder on real Windows. Do not let a
  # process-level ProgramData override redirect privileged cleanup to a
  # user-writable directory. The fallback is only for Linux PowerShell tests.
  if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $known = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if (-not [string]::IsNullOrWhiteSpace($known)) { return $known }
    return "C:\ProgramData"
  }
  if ($env:ProgramData) { return $env:ProgramData }
  return "C:\ProgramData"
}

function ConvertTo-SingleQuotedPsLiteral([string]$Value) {
  return "'" + ($Value -replace "'", "''") + "'"
}

# --- HubBound MSI products (HUBJ-314) -----------------------------------------
# Setup installs the CLI (per-user) and the Runtime (per-machine) as MSI products
# identified by a fixed UpgradeCode (packaging/windows/hubbound-*-v4.wxs; dev and
# release builds share them, only the data directory name differs). Deleting
# their files and service by hand leaves the MSI registration behind, so Setup
# later reports "already installed" for a machine that has nothing installed.
# The uninstaller therefore removes the products through Windows Installer and
# keeps its manual cleanup for leftovers.
#
# The three functions below are also embedded in the elevated child scripts, so
# their bodies must not call any other function of this file and must keep
# comments outside of them (the encoded command has a length limit).
$ExitNewerInstall = 42

function Get-HubboundMsiProducts {
  param([string[]]$Components = @("CLI", "Runtime"))
  $upgradeCodes = @{ CLI = "{8B3F5A8F-29AB-44E8-9F9D-5B79D94E7D01}"; Runtime = "{4A7943DE-75A4-4A58-9F22-A2CDE9E85EE3}" }
  $found = @()
  try { $installer = New-Object -ComObject WindowsInstaller.Installer } catch { return @() }
  foreach ($component in $Components) {
    if (-not $upgradeCodes.ContainsKey($component)) { continue }
    try {
      $related = $installer.GetType().InvokeMember("RelatedProducts", "GetProperty", $null, $installer, @($upgradeCodes[$component]))
      foreach ($product in @($related)) {
        $version = ""
        try { $version = [string]$installer.GetType().InvokeMember("ProductInfo", "GetProperty", $null, $installer, @($product, "VersionString")) } catch { }
        $found += [pscustomobject]@{ Component = $component; ProductCode = ([string]$product).ToUpperInvariant(); Version = $version }
      }
    } catch { }
  }
  return @($found)
}

function Test-HubboundNewerInstall {
  param([string[]]$Snapshot, [string[]]$Components)
  foreach ($product in @(Get-HubboundMsiProducts -Components $Components)) {
    if (@($Snapshot) -notcontains "$($product.Component)|$($product.ProductCode)|$($product.Version)") { return $true }
  }
  return $false
}

function Uninstall-HubboundMsiProducts {
  param([string[]]$Snapshot, [string[]]$Components)
  $failed = 0
  foreach ($product in @(Get-HubboundMsiProducts -Components $Components)) {
    if (@($Snapshot) -notcontains "$($product.Component)|$($product.ProductCode)|$($product.Version)") {
      Write-Host "  ! Skipping $($product.Component) MSI $($product.ProductCode): it was not installed when the uninstall started"
      continue
    }
    Write-Host "    > msiexec /x $($product.ProductCode) ($($product.Component) $($product.Version))"
    $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList @("/x", $product.ProductCode, "/qn", "/norestart") -Wait -PassThru -WindowStyle Hidden
    $code = $process.ExitCode
    if ($code -eq 0 -or $code -eq 1605 -or $code -eq 3010) {
      Write-Host "  + $($product.Component) MSI removed (exit $code)"
    } else {
      Write-Host "  ! $($product.Component) MSI removal failed (exit $code)"
      $failed++
    }
  }
  return $failed
}

function Get-HubboundFunctionSource([string]$Name) {
  return "function $Name {" + [Environment]::NewLine + (Get-Command -Name $Name -CommandType Function).Definition + [Environment]::NewLine + "}"
}

# "Component|PRODUCTCODE|Version" for every HubBound MSI product registered now.
function Get-HubboundMsiSnapshot {
  return @(Get-HubboundMsiProducts | ForEach-Object { "$($_.Component)|$($_.ProductCode)|$($_.Version)" })
}

# Lines that make an elevated child re-check, right before it destroys
# anything, that no HubBound MSI product appeared after the uninstall started
# (UAC can be accepted long after the prompt was raised). The parent turns
# $ExitNewerInstall into a warning.
function Get-ElevatedGuardLines {
  param([string[]]$Components, [switch]$WithUninstall)
  $snapshotLits = (@($script:MsiSnapshot | ForEach-Object { ConvertTo-SingleQuotedPsLiteral $_ }) -join ", ")
  $componentLits = (@($Components | ForEach-Object { ConvertTo-SingleQuotedPsLiteral $_ }) -join ", ")
  $lines = @(
    (Get-HubboundFunctionSource "Get-HubboundMsiProducts")
    (Get-HubboundFunctionSource "Test-HubboundNewerInstall")
  )
  if ($WithUninstall) { $lines += (Get-HubboundFunctionSource "Uninstall-HubboundMsiProducts") }
  $lines += "`$msiSnapshot = @($snapshotLits)"
  $lines += "if (Test-HubboundNewerInstall -Snapshot `$msiSnapshot -Components @($componentLits)) { exit $ExitNewerInstall }"
  return $lines
}

# True (after a warning) when a HubBound MSI product of the component appeared
# after the uninstall started: its files, service and PATH entry are not ours.
function Test-NewerInstallSkip {
  param([string]$Component, [string]$What)
  if (Test-HubboundNewerInstall -Snapshot $script:MsiSnapshot -Components @($Component)) {
    Write-Warn "A newer HubBound installation was detected; leaving $What in place"
    return $true
  }
  return $false
}

function Invoke-ElevatedScript {
  param(
    [string]$WorkDir,
    [string[]]$Lines,
    [string]$LogPath
  )

  Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
  # Keep the elevated payload in memory. A generated .ps1 under the caller's
  # temp directory could be replaced by the user between UAC approval and
  # execution. The lines passed by callers contain only single-quoted,
  # escaped data values.
  $scriptLines = @(
    '$ErrorActionPreference = "Continue"'
    $Lines
    'exit $LASTEXITCODE'
  )
  $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($scriptLines -join [Environment]::NewLine)))

  if (Test-IsAdministrator) {
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
      -NoProfile -EncodedCommand $encodedCommand
    return $LASTEXITCODE
  }

  Write-Warn "Windows will request administrator permission once to remove the system daemon."
  $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -ArgumentList @("-NoProfile", "-EncodedCommand", $encodedCommand) `
    -Verb RunAs -Wait -PassThru
  if ($null -eq $process) {
    throw "Administrator permission was not granted"
  }
  return $process.ExitCode
}

function Remove-HubboundAgentTask {
  param(
    [string]$WorkDir,
    [string]$LogPath,
    [string[]]$AgentPaths
  )

  # The installer uses this current-user value only when Task Scheduler is not
  # available. Remove it in the original desktop-user process, before UAC can
  # change the registry context on machines with separate admin credentials.
  $runKeyPath = "Software\Microsoft\Windows\CurrentVersion\Run"
  $runKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runKeyPath, $true)
  if ($null -ne $runKey) {
    try { $runKey.DeleteValue("HubboundAgent", $false) }
    finally { $runKey.Dispose() }
  }

  # Do not use the ScheduledTasks cmdlets here. A previous installer could
  # have created the task under a different owner/SID, in which case those
  # cmdlets can report "not found" while the Task Scheduler still retains it.
  # schtasks queries the scheduler directly, and the elevated runner can
  # remove an orphan created by an Administrator or an interrupted install.
  $schtasks = Join-Path $env:SystemRoot "System32\schtasks.exe"
  $taskName = "HubboundAgent"
  $taskLit = ConvertTo-SingleQuotedPsLiteral $taskName
  $schtasksLit = ConvertTo-SingleQuotedPsLiteral $schtasks
  $agentLits = @($AgentPaths | ForEach-Object { ConvertTo-SingleQuotedPsLiteral $_ }) -join ", "

  $exitCode = Invoke-ElevatedScript -WorkDir $WorkDir -LogPath $LogPath -Lines (@(Get-ElevatedGuardLines -Components @("Runtime")) + @(
    "`$taskName = $taskLit"
    "`$schtasks = $schtasksLit"
    "`$agentPaths = @($agentLits)"
    "& `$schtasks /End /TN `$taskName 2>`$null | Out-Null"
    "& `$schtasks /Delete /TN `$taskName /F 2>`$null | Out-Null"
    # Stop only Hubbound's managed agent instances, never a same-named
    # executable from an unrelated location.
    "Get-CimInstance -ClassName Win32_Process -Filter `"Name = 'hubbound-agent.exe'`" -ErrorAction SilentlyContinue | ForEach-Object { if (`$_.ExecutablePath -and (`$agentPaths -contains `$_.ExecutablePath)) { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue } }"
    "& `$schtasks /Query /TN `$taskName 2>`$null | Out-Null"
    "if (`$LASTEXITCODE -eq 0) { exit 1 }"
    "exit 0"
  ))

  if ($exitCode -eq 0) {
    Write-Ok "User startup registration removed (or was already absent)"
  } elseif ($exitCode -eq $ExitNewerInstall) {
    Write-Warn "A newer HubBound installation was detected; leaving its startup registration in place"
  } else {
    Write-Warn "Could not verify removal of scheduled task '$taskName' (exit $exitCode)"
  }
}

function Remove-PathIfExists {
  param([string]$Path, [string]$Label)
  Write-Detail "Path: $Path"
  if (Test-Path -LiteralPath $Path) {
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Path) {
      Write-Warn "Could not fully remove $Label (may need elevation)"
      return $false
    }
    Write-Ok "$Label removed"
    return $true
  }
  return $false
}

# Telemetry spool lives at {system_root}\analytics. -KeepData must relocate it
# into the matching AppData\Roaming\{hubbound|hubbound-lab}\analytics BEFORE
# helper system uninstall RemoveAll's the system root.
function Preserve-SystemTelemetry {
  param(
    [string[]]$Roots,
    [string]$AppDataRoot,
    [string]$WorkDir,
    [string]$LogPath
  )

  Write-Step "Preserving system telemetry (analytics)"
  $preserved = 0
  foreach ($root in $Roots) {
    $src = Join-Path $root "analytics"
    if (-not (Test-Path -LiteralPath $src)) { continue }
    $name = Split-Path -Leaf $root
    $destParent = Join-Path $AppDataRoot $name
    $dest = Join-Path $destParent "analytics"
    Write-Detail "From: $src"
    Write-Detail "To:   $dest"

    if (-not (Test-Path -LiteralPath $destParent)) {
      New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }
    if ((Test-Path -LiteralPath $dest) -and (Get-ChildItem -LiteralPath $dest -Force -ErrorAction SilentlyContinue)) {
      $stash = "$dest.user-prior.$((Get-Date).ToString('yyyyMMddHHmmss'))"
      Move-Item -LiteralPath $dest -Destination $stash -Force
      Write-Detail "Existing user analytics moved aside: $stash"
    }
    Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue

    $srcLit = ConvertTo-SingleQuotedPsLiteral $src
    $destLit = ConvertTo-SingleQuotedPsLiteral $dest
    $exitCode = Invoke-ElevatedScript -WorkDir $WorkDir -LogPath $LogPath -Lines @(
      "New-Item -ItemType Directory -Path (Split-Path -Parent $destLit) -Force | Out-Null"
      "Copy-Item -LiteralPath $srcLit -Destination $destLit -Recurse -Force"
      "if (-not (Test-Path -LiteralPath $destLit)) { exit 1 }"
      "exit 0"
    )
    if ($exitCode -eq 0) {
      # Drop inherited Admin ACLs so the desktop user owns the preserved spool.
      try {
        $acl = Get-Acl -LiteralPath $dest
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($user, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.SetAccessRule($rule)
        Set-Acl -LiteralPath $dest -AclObject $acl
      } catch {
        Write-Warn "Preserved analytics but could not adjust ACLs: $($_.Exception.Message)"
      }
      Write-Ok "Preserved telemetry for $name"
      $preserved++
    } else {
      Write-Warn "Could not preserve analytics from $root"
    }
  }
  if ($preserved -eq 0) {
    Write-Warn "No system analytics spool found to preserve"
  }
}

# --- PowerShell provider cleanup (fallback when Go is unavailable) ----------
# Mirrors scripts/dev/purge-providers.go on a best-effort basis: only entries
# the installer marked as its own (hubbound.source = hubbound) are touched.

function Read-JsonFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if (-not $raw -or -not $raw.Trim()) { return $null }
    return ($raw | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    Write-Warn "Could not parse $Path (left untouched)"
    return $null
  }
}

function Write-JsonFile {
  param([string]$Path, $Document)
  $json = $Document | ConvertTo-Json -Depth 100
  # No BOM: Go's encoding/json rejects a leading byte-order mark.
  [IO.File]::WriteAllText($Path, $json + "`n", (New-Object Text.UTF8Encoding($false)))
}

function Get-JsonProperty {
  param($Object, [string]$Name)
  if ($null -eq $Object) { return $null }
  $properties = $null
  try { $properties = $Object.PSObject.Properties } catch { return $null }
  if ($null -eq $properties) { return $null }
  return ($properties | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)
}

function Test-HubboundEntry {
  param($Entry)
  $marker = Get-JsonProperty -Object $Entry -Name "hubbound"
  if ($null -eq $marker) { return $false }
  $source = Get-JsonProperty -Object $marker.Value -Name "source"
  return ($null -ne $source -and $source.Value -eq "hubbound")
}

# Hooks the Go installers wrote carry no marker: they run `hubbound ... hook`, the
# provenance capture script (hubbound-hook-capture.*) or a script kept under a
# hubbound-hooks directory.
# Go writes Windows hooks as `powershell ... -EncodedCommand <base64 UTF-16LE>`: the
# command line only carries the payload, so decode it before matching.
function Expand-HubboundHookCommand {
  param([string]$Text)
  $match = [regex]::Match($Text, '-EncodedCommand\s+([A-Za-z0-9+/=]+)')
  if (-not $match.Success) { return $Text }
  try {
    $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($match.Groups[1].Value))
    return "$Text`n$decoded"
  } catch { return $Text }
}

function Test-HubboundHookEntry {
  param($Entry)
  if (Test-HubboundEntry -Entry $Entry) { return $true }
  foreach ($key in @("command", "command_windows", "commandWindows", "bash", "powershell")) {
    $property = Get-JsonProperty -Object $Entry -Name $key
    if ($null -eq $property -or $property.Value -isnot [string]) { continue }
    $text = Expand-HubboundHookCommand -Text $property.Value
    if ($text -match 'hubbound(\.exe)?[''"]?\s+(memory|workspace|live-docs|live-planning)\s+hook\b') { return $true }
    if ($text -match 'hubbound-hook-capture\.(sh|ps1)|[/\\]hubbound-hooks[/\\]') { return $true }
  }
  return $false
}

function Remove-HubboundMcpServers {
  param([string]$Path)
  $doc = Read-JsonFile -Path $Path
  if ($null -eq $doc) { return }
  $servers = Get-JsonProperty -Object $doc -Name "mcpServers"
  if ($null -eq $servers -or $null -eq $servers.Value) { return }

  $removed = @()
  foreach ($server in @($servers.Value.PSObject.Properties)) {
    if (Test-HubboundEntry -Entry $server.Value) { $removed += $server.Name }
  }
  if ($removed.Count -eq 0) { return }

  foreach ($name in $removed) { $servers.Value.PSObject.Properties.Remove($name) }
  Write-JsonFile -Path $Path -Document $doc
  Write-Detail "Removed MCP server(s) from ${Path}: $($removed -join ', ')"
}

# The Go installers write the HubBound MCP servers without an ownership marker,
# so the fallback recognises them by name AND by running the hubbound CLI; a
# server a user registered under the same name with another command is kept.
$HubboundServerNames = @("hubbound-memories", "hubbound-live-docs", "hubbound-toolkit", "hubbound-artifacts")

function Test-RunsHubbound {
  param($Command)
  if ($Command -is [Array]) { $Command = if ($Command.Count -gt 0) { $Command[0] } else { $null } }
  if ($Command -isnot [string] -or [string]::IsNullOrWhiteSpace($Command)) { return $false }
  $leaf = Split-Path -Leaf ($Command -replace '/', '\')
  return ($leaf -eq "hubbound" -or $leaf -eq "hubbound.exe")
}

function Remove-HubboundNamedMcp {
  param([string]$Path)
  $doc = Read-JsonFile -Path $Path
  if ($null -eq $doc) { return }
  $changed = $false
  foreach ($rootName in @("mcpServers", "servers", "mcp")) {
    $servers = Get-JsonProperty -Object $doc -Name $rootName
    if ($null -eq $servers -or $null -eq $servers.Value) { continue }
    foreach ($name in $HubboundServerNames) {
      $entry = Get-JsonProperty -Object $servers.Value -Name $name
      if ($null -eq $entry) { continue }
      $command = Get-JsonProperty -Object $entry.Value -Name "command"
      if ($null -ne $command -and (Test-RunsHubbound -Command $command.Value)) {
        $servers.Value.PSObject.Properties.Remove($name)
        Write-Detail "Removed MCP server ${name} from $Path"
        $changed = $true
      }
    }
  }
  if ($changed) { Write-JsonFile -Path $Path -Document $doc }
}

function Remove-HubboundHookEntries {
  param([string]$Path)
  $doc = Read-JsonFile -Path $Path
  if ($null -eq $doc) { return }
  $hooksProperty = Get-JsonProperty -Object $doc -Name "hooks"
  if ($null -eq $hooksProperty -or $null -eq $hooksProperty.Value) { return }

  $hooksRoot = $hooksProperty.Value
  $changed = $false
  $emptyEvents = @()

  foreach ($hookEvent in @($hooksRoot.PSObject.Properties)) {
    $entries = $hookEvent.Value
    if ($null -eq $entries -or $entries -isnot [Array]) { continue }

    $kept = @()
    foreach ($entry in $entries) {
      # Cursor stores handlers directly; Claude nests them under a group.
      if (Test-HubboundHookEntry -Entry $entry) { $changed = $true; continue }
      $nested = Get-JsonProperty -Object $entry -Name "hooks"
      if ($null -ne $nested -and $nested.Value -is [Array]) {
        $handlers = @($nested.Value)
        $keptHandlers = @($handlers | Where-Object { -not (Test-HubboundHookEntry -Entry $_) })
        if ($keptHandlers.Count -ne $handlers.Count) { $changed = $true }
        if ($keptHandlers.Count -eq 0) { continue }
        $nested.Value = $keptHandlers
      }
      $kept += $entry
    }

    if ($kept.Count -eq 0) { $emptyEvents += $hookEvent.Name } else { $hookEvent.Value = $kept }
  }

  foreach ($name in $emptyEvents) { $hooksRoot.PSObject.Properties.Remove($name) }
  if (-not $changed) { return }

  Write-JsonFile -Path $Path -Document $doc
  Write-Detail "Removed hook entries from $Path"
}

function Remove-HubboundSkillDirs {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  foreach ($dir in @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue)) {
    $marker = Join-Path $dir.FullName ".hubbound.json"
    if (-not (Test-Path -LiteralPath $marker)) { continue }
    $doc = Read-JsonFile -Path $marker
    $source = Get-JsonProperty -Object $doc -Name "source"
    if ($null -eq $source -or $source.Value -ne "hubbound") { continue }
    Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
    Write-Detail "Removed skill: $($dir.FullName)"
  }
}

function Remove-HubboundArtifactFiles {
  param([string]$Path, [string]$Filter)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Filter $Filter -Force -ErrorAction SilentlyContinue)) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content -or -not $content.Contains("<!-- hubbound:artifact")) { continue }
    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    Write-Detail "Removed artifact: $($file.FullName)"
  }
}

# Gemini/Antigravity hooks.json keeps one hubbound-artifact-<id> block per hook artifact.
# True when any command nested in a hook block is a HubBound hook command.
function Test-HubboundHookBlock {
  param($Block)
  if ($null -eq $Block) { return $false }
  if ($Block -is [string]) { return $false }
  if ($Block -is [Array]) {
    foreach ($item in $Block) { if (Test-HubboundHookBlock -Block $item) { return $true } }
    return $false
  }
  if (Test-HubboundHookEntry -Entry $Block) { return $true }
  $properties = $null
  try { $properties = $Block.PSObject.Properties } catch { return $false }
  foreach ($property in @($properties)) {
    if ($property.Value -isnot [string] -and (Test-HubboundHookBlock -Block $property.Value)) { return $true }
  }
  return $false
}

function Remove-HubboundHookBlocks {
  param([string]$Path)
  $doc = Read-JsonFile -Path $Path
  if ($null -eq $doc) { return }
  # Distributed artifacts (hubbound-artifact-*) and the Go-installed hubbound-workspace /
  # hubbound-live-docs / hubbound-memories blocks, matched by their HubBound hook command.
  $names = @($doc.PSObject.Properties | Where-Object {
      $_.Name -like "hubbound-artifact-*" -or ($_.Name -like "hubbound-*" -and (Test-HubboundHookBlock -Block $_.Value))
    } | ForEach-Object { $_.Name })
  if ($names.Count -eq 0) { return }
  foreach ($name in $names) { $doc.PSObject.Properties.Remove($name) }
  Write-JsonFile -Path $Path -Document $doc
  Write-Detail "Removed hook block(s) from ${Path}: $($names -join ', ')"
}

# Copilot keeps one hooks file per HubBound feature: ~/.copilot/hooks/hubbound-*.json.
function Remove-HubboundHookFiles {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Filter "hubbound-*.json" -Force -ErrorAction SilentlyContinue)) {
    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    Write-Detail "Removed hook file: $($file.FullName)"
  }
}

# OpenCode hook artifacts are plugins named hubbound-hook-*.ts that open with a marker line.
function Remove-HubboundHookPlugins {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Filter "hubbound-hook-*.ts" -Force -ErrorAction SilentlyContinue)) {
    $head = Get-Content -LiteralPath $file.FullName -TotalCount 3 -ErrorAction SilentlyContinue
    if ($null -eq $head -or -not (($head -join "`n").Contains("// hubbound:artifact "))) { continue }
    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    Write-Detail "Removed plugin: $($file.FullName)"
  }
}

# OpenCode plugins written by the Memories, Workspace and Live Documents installers: a file or a
# directory whose content opens with the "HubBound managed" ownership header.
function Remove-HubboundOwnedPlugin {
  param([string]$Path)
  $header = "HubBound managed"
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    $head = Get-Content -LiteralPath $Path -TotalCount 3 -ErrorAction SilentlyContinue
    if ($null -ne $head -and ($head -join "`n").Contains($header)) {
      Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
      Write-Detail "Removed plugin: $Path"
    }
  } elseif (Test-Path -LiteralPath $Path -PathType Container) {
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Force -ErrorAction SilentlyContinue)) {
      $head = Get-Content -LiteralPath $file.FullName -TotalCount 3 -ErrorAction SilentlyContinue
      if ($null -ne $head -and ($head -join "`n").Contains($header)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        Write-Detail "Removed plugin: $Path"
        return
      }
    }
  }
}

# The capture plugin is referenced from opencode.json (hubbound/hubbound-capture*).
function Remove-HubboundOpenCodePluginEntries {
  param([string]$Path)
  $doc = Read-JsonFile -Path $Path
  if ($null -eq $doc) { return }
  $plugins = Get-JsonProperty -Object $doc -Name "plugin"
  if ($null -eq $plugins -or $plugins.Value -isnot [Array]) { return }
  $entries = @($plugins.Value)
  $kept = @($entries | Where-Object {
      $name = if ($_ -is [Array] -and $_.Count -gt 0) { $_[0] } else { $_ }
      -not ($name -is [string] -and $name -match '[/\\]hubbound[/\\]hubbound-capture')
    })
  if ($kept.Count -eq $entries.Count) { return }
  $plugins.Value = $kept
  Write-JsonFile -Path $Path -Document $doc
  Write-Detail "Removed the capture plugin entry from $Path"
}

# Removes the <!-- hubbound:artifact ... BEGIN/END --> blocks of an instruction file.
function Remove-HubboundMarkdownBlocks {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $original = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
  if ([string]::IsNullOrEmpty($original)) { return }
  $pattern = '(?s)<!-- hubbound:artifact [^>]+ BEGIN -->.*?<!-- hubbound:artifact [^>]+ END -->\r?\n?'
  $cleaned = [regex]::Replace($original, $pattern, "")
  if ($cleaned -eq $original) { return }
  [IO.File]::WriteAllText($Path, $cleaned.Trim() + "`n", (New-Object Text.UTF8Encoding($false)))
  Write-Detail "Removed HubBound blocks from $Path"
}

function Invoke-ProviderCleanupFallback {
  param([string]$HomeDir, [string[]]$EditorDirs)

  foreach ($dir in $EditorDirs) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Detail "Removed: $dir"
  }

  Remove-HubboundMcpServers -Path (Join-Path $HomeDir ".mcp.json")
  Remove-HubboundMcpServers -Path (Join-Path $HomeDir ".cursor\mcp.json")
  foreach ($mcpFile in @(
      ".claude.json", ".cursor\mcp.json", ".copilot\mcp-config.json",
      ".gemini\config\mcp_config.json", ".gemini\antigravity-cli\mcp_config.json",
      "AppData\Roaming\Code\User\mcp.json")) {
    Remove-HubboundNamedMcp -Path (Join-Path $HomeDir $mcpFile)
  }
  $McpConfigHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HomeDir ".config" }
  foreach ($mcpFile in @("opencode\opencode.json", "muse\settings.json")) {
    Remove-HubboundNamedMcp -Path (Join-Path $McpConfigHome $mcpFile)
  }
  $ConfigHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HomeDir ".config" }
  Remove-HubboundHookEntries -Path (Join-Path $HomeDir ".cursor\hooks.json")
  Remove-HubboundHookEntries -Path (Join-Path $HomeDir ".claude\settings.json")
  Remove-HubboundHookEntries -Path (Join-Path $HomeDir ".codex\hooks.json")
  # Muse settings.json shares the Claude hooks layout.
  Remove-HubboundHookEntries -Path (Join-Path $ConfigHome "muse\settings.json")
  Remove-HubboundHookBlocks -Path (Join-Path $HomeDir ".gemini\config\hooks.json")
  Remove-HubboundHookFiles -Path (Join-Path $HomeDir ".copilot\hooks")
  Remove-HubboundOpenCodePluginEntries -Path (Join-Path $ConfigHome "opencode\opencode.json")
  Remove-HubboundHookPlugins -Path (Join-Path $ConfigHome "opencode\plugins")
  foreach ($plugin in @("hubbound-memories.js", "hubbound-memories-v2", "hubbound-workspace.js", "hubbound-workspace-v2", "hubbound-live-docs.js", "hubbound-live-docs-v2")) {
    Remove-HubboundOwnedPlugin -Path (Join-Path $ConfigHome "opencode\plugins\$plugin")
  }

  foreach ($skills in @(".claude\skills", ".cursor\skills", ".copilot\skills", ".gemini\skills", ".gemini\config\skills", ".agents\skills")) {
    Remove-HubboundSkillDirs -Path (Join-Path $HomeDir $skills)
  }
  foreach ($tool in @("opencode", "muse")) {
    Remove-HubboundSkillDirs -Path (Join-Path $ConfigHome "$tool\skills")
    Remove-HubboundMarkdownBlocks -Path (Join-Path $ConfigHome "$tool\AGENTS.md")
  }
  foreach ($block in @(".claude\CLAUDE.md", ".codex\AGENTS.md", ".copilot\copilot-instructions.md", ".gemini\GEMINI.md")) {
    Remove-HubboundMarkdownBlocks -Path (Join-Path $HomeDir $block)
  }
  Remove-HubboundArtifactFiles -Path (Join-Path $ConfigHome "opencode\command") -Filter "*.md"
  Remove-HubboundArtifactFiles -Path (Join-Path $ConfigHome "opencode\agent") -Filter "*.md"

  Remove-HubboundArtifactFiles -Path (Join-Path $HomeDir ".claude\rules") -Filter "*.md"
  Remove-HubboundArtifactFiles -Path (Join-Path $HomeDir ".claude\agents") -Filter "*.md"
  Remove-HubboundArtifactFiles -Path (Join-Path $HomeDir ".cursor\rules") -Filter "*.mdc"
  Remove-HubboundArtifactFiles -Path (Join-Path $HomeDir ".cursor\agents") -Filter "*.md"
  Remove-HubboundArtifactFiles -Path (Join-Path $HomeDir ".copilot\agents") -Filter "*.agent.md"
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($KeepData -and $PurgeData) {
  throw "-KeepData and -PurgeData cannot be combined"
}

if ($Preview) {
  Write-Title "hubbound: Full uninstall (Windows)"
  Write-Host ""
  Write-Step "Stopping + removing hubboundd Windows service"
  Write-Ok "Daemon uninstalled via hubbound-helper system uninstall"
  Write-Step "Removing HubBound Runtime MSI"
  Write-Ok "HubBound Runtime MSI removed"
  Write-Step "Force-removing orphaned Windows service"
  Write-Warn "Service not found, nothing to remove"
  Write-Step "Removing HubboundAgent user startup registration"
  Write-Ok "User startup registration removed"
  Write-Step "Removing system root"
  Write-Ok "System root removed"
  Write-Step "Removing HubBound CLI MSI registration"
  Write-Ok "HubBound CLI MSI removed"
  Write-Step "Removing user bin"
  Write-Ok "User bin removed"
  Write-Step "Removing user state + cache"
  Write-Ok "User state removed"
  Write-Step "Removing per-editor integration dirs"
  Write-Warn "No editor integration dirs found"
  Write-Step "Removing user PATH entry"
  Write-Ok "Removed Hubbound bin from user PATH"
  Write-Step "Cleaning provider integrations"
  Write-Warn "Provider cleanup skipped in preview"
  Write-Host ""
  Write-Color "Uninstall complete. hubbound is fully removed." Green
  Write-Host ""
  Write-Detail "Reinstall with: $ReinstallCommand"
  exit 0
}

# Resolve Windows paths only after Preview: Linux pwsh containers lack
# ProgramData / LOCALAPPDATA / APPDATA.
$ProgramData = Get-HubboundProgramData
$LocalAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE "AppData\Local" }
$AppData = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $env:USERPROFILE "AppData\Roaming" }
$HomeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }

# Release builds install under "hubbound"; dev builds under "hubbound-lab".
# Without an explicit override both layouts may exist, so remove both.
$DataDirNames = @("hubbound", "hubbound-lab")
if ($env:HUBBOUND_SYSTEM_ROOT) {
  throw "Custom Windows system roots are not supported by the trusted uninstaller; use the machine-wide ProgramData root"
}
$SystemRoots = @($DataDirNames | ForEach-Object { Join-Path $ProgramData $_ })

$UserBin = if ($env:HUBBOUND_USER_BIN) { $env:HUBBOUND_USER_BIN } else { Join-Path $LocalAppData "Hubbound\bin" }
$UserStateDirs = @($DataDirNames | ForEach-Object { Join-Path $AppData $_ })
$UserCacheDirs = @($DataDirNames | ForEach-Object { Join-Path $LocalAppData $_ })

# Muse and OpenCode keep their configuration under XDG_CONFIG_HOME.
$EditorConfigHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HomeDir ".config" }

$EditorDirs = @(
  (Join-Path $HomeDir ".claude\hubbound"),
  (Join-Path $HomeDir ".claude\hubbound-hooks"),
  (Join-Path $HomeDir ".cursor\hubbound"),
  (Join-Path $HomeDir ".cursor\hubbound-hooks"),
  (Join-Path $HomeDir ".codex\hubbound"),
  (Join-Path $HomeDir ".codex\hubbound-hooks"),
  (Join-Path $HomeDir ".copilot\hubbound"),
  (Join-Path $HomeDir ".copilot\hubbound-hooks"),
  (Join-Path $HomeDir ".gemini\hubbound"),
  (Join-Path $HomeDir ".gemini\hubbound-hooks"),
  (Join-Path $HomeDir ".antigravity\hubbound"),
  (Join-Path $EditorConfigHome "muse\hubbound"),
  (Join-Path $EditorConfigHome "muse\hubbound-hooks"),
  (Join-Path $EditorConfigHome "opencode\hubbound"),
  (Join-Path $EditorConfigHome "opencode\hubbound-hooks")
)

$AgentPaths = @($SystemRoots | ForEach-Object { Join-Path $_ "current\hubbound-agent.exe" })
$AgentPaths += (Join-Path $UserBin "hubbound-agent.exe")

# --- Organization uninstall policy (HUB-173) ----------------------------------
# Removing the suite removes every governed feature, so it is refused, before
# anything is touched, when the organization forbids uninstalling any of them.
# The CLI prints the red notice. Exit 77 is the policy denial; any other result
# (CLI missing or older, device not enrolled, offline with no cached policy)
# never blocks the uninstall.
$PolicyCli = Join-Path $UserBin "hubbound.exe"
if (-not (Test-Path -LiteralPath $PolicyCli)) {
  $PolicyCmd = Get-Command hubbound.exe -ErrorAction SilentlyContinue
  $PolicyCli = if ($PolicyCmd) { $PolicyCmd.Source } else { $null }
}
if ($PolicyCli) {
  $global:LASTEXITCODE = 0
  try {
    & $PolicyCli internal policy-check --suite
  } catch {
    $global:LASTEXITCODE = 0
  }
  if ($LASTEXITCODE -eq 77) { exit 1 }
}

# --- MSI snapshot (HUBJ-314) ---------------------------------------------------
# Record the HubBound MSI products that exist now, before the data prompt and
# before any UAC prompt. Every destructive step below re-checks against this
# snapshot so an installation made after the uninstall started (Setup run while
# a prompt was still open) is never torn down.
$MsiSnapshot = Get-HubboundMsiSnapshot
$RuntimeMsiPresent = @($MsiSnapshot | Where-Object { $_ -like "Runtime|*" }).Count -gt 0
$CliMsiPresent = @($MsiSnapshot | Where-Object { $_ -like "CLI|*" }).Count -gt 0

$KeepUserData = $false
if ($KeepData) {
  $KeepUserData = $true
} elseif ($PurgeData) {
  $KeepUserData = $false
} elseif ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
  $existingState = @($UserStateDirs | Where-Object { Test-Path -LiteralPath $_ })
  $stateLabel = if ($existingState.Count -gt 0) { $existingState -join ", " } else { $UserStateDirs[0] }
  Write-Host ""
  Write-Host "What should be removed?"
  Write-Host "  1) Binaries only - keep user data at $stateLabel"
  Write-Host "  2) Full uninstall - also delete user data"
  Write-Host ""
  $choice = Read-Host "Choice [1/2] (default 1)"
  switch -Regex ($choice) {
    '^(2|full|purge|all|y|Y)$' { $KeepUserData = $false }
    default { $KeepUserData = $true }
  }
} else {
  # Never guess at destroying user data in automation. An explicit flag is the
  # only way to run unattended.
  throw "Non-interactive run requires -KeepData or -PurgeData"
}

if ($KeepUserData) {
  Write-Title "hubbound: Uninstall (keep user data) (Windows)" Yellow
} else {
  Write-Title "hubbound: Full uninstall (Windows)"
}
Write-Host ""
foreach ($entry in $MsiSnapshot) { Write-Detail "MSI product: $entry" }

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
New-Item -ItemType Directory -Path $Tmp | Out-Null
try {
  $logPath = Join-Path $env:TEMP "hubbound-helper-uninstall.log"
  $ExistingRoots = @($SystemRoots | Where-Object { Test-Path -LiteralPath $_ })

  if ($KeepUserData -and $ExistingRoots.Count -gt 0) {
    Preserve-SystemTelemetry -Roots $ExistingRoots -AppDataRoot $AppData -WorkDir $Tmp -LogPath $logPath
  }

  # --- Report the uninstall (HUB-171) -----------------------------------------
  # Tell the organization while the CLI and device credential still exist.
  # Best effort: bounded by a timeout and never able to stop the uninstall.
  # The helper below removes the service without going through `hubbound
  # daemon uninstall`, so the daemon is reported here too.
  $reportCli = Join-Path $UserBin "hubbound.exe"
  if (-not (Test-Path -LiteralPath $reportCli)) {
    $reportCmd = Get-Command hubbound.exe -ErrorAction SilentlyContinue
    $reportCli = if ($reportCmd) { $reportCmd.Source } else { $null }
  }
  if ($reportCli) {
    try {
      $reportProc = Start-Process -FilePath $reportCli -ArgumentList @("internal", "feature-event", "--feature", "cli", "--feature", "daemon", "--sync") -WindowStyle Hidden -PassThru -ErrorAction Stop
      if (-not $reportProc.WaitForExit(10000)) { Stop-Process -Id $reportProc.Id -Force -ErrorAction SilentlyContinue }
    } catch {
      Write-Detail "Uninstall report skipped: $($_.Exception.Message)"
    }
  }

  # --- Provenance capture ---------------------------------------------------
  # Owned by the daemon (global Trace2 git configuration), so it is switched off
  # while the daemon still answers. Best effort, hidden, bounded.
  if ($reportCli) {
    Write-Step "Disabling provenance capture"
    try {
      $provProc = Start-Process -FilePath $reportCli -ArgumentList @("provenance", "remove") -WindowStyle Hidden -PassThru -ErrorAction Stop
      if (-not $provProc.WaitForExit(20000)) {
        Stop-Process -Id $provProc.Id -Force -ErrorAction SilentlyContinue
        Write-Warn "Provenance capture did not answer in time"
      } elseif ($provProc.ExitCode -eq 0) {
        Write-Ok "Provenance capture disabled"
      } else {
        Write-Warn "Could not disable provenance capture (the daemon may be stopped already)"
      }
    } catch {
      Write-Detail "Provenance capture skipped: $($_.Exception.Message)"
    }
  }

  # --- Daemon / system uninstall (elevated) ---------------------------------
  Write-Step "Stopping + removing hubboundd Windows service"

  $FallbackHelper = $null
  $userBinHelper = Join-Path $UserBin "hubbound-helper.exe"
  if (Test-Path -LiteralPath $userBinHelper) {
    $FallbackHelper = $userBinHelper
  } else {
    $cmd = Get-Command hubbound-helper.exe -ErrorAction SilentlyContinue
    if ($cmd) { $FallbackHelper = $cmd.Source }
  }

  # One elevated batch for every install layout keeps UAC to a single prompt.
  # Its first lines re-check the MSI snapshot: nothing is removed when a
  # newer Runtime was installed while the UAC prompt was open. $failed is a
  # bit mask: 1 = helper uninstall failed, 2 = MSI removal failed.
  $helperLines = @(Get-ElevatedGuardLines -Components @("Runtime") -WithUninstall)
  $helperLines += '$failed = 0'
  $helperTargets = 0
  $logLit = ConvertTo-SingleQuotedPsLiteral $logPath
  foreach ($root in $ExistingRoots) {
    $rootHelper = Join-Path $root "current\hubbound-helper.exe"
    $helper = if (Test-Path -LiteralPath $rootHelper) { $rootHelper } else { $FallbackHelper }
    if (-not $helper) { continue }
    Write-Detail "Helper: $helper (root: $root)"
    $helperLit = ConvertTo-SingleQuotedPsLiteral $helper
    $rootLit = ConvertTo-SingleQuotedPsLiteral $root
    $helperLines += "& $helperLit system uninstall --system-root $rootLit *>> $logLit"
    $helperLines += 'if ($LASTEXITCODE -ne 0) { $failed = 1 }'
    $helperTargets++
  }

  # The Runtime MSI is removed after the helper has stopped the daemon, so the
  # registration disappears together with the service and its files.
  if ($RuntimeMsiPresent) {
    $helperLines += "`$msiFailed = Uninstall-HubboundMsiProducts -Snapshot `$msiSnapshot -Components @('Runtime') 6>> $logLit"
    $helperLines += 'if ($msiFailed -ne 0) { $failed = $failed -bor 2 }'
  }

  if ($helperTargets -gt 0 -or $RuntimeMsiPresent) {
    $helperLines += 'exit $failed'
    $exitCode = Invoke-ElevatedScript -WorkDir $Tmp -LogPath $logPath -Lines $helperLines
    if ($exitCode -eq 0) {
      if ($helperTargets -gt 0) { Write-Ok "Daemon uninstalled via 'hubbound-helper system uninstall'" }
      if ($RuntimeMsiPresent) { Write-Ok "HubBound Runtime MSI removed" }
    } elseif ($exitCode -eq $ExitNewerInstall) {
      Write-Warn "A newer HubBound Runtime installation was detected; leaving the service, its files and its MSI registration in place"
    } else {
      if (($exitCode -band 1) -ne 0) { Write-Warn "Helper system uninstall failed/not installed (exit $exitCode), continuing" }
      if (($exitCode -band 2) -ne 0) { Write-Warn "Could not remove the HubBound Runtime MSI (see $logPath); Setup may still report it as installed" }
      if ($exitCode -lt 0 -or $exitCode -gt 3) { Write-Warn "Elevated Runtime uninstall ended with exit $exitCode, continuing" }
    }
  } else {
    Write-Warn "hubbound-helper not found, skipping helper uninstall"
  }

  # Belt and suspenders: helper uninstall depends on the binary still being
  # runnable. Partial installs leave an orphaned SCM service that blocks the
  # next system install.
  Write-Step "Force-removing orphaned Windows service"
  Write-Detail "Service name: hubboundd"
  $svc = Get-Service -Name "hubboundd" -ErrorAction SilentlyContinue
  if ($svc -and (Test-NewerInstallSkip -Component "Runtime" -What "the hubboundd service")) {
    # A newer Runtime owns the service now.
  } elseif ($svc) {
    $exitCode = Invoke-ElevatedScript -WorkDir $Tmp -LogPath $logPath -Lines (@(Get-ElevatedGuardLines -Components @("Runtime")) + @(
      'Stop-Service -Name hubboundd -Force -ErrorAction SilentlyContinue'
      'sc.exe delete hubboundd | Out-Null'
      'if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }'
      'exit 0'
    ))
    if ($exitCode -eq 0) {
      Write-Ok "Windows service removed"
    } elseif ($exitCode -eq $ExitNewerInstall) {
      Write-Warn "A newer HubBound installation was detected; leaving the hubboundd service in place"
    } else {
      Write-Warn "Could not delete hubboundd service (exit $exitCode)"
    }
  } else {
    Write-Warn "Service not found, nothing to remove"
  }

  # --- AI tool integrations, through the CLI --------------------------------
  # The installers that wrote the MCP servers (memories, live documents,
  # artifacts), hooks, skills and instruction blocks know their ownership
  # rules, so they remove them while the CLI still exists. The daemon is gone,
  # so nothing re-adds them. The fallback below handles an older or missing CLI.
  Write-Step "Removing MCP servers, hooks and skills from your AI tools"
  if ($reportCli) {
    try {
      & $reportCli internal remove-integrations
      if ($LASTEXITCODE -eq 0) {
        Write-Ok "Integrations removed via 'hubbound internal remove-integrations'"
      } else {
        Write-Warn "'hubbound internal remove-integrations' failed (older CLI?); using the built-in cleaner"
      }
    } catch {
      Write-Warn "'hubbound internal remove-integrations' failed: $($_.Exception.Message)"
    }
  } else {
    Write-Warn "hubbound not found; using the built-in cleaner"
  }

  # --- User agent autostart -------------------------------------------------
  Write-Step "Removing HubboundAgent user startup registration"
  Remove-HubboundAgentTask -WorkDir $Tmp -LogPath $logPath -AgentPaths $AgentPaths

  # --- System roots (force if the helper left leftovers) --------------------
  Write-Step "Removing system root"
  if ($ExistingRoots.Count -gt 0 -and (Test-NewerInstallSkip -Component "Runtime" -What "the HubBound system root")) {
    # A newer Runtime owns the system root now.
  } elseif ($ExistingRoots.Count -gt 0) {
    $rootLines = @(Get-ElevatedGuardLines -Components @("Runtime"))
    foreach ($root in $ExistingRoots) {
      Write-Detail "Path: $root"
      $rootLit = ConvertTo-SingleQuotedPsLiteral $root
      $rootLines += "Remove-Item -LiteralPath $rootLit -Recurse -Force -ErrorAction SilentlyContinue"
      $rootLines += "if (Test-Path -LiteralPath $rootLit) { exit 1 }"
    }
    $rootLines += "exit 0"
    $exitCode = Invoke-ElevatedScript -WorkDir $Tmp -LogPath $logPath -Lines $rootLines
    if ($exitCode -eq 0) {
      Write-Ok "System root removed"
    } elseif ($exitCode -eq $ExitNewerInstall) {
      Write-Warn "A newer HubBound installation was detected; leaving the system root in place"
    } else {
      Write-Warn "System root still present after elevated remove"
    }
  } else {
    foreach ($root in $SystemRoots) { Write-Detail "Path: $root" }
    Write-Warn "System root not found"
  }

  # --- CLI MSI (per-user, no elevation) ---------------------------------------
  Write-Step "Removing HubBound CLI MSI registration"
  $SkipCliCleanup = $false
  if ($CliMsiPresent) {
    if (Test-NewerInstallSkip -Component "CLI" -What "the HubBound CLI") {
      $SkipCliCleanup = $true
    } else {
      $cliMsiFailed = Uninstall-HubboundMsiProducts -Snapshot $MsiSnapshot -Components @("CLI")
      if ($cliMsiFailed -ne 0) { Write-Warn "Could not remove the HubBound CLI MSI; Setup may still report it as installed" }
    }
  } else {
    Write-Detail "No HubBound CLI MSI is registered"
  }

  # --- User bin copies ------------------------------------------------------
  Write-Step "Removing user bin"
  Write-Detail "Path: $UserBin"
  if ($SkipCliCleanup -or (Test-NewerInstallSkip -Component "CLI" -What "the HubBound CLI bin directory")) {
    $SkipCliCleanup = $true
  } elseif (Test-Path -LiteralPath $UserBin) {
    Remove-Item -LiteralPath $UserBin -Recurse -Force -ErrorAction SilentlyContinue
    $parent = Split-Path -Parent $UserBin
    if ((Test-Path -LiteralPath $parent) -and -not (Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue)) {
      Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
    }
    Write-Ok "User bin removed"
  } else {
    Write-Warn "User bin not found"
  }

  # --- User state + cache ---------------------------------------------------
  if ($KeepUserData) {
    Write-Step "Keeping user state + cache + telemetry"
    foreach ($dir in ($UserStateDirs + $UserCacheDirs)) {
      if (Test-Path -LiteralPath $dir) { Write-Detail "Path: $dir" }
    }
    foreach ($dir in $UserStateDirs) {
      $analytics = Join-Path $dir "analytics"
      if (Test-Path -LiteralPath $analytics) { Write-Detail "Telemetry: $analytics" }
    }
    Write-Ok "User data preserved (config, DB, installs, telemetry)"
  } else {
    Write-Step "Removing user state + cache"
    $dataRemoved = 0
    foreach ($dir in $UserStateDirs) {
      if (Remove-PathIfExists -Path $dir -Label "User state") { $dataRemoved++ }
    }
    foreach ($dir in $UserCacheDirs) {
      if (Remove-PathIfExists -Path $dir -Label "User cache") { $dataRemoved++ }
    }
    if ($dataRemoved -eq 0) { Write-Warn "No user state or cache found" }
  }

  # --- Per-editor integration dirs ------------------------------------------
  Write-Step "Removing per-editor integration dirs"
  $editorsRemoved = 0
  $editorsSkipped = 0
  foreach ($d in $EditorDirs) {
    $editorName = Split-Path -Leaf (Split-Path -Parent $d)
    if (Test-Path -LiteralPath $d) {
      Write-Detail "Removing: $d"
      Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
      Write-Ok "$editorName integration removed"
      $editorsRemoved++
    } else {
      $editorsSkipped++
    }
  }
  if ($editorsRemoved -eq 0) {
    Write-Warn "No editor integration dirs found"
  } else {
    Write-Ok "Removed $editorsRemoved editor(s), skipped $editorsSkipped"
  }

  # --- User PATH entry (inverse of install.ps1) -----------------------------
  Write-Step "Removing user PATH entry"
  $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if ($SkipCliCleanup -or (Test-NewerInstallSkip -Component "CLI" -What "the HubBound CLI PATH entry")) {
    # A newer CLI owns the PATH entry now.
  } elseif ($UserPath) {
    $target = $UserBin.TrimEnd('\')
    $parts = @($UserPath -split ';' | Where-Object { $_ })
    $kept = @($parts | Where-Object { $_.TrimEnd('\') -ne $target })
    if ($kept.Count -lt $parts.Count) {
      [Environment]::SetEnvironmentVariable("Path", ($kept -join ';'), "User")
      Write-Ok "Removed $UserBin from user PATH"
    } else {
      Write-Warn "No Hubbound bin entry in user PATH"
    }
  } else {
    Write-Warn "User PATH empty, nothing to remove"
  }

  # --- Provider integrations ------------------------------------------------
  # The Go cleaner is the reference implementation and handles TOML providers
  # (Codex) plus managed markdown blocks. It is only present in a source
  # checkout, so end users fall through to the PowerShell subset below.
  Write-Step "Cleaning provider integrations (hooks, MCP servers, artifacts)"
  $purgeGoDir = Join-Path $ScriptDir "dev"
  $purgeGo = Join-Path $purgeGoDir "purge-providers.go"
  $goCmd = Get-Command go -ErrorAction SilentlyContinue
  if ($goCmd -and (Test-Path -LiteralPath $purgeGo)) {
    Push-Location $purgeGoDir
    try {
      & go run $purgeGo
      if ($LASTEXITCODE -eq 0) {
        Write-Ok "Provider integrations cleaned"
      } else {
        Write-Warn "Provider cleanup had issues (non-fatal)"
      }
    } catch {
      Write-Warn "Provider cleanup had issues (non-fatal): $($_.Exception.Message)"
    } finally {
      Pop-Location
    }
  } else {
    try {
      Invoke-ProviderCleanupFallback -HomeDir $HomeDir -EditorDirs $EditorDirs
      Write-Ok "Provider integrations cleaned"
    } catch {
      Write-Warn "Provider cleanup had issues (non-fatal): $($_.Exception.Message)"
    }
  }

  Write-Host ""
  if ($KeepUserData) {
    Write-Color "Uninstall complete. Binaries removed, user data kept." Green
    Write-Host ""
    foreach ($dir in $UserStateDirs) {
      if (Test-Path -LiteralPath $dir) { Write-Detail "Kept: $dir" }
    }
  } else {
    Write-Color "Uninstall complete. hubbound is fully removed." Green
    Write-Host ""
  }
  Write-Detail "Reinstall with: $ReinstallCommand"
  Write-Host ""
}
catch {
  Write-Fail $_.Exception.Message
  exit 1
}
finally {
  Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# Explicit: $LASTEXITCODE still holds a value from a tolerated non-zero native
# call (elevated runner, go run), which callers would otherwise inherit.
exit 0
