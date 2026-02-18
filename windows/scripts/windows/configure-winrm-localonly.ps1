Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Warning 'Deprecated: this repository now defaults to OpenSSH transport. Use scripts/windows/configure-openssh-localonly.ps1 for new setups.'

function Assert-Admin {
  $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated PowerShell session (Run as Administrator)."
  }
}

function Get-ListenerField {
  param(
    [string[]]$Keys,
    [string]$Name
  )

  $entry = $Keys | Where-Object { $_ -like "$Name=*" } | Select-Object -First 1
  if (-not $entry) {
    return $null
  }

  return ($entry -split '=', 2)[1]
}

function Get-HttpListeners {
  $listeners = @(Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue)
  $httpListeners = @()

  foreach ($listener in $listeners) {
    $keys = @($listener.Keys)
    $transport = Get-ListenerField -Keys $keys -Name 'Transport'
    $address = Get-ListenerField -Keys $keys -Name 'Address'

    if ($transport -eq 'HTTP') {
      $httpListeners += [PSCustomObject]@{
        Address = $address
        Path = $listener.PSPath
      }
    }
  }

  return $httpListeners
}

function Ensure-LoopbackHttpListener {
  $httpListeners = Get-HttpListeners

  foreach ($listener in $httpListeners) {
    if ($listener.Address -ne '127.0.0.1') {
      $selector = "winrm/config/Listener?Address=$($listener.Address)+Transport=HTTP"
      & winrm delete $selector | Out-Null
    }
  }

  $hasLoopback = (Get-HttpListeners | Where-Object { $_.Address -eq '127.0.0.1' } | Measure-Object).Count -gt 0
  if (-not $hasLoopback) {
    & winrm create winrm/config/Listener?Address=127.0.0.1+Transport=HTTP | Out-Null
  }
}

function Ensure-LocalhostFirewallRule {
  $ruleName = 'WinRM 5985 Localhost Only'
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
      -LocalPort 5985 `
      -Action Allow `
      -LocalAddress 127.0.0.1 | Out-Null
  }
  catch {
    $mode = 'RemoteAddress'
    New-NetFirewallRule `
      -DisplayName $ruleName `
      -Direction Inbound `
      -Protocol TCP `
      -LocalPort 5985 `
      -Action Allow `
      -RemoteAddress 127.0.0.1 | Out-Null
  }

  return [PSCustomObject]@{
    RuleName = $ruleName
    AddressMode = $mode
  }
}

Assert-Admin

Enable-PSRemoting -Force
Set-Service WinRM -StartupType Automatic
Start-Service WinRM

Set-Item -Path WSMan:\localhost\Service\Auth\Basic -Value $true
Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $true
Set-Item -Path WSMan:\localhost\Client\TrustedHosts -Value '127.0.0.1' -Force

Ensure-LoopbackHttpListener
$firewallInfo = Ensure-LocalhostFirewallRule

New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Force | Out-Null
New-ItemProperty `
  -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
  -Name 'LocalAccountTokenFilterPolicy' `
  -PropertyType DWord `
  -Value 1 `
  -Force | Out-Null

$service = Get-Service WinRM
$listenerSummary = & winrm enumerate winrm/config/listener 2>$null |
  Select-String -Pattern 'Address\s*=|Transport\s*=|Port\s*=' |
  ForEach-Object { $_.Line.Trim() }

Write-Host ''
Write-Host 'WinRM local-only configuration complete.'
Write-Host ("WinRM service: {0} ({1})" -f $service.Status, $service.StartType)
Write-Host ("Firewall rule: {0} ({1} restriction)" -f $firewallInfo.RuleName, $firewallInfo.AddressMode)
Write-Host 'Listener summary:'
$listenerSummary | ForEach-Object { Write-Host ("  {0}" -f $_) }
