# Windows Bootstrap (Ansible)

Single-user Windows bootstrap for reinstall/new machine setup.

This workflow is **WSL-first**:

- Control node: Ubuntu on WSL (where you run Ansible).
- Managed node: Windows host via WinRM (can be the same machine).

WSL installation is treated as a prerequisite and is disabled by default in the playbook config.

## 1) Fresh Windows prerequisite: install WSL

Run in an elevated PowerShell terminal:

```powershell
wsl --install
wsl --set-default-version 2
```

Reboot when prompted, open Ubuntu, and complete first-user setup.

Verify WSL2 is active:

```powershell
wsl -l -v
```

Your distro should show `VERSION` = `2`. If it does not:

```powershell
wsl --set-version Ubuntu 2
```

Then verify from Ubuntu:

```bash
uname -a
```

## 2) Prepare WSL Ubuntu (control node)

```bash
sudo apt update
sudo apt install -y python3 python3-pip python3-venv pipx git
pipx ensurepath
source ~/.bashrc 2>/dev/null || true
pipx install ansible
```

Clone repo and install collections:

```bash
git clone <your-repo-url>
cd windows
ansible-galaxy collection install -r requirements.yml
```

Optional helper script for fresh WSL setup:

```bash
./scripts/setup-wsl-control-node.sh
```

## 3) Configure inventory and variables

Primary config files:

- `inventory.ini`
- `group_vars/windows.yml`
- `group_vars/windows_apps_catalog.yml`
- `group_vars/windows/vault.yml` (optional, encrypted)

Edit `inventory.ini`:

- `ansible_host`: Windows IP or hostname
- `ansible_user`: Windows account name
- `ansible_password`: uses `{{ vault_windows_password }}`

## 4) Configure secrets with Ansible Vault

```bash
cp group_vars/windows/vault.example.yml group_vars/windows/vault.yml
```

Set `vault_windows_password` in `group_vars/windows/vault.yml`, then encrypt:

```bash
ansible-vault encrypt group_vars/windows/vault.yml
```

## 5) Prepare WinRM on Windows target

Run in elevated PowerShell on the target Windows host:

```powershell
Enable-PSRemoting -Force
Set-Item -Path WSMan:\localhost\Service\Auth\Basic -Value $true
Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $true
Set-NetFirewallRule -Name WINRM-HTTP-In-TCP -Enabled True
winrm quickconfig -q
```

Your inventory is configured for NTLM transport, so keep:

- `ansible_connection=winrm`
- `ansible_winrm_transport=ntlm`

## 6) First run

Syntax check:

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ansible-playbook -i inventory.ini --syntax-check playbook.yml
```

Optional local validation bundle:

```bash
make check
```

Recommended preflight before first run or after Windows changes:

```bash
make doctor
```

Run bootstrap:

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ansible-playbook -i inventory.ini playbook.yml
```

## 7) Ongoing use (drift correction)

Re-run anytime after editing `group_vars/windows.yml`:

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ansible-playbook -i inventory.ini playbook.yml
```

Targeted runs:

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ansible-playbook -i inventory.ini playbook.yml --tags apps
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ansible-playbook -i inventory.ini playbook.yml --tags runtimes
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ansible-playbook -i inventory.ini playbook.yml --tags dotfiles
```

## 8) Common customizations

In `group_vars/windows.yml`:

- Keep `windows_apps_selection.include_categories` and `include_apps` empty to install full catalog.
- Use `windows_apps_selection.exclude_apps` to skip specific apps.
- Toggle phases with `windows_bootstrap_features` (for this workflow, `wsl` defaults to `false`).

In `group_vars/windows_apps_catalog.yml`:

- Organize apps by category key (for example `dev`, `browser`, `utility`).
- Add/remove apps or adjust package IDs inside each category list.

If you want playbook-driven WSL changes anyway:

- Set `windows_bootstrap_features.wsl: true`
- Configure `wsl.install_method` (`winget` or `wsl_cli`)

## 9) WinUtil (manual, recommended)

WinUtil is intentionally not automated by this playbook by default.

Run it manually in elevated PowerShell when you want to apply system tweaks:

```powershell
irm https://christitus.com/win | iex
```

Project link:

- https://github.com/ChrisTitusTech/winutil

## 10) Preflight Doctor

Run:

```bash
make doctor
```

Checks performed:

- required local commands (`ansible-playbook`, `ansible-galaxy`, `python3`)
- required repo files
- inventory placeholders still present (`YOUR_WINDOWS_IP`, `YOUR_WINDOWS_USERNAME`)
- optional WinRM TCP 5985 reachability test
- Ansible syntax check

## 11) Troubleshooting

- Vault var not found:
  - Ensure `group_vars/windows/vault.yml` exists and includes `vault_windows_password`.
- WinRM auth failures:
  - Re-check username/password, firewall, and WinRM service state.
- Connection timeout:
  - Verify host/IP reachability from WSL and that WinRM HTTP listener is enabled.
- Missing package manager on target:
  - Keep `package_management.bootstrap_missing_managers: true` or preinstall required managers.
