Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Admin {
  $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell session (Run as Administrator).'
  }
}

function Ensure-OpenSSHServer {
  $capability = Get-WindowsCapability -Online | Where-Object { $_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1
  if (-not $capability) {
    throw 'OpenSSH Server capability was not found on this Windows image.'
  }

  if ($capability.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name $capability.Name | Out-Null
  }

  return $capability.Name
}

function Ensure-LocalhostListenAddress {
  $configPath = Join-Path $env:ProgramData 'ssh\sshd_config'
  if (-not (Test-Path $configPath)) {
    throw "sshd_config not found at $configPath"
  }

  $rawContent = Get-Content -Path $configPath
  $linePattern = '^\s*ListenAddress\s+'
  $hasListenAddress = ($rawContent | Where-Object { $_ -match $linePattern }).Count -gt 0
  $newContent = @()

  foreach ($line in $rawContent) {
    if ($line -match $linePattern) {
      $newContent += 'ListenAddress 127.0.0.1'
    }
    else {
      $newContent += $line
    }
  }

  if (-not $hasListenAddress) {
    if ($newContent.Count -gt 0 -and $newContent[-1] -ne '') {
      $newContent += ''
    }
    $newContent += 'ListenAddress 127.0.0.1'
  }

  $updatedContent = @()
  $lastWasListenAddress = $false
  foreach ($line in $newContent) {
    if ($line -eq 'ListenAddress 127.0.0.1') {
      if (-not $lastWasListenAddress) {
        $updatedContent += $line
      }
      $lastWasListenAddress = $true
    }
    else {
      $updatedContent += $line
      $lastWasListenAddress = $false
    }
  }

  $before = $rawContent -join "`n"
  $after = $updatedContent -join "`n"
  $changed = $before -ne $after

  if ($changed) {
    Set-Content -Path $configPath -Value $updatedContent -Encoding utf8
  }

  return [PSCustomObject]@{
    Path = $configPath
    Changed = $changed
  }
}

function Ensure-LocalhostFirewallRule {
  $ruleName = 'OpenSSH 22 Localhost Only'
  $mode = 'LocalAddress'

  $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
  if ($existingRule) {
    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction Stop
  }

  try {
    New-NetFirewallRule `
      -DisplayName $ruleName `
      -Direction Inbound `
      -Protocol TCP `
      -LocalPort 22 `
      -Action Allow `
      -LocalAddress 127.0.0.1 | Out-Null
  }
  catch {
    $mode = 'RemoteAddress'
    New-NetFirewallRule `
      -DisplayName $ruleName `
      -Direction Inbound `
      -Protocol TCP `
      -LocalPort 22 `
      -Action Allow `
      -RemoteAddress 127.0.0.1 | Out-Null
  }

  return [PSCustomObject]@{
    RuleName = $ruleName
    AddressMode = $mode
  }
}

Assert-Admin
$capabilityName = Ensure-OpenSSHServer

Set-Service sshd -StartupType Automatic
Start-Service sshd

$configResult = Ensure-LocalhostListenAddress
Restart-Service sshd
$firewallInfo = Ensure-LocalhostFirewallRule

$service = Get-Service sshd
$listeners = Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue |
  Select-Object -Property LocalAddress, LocalPort, OwningProcess

Write-Host ''
Write-Host 'OpenSSH local-only configuration complete.'
Write-Host ("Capability: {0}" -f $capabilityName)
Write-Host ("sshd service: {0} ({1})" -f $service.Status, $service.StartType)
Write-Host ("sshd_config: {0} (updated={1})" -f $configResult.Path, $configResult.Changed)
Write-Host ("Firewall rule: {0} ({1} restriction)" -f $firewallInfo.RuleName, $firewallInfo.AddressMode)
Write-Host 'Listener summary:'
if ($listeners) {
  $listeners | ForEach-Object {
    Write-Host ("  Address={0} Port={1} PID={2}" -f $_.LocalAddress, $_.LocalPort, $_.OwningProcess)
  }
}
else {
  Write-Host '  No active TCP listeners found on port 22.'
}
