# Windows Bootstrap (Ansible)

Single-user Windows bootstrap for reinstall/new machine setup.

This workflow is intentionally minimal and optimized for one-time use:

- Control node: Ubuntu in WSL.
- Managed node: your local Windows host over OpenSSH loopback (`127.0.0.1:22`).
- Security posture: key-based SSH auth, localhost-only listener.

## Transport model

This repo uses SSH to manage Windows:

- `ansible_connection=ssh`
- `ansible_host=127.0.0.1`
- `ansible_port=22`
- `ansible_shell_type=powershell`
- `ansible_shell_executable=powershell.exe`

Windows module support remains unchanged (`ansible.windows.*`).

## 1) Install WSL on fresh Windows

Run in elevated PowerShell:

```powershell
wsl --install
wsl --set-default-version 2
```

Reboot if prompted, open Ubuntu, and finish first-user setup.

Verify:

```powershell
wsl -l -v
```

## 2) Prepare WSL Ubuntu (control node)

```bash
sudo apt update
sudo apt install -y ansible git openssh-client
```

Clone repo and install collections:

```bash
git clone <your-repo-url>
cd windows
ansible-galaxy collection install -r requirements.yml
```

Optional helper script:

```bash
./scripts/setup-wsl-control-node.sh
```

## 3) Configure OpenSSH as local-only (Admin PowerShell)

Run this helper script on the Windows machine you are bootstrapping:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\windows\configure-openssh-localonly.ps1
```

The script does all of the following:

- Installs OpenSSH Server capability if missing.
- Enables and starts `sshd` with automatic startup.
- Forces `ListenAddress 127.0.0.1` in `C:\ProgramData\ssh\sshd_config`.
- Adds a dedicated firewall rule `OpenSSH 22 Localhost Only`.
- Restarts `sshd` and prints listener summary.

## 4) Create a local admin Ansible user (recommended)

If your normal login is tied to a Microsoft account, create a dedicated local admin user for Ansible.

Run in elevated PowerShell:

```powershell
$Username = "ansible"
$Password = Read-Host "Enter password for local ansible user" -AsSecureString

if (-not (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue)) {
  New-LocalUser -Name $Username -Password $Password -FullName "Ansible Local Admin" -Description "Local automation account for bootstrap"
}

Add-LocalGroupMember -Group "Administrators" -Member $Username -ErrorAction SilentlyContinue
```

## 5) Set up SSH key auth from WSL

Generate a key in WSL if needed:

```bash
ssh-keygen -t ed25519
```

Copy the public key text:

```bash
cat ~/.ssh/id_ed25519.pub
```

Append that line to:

- `C:\Users\<WINDOWS_USER>\.ssh\authorized_keys`

Quick PowerShell helper (run as that target user or in elevated PowerShell with adjusted path):

```powershell
$User = "ansible"
$SshDir = "C:\Users\$User\.ssh"
$AuthKeys = Join-Path $SshDir 'authorized_keys'

New-Item -ItemType Directory -Path $SshDir -Force | Out-Null
if (-not (Test-Path $AuthKeys)) { New-Item -ItemType File -Path $AuthKeys -Force | Out-Null }
notepad $AuthKeys
```

Paste the WSL public key as a single line, save, then verify:

```bash
ssh ansible@127.0.0.1
```

## 6) Configure inventory

Create local inventory:

```bash
cp inventory.example.ini inventory.ini
```

Edit `inventory.ini`:

- Set `ansible_user` to your Windows admin user.
- Set `ansible_ssh_private_key_file` to your private key path if not `~/.ssh/id_ed25519`.

No password is required in inventory for this workflow.

## 7) Validate and run

Syntax check:

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ~/.local/bin/ansible-playbook -i inventory.ini --syntax-check playbook.yml
```

Connection test:

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ~/.local/bin/ansible -i inventory.ini windows -m ansible.windows.win_ping
```

Doctor preflight:

```bash
make doctor
```

Run the bootstrap:

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ~/.local/bin/ansible-playbook -i inventory.ini playbook.yml
```

## 8) Common failures and fastest fixes

Timeout or cannot connect:

```powershell
Get-Service sshd
Get-Content C:\ProgramData\ssh\sshd_config | Select-String ListenAddress
```

- Ensure `sshd` is running.
- Ensure `ListenAddress 127.0.0.1` is set.
- Re-run `.\scripts\windows\configure-openssh-localonly.ps1`.

Auth fails:

- Confirm `ansible_user` matches the Windows user with the installed key.
- Confirm the matching private key path in inventory.
- Test direct SSH first: `ssh <user>@127.0.0.1`.

Host key mismatch from reinstalled machine:

```bash
ssh-keygen -R 127.0.0.1
```

Then retry SSH.

Access denied on admin-required tasks:

- Use an account in local `Administrators`.
- Confirm the SSH session for that user works before running Ansible.

## 9) Deprecated WinRM helper

`./scripts/windows/configure-winrm-localonly.ps1` is retained only for legacy fallback paths and is no longer the default transport workflow.

## 10) WinUtil (manual, optional)

Run manually in elevated PowerShell:

```powershell
irm https://christitus.com/win | iex
```

Project link:

- https://github.com/ChrisTitusTech/winutil
