#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

pass() { echo "[PASS] $*"; }
warn() { echo "[WARN] $*"; }
fail() { echo "[FAIL] $*"; }

fail_count=0
warn_count=0

check_cmd() {
  local c="$1"
  if command -v "$c" >/dev/null 2>&1; then
    pass "command available: $c"
  else
    fail "missing command: $c"
    fail_count=$((fail_count + 1))
  fi
}

check_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    pass "file exists: $f"
  else
    fail "missing file: $f"
    fail_count=$((fail_count + 1))
  fi
}

extract_inventory_host() {
  awk '/^\[windows\]/{inwin=1; next} /^\[/{inwin=0} inwin && $0 !~ /^\s*#/ && NF {print $0; exit}' inventory.ini |
    sed -E 's/.*ansible_host=([^ ]+).*/\1/'
}

extract_inventory_user() {
  awk -F= '/^ansible_user=/{print $2; exit}' inventory.ini
}

echo "== Local prerequisites =="
check_cmd bash
check_cmd python3
check_cmd ansible-playbook
check_cmd ansible-galaxy
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  pass "timeout utility available"
else
  warn "timeout utility not found; PSRP port reachability probe will be skipped"
  warn_count=$((warn_count + 1))
fi

if command -v ansible-lint >/dev/null 2>&1; then
  pass "command available: ansible-lint"
else
  warn "ansible-lint not installed (optional)"
  warn_count=$((warn_count + 1))
fi

echo

echo "== PSRP Python dependency =="
if command -v pipx >/dev/null 2>&1 && pipx list 2>/dev/null | grep -q "package ansible"; then
  if pipx runpip ansible show pypsrp >/dev/null 2>&1; then
    pass "pypsrp installed in pipx ansible environment"
  else
    fail "pypsrp missing in pipx ansible environment (run ./scripts/setup-wsl-control-node.sh)"
    fail_count=$((fail_count + 1))
  fi
else
  if python3 -c "import pypsrp" >/dev/null 2>&1; then
    pass "python3 can import pypsrp"
  else
    fail "pypsrp not detected (install for your Ansible environment)"
    fail_count=$((fail_count + 1))
  fi
fi

echo

echo "== Required files =="
check_file playbook.yml
check_file inventory.example.ini
check_file requirements.yml
check_file group_vars/windows.yml
check_file group_vars/windows_apps_catalog.yml
check_file scripts/setup-wsl-control-node.sh

if [[ -f inventory.ini ]]; then
  pass "file exists: inventory.ini"
else
  fail "missing file: inventory.ini (create it with: cp inventory.example.ini inventory.ini)"
  fail_count=$((fail_count + 1))
fi

if [[ -f inventory.ini ]] && cmp -s inventory.ini inventory.example.ini; then
  warn "inventory.ini still matches inventory.example.ini placeholders"
  warn_count=$((warn_count + 1))
fi

if [[ -f group_vars/windows/vault.yml ]]; then
  if grep -q '^\$ANSIBLE_VAULT;' group_vars/windows/vault.yml; then
    pass "vault file exists and is encrypted"
  elif grep -q 'vault_windows_password' group_vars/windows/vault.yml; then
    pass "vault file contains vault_windows_password key"
  else
    fail "group_vars/windows/vault.yml is missing vault_windows_password key"
    fail_count=$((fail_count + 1))
  fi
else
  warn "group_vars/windows/vault.yml not found (expected if not configured yet)"
  warn_count=$((warn_count + 1))
fi

echo

echo "== Inventory checks =="
if [[ -f inventory.ini ]]; then
  target_host="$(extract_inventory_host || true)"
  target_user="$(extract_inventory_user || true)"

  if [[ -z "${target_host:-}" || "$target_host" == "YOUR_WINDOWS_HOSTNAME_OR_IP" || "$target_host" == "YOUR_WINDOWS_IP" ]]; then
    fail "inventory.ini ansible_host is not set"
    fail_count=$((fail_count + 1))
  else
    pass "inventory target host: $target_host"
  fi

  if [[ -z "${target_user:-}" || "$target_user" == "YOUR_WINDOWS_USERNAME" ]]; then
    fail "inventory.ini ansible_user is not set"
    fail_count=$((fail_count + 1))
  else
    pass "inventory user: $target_user"
  fi

  if grep -q 'vault_windows_password' inventory.ini; then
    pass "inventory uses vault_windows_password"
  else
    warn "inventory password is not using vault_windows_password"
    warn_count=$((warn_count + 1))
  fi

  if grep -q '^ansible_connection=psrp' inventory.ini; then
    pass "inventory uses ansible_connection=psrp"
  else
    fail "inventory is not configured for ansible_connection=psrp"
    fail_count=$((fail_count + 1))
  fi

  if grep -q '^ansible_psrp_protocol=https' inventory.ini; then
    pass "inventory uses ansible_psrp_protocol=https"
  else
    fail "inventory is not configured for ansible_psrp_protocol=https"
    fail_count=$((fail_count + 1))
  fi

  if grep -q '^ansible_psrp_cert_validation=validate' inventory.ini; then
    pass "inventory enforces TLS cert validation"
  else
    fail "inventory must set ansible_psrp_cert_validation=validate"
    fail_count=$((fail_count + 1))
  fi
fi

echo

echo "== PSRP reachability =="
if [[ -n "${target_host:-}" && "$target_host" != "YOUR_WINDOWS_HOSTNAME_OR_IP" && "$target_host" != "YOUR_WINDOWS_IP" ]]; then
  timeout_cmd="timeout"
  if ! command -v "$timeout_cmd" >/dev/null 2>&1; then
    timeout_cmd="gtimeout"
  fi
  if command -v "$timeout_cmd" >/dev/null 2>&1 && "$timeout_cmd" 3 bash -c "</dev/tcp/${target_host}/5986" >/dev/null 2>&1; then
    pass "PSRP/WinRM HTTPS TCP 5986 reachable on $target_host"
  elif command -v "$timeout_cmd" >/dev/null 2>&1; then
    warn "PSRP/WinRM HTTPS TCP 5986 is not reachable on $target_host"
    warn_count=$((warn_count + 1))
  else
    warn "timeout utility unavailable; skipping PSRP TCP reachability probe"
    warn_count=$((warn_count + 1))
  fi
else
  warn "skipping PSRP port check because ansible_host is not configured"
  warn_count=$((warn_count + 1))
fi

echo

echo "== Playbook validation =="
if ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ansible-playbook -i inventory.ini --syntax-check playbook.yml >/dev/null; then
  pass "playbook syntax check passed"
else
  fail "playbook syntax check failed"
  fail_count=$((fail_count + 1))
fi

echo
if [[ "$fail_count" -gt 0 ]]; then
  echo "Doctor result: FAIL ($fail_count failures, $warn_count warnings)"
  exit 1
fi

echo "Doctor result: PASS ($warn_count warnings)"
