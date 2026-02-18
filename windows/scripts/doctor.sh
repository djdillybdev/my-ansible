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

extract_inventory_var() {
  local key="$1"
  awk -F= -v k="$key" '$1 == k {print substr($0, index($0, "=") + 1); exit}' inventory.ini
}

expand_user_path() {
  local p="$1"
  if [[ "$p" == "~/"* ]]; then
    printf '%s\n' "$HOME/${p#~/}"
  else
    printf '%s\n' "$p"
  fi
}

echo "== Local prerequisites =="
check_cmd bash
check_cmd python3
check_cmd ssh
check_cmd ansible-playbook
check_cmd ansible-galaxy
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  pass "timeout utility available"
else
  warn "timeout utility not found; SSH reachability probe will be skipped"
  warn_count=$((warn_count + 1))
fi

if command -v ansible-lint >/dev/null 2>&1; then
  pass "command available: ansible-lint"
else
  warn "ansible-lint not installed (optional)"
  warn_count=$((warn_count + 1))
fi

echo

echo "== Required files =="
check_file playbook.yml
check_file inventory.example.ini
check_file requirements.yml
check_file group_vars/windows.yml
check_file group_vars/windows_apps_catalog.yml
check_file scripts/setup-wsl-control-node.sh
check_file scripts/windows/configure-openssh-localonly.ps1

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
  else
    warn "group_vars/windows/vault.yml exists but is not encrypted"
    warn_count=$((warn_count + 1))
  fi
else
  warn "group_vars/windows/vault.yml not found (optional for SSH key-based workflow)"
  warn_count=$((warn_count + 1))
fi

echo

echo "== Inventory checks =="
if [[ -f inventory.ini ]]; then
  target_host="$(extract_inventory_host || true)"
  target_user="$(extract_inventory_user || true)"
  connection_var="$(extract_inventory_var ansible_connection || true)"
  shell_type_var="$(extract_inventory_var ansible_shell_type || true)"
  shell_exec_var="$(extract_inventory_var ansible_shell_executable || true)"
  key_file_var="$(extract_inventory_var ansible_ssh_private_key_file || true)"

  if [[ -z "${target_host:-}" || "$target_host" == "YOUR_WINDOWS_HOSTNAME_OR_IP" || "$target_host" == "YOUR_WINDOWS_IP" ]]; then
    fail "inventory.ini ansible_host is not set"
    fail_count=$((fail_count + 1))
  elif [[ "$target_host" != "127.0.0.1" ]]; then
    fail "inventory ansible_host must be 127.0.0.1 for this local loopback workflow"
    fail_count=$((fail_count + 1))
  else
    pass "inventory target host: $target_host"
  fi

  if [[ -z "${target_user:-}" || "$target_user" == "YOUR_WINDOWS_USERNAME" || "$target_user" == ".\\YOUR_WINDOWS_USERNAME" ]]; then
    fail "inventory.ini ansible_user is not set"
    fail_count=$((fail_count + 1))
  else
    pass "inventory user: $target_user"
  fi

  if [[ "$connection_var" == "ssh" ]]; then
    pass "inventory uses ansible_connection=ssh"
  else
    fail "inventory must set ansible_connection=ssh"
    fail_count=$((fail_count + 1))
  fi

  if grep -q '^ansible_port=22$' inventory.ini; then
    pass "inventory uses SSH port 22"
  else
    warn "inventory does not explicitly set ansible_port=22"
    warn_count=$((warn_count + 1))
  fi

  if [[ "$shell_type_var" == "powershell" ]]; then
    pass "inventory uses ansible_shell_type=powershell"
  else
    fail "inventory must set ansible_shell_type=powershell"
    fail_count=$((fail_count + 1))
  fi

  if [[ "$shell_exec_var" == "powershell.exe" ]]; then
    pass "inventory uses ansible_shell_executable=powershell.exe"
  else
    fail "inventory must set ansible_shell_executable=powershell.exe"
    fail_count=$((fail_count + 1))
  fi

  if [[ -z "$key_file_var" || "$key_file_var" == "YOUR_PRIVATE_KEY_PATH" ]]; then
    key_file_var="~/.ssh/id_ed25519"
    warn "ansible_ssh_private_key_file not set; defaulting check to $key_file_var"
    warn_count=$((warn_count + 1))
  fi

  resolved_key_file="$(expand_user_path "$key_file_var")"
  if [[ -f "$resolved_key_file" ]]; then
    pass "SSH private key exists: $resolved_key_file"
  else
    fail "SSH private key not found: $resolved_key_file"
    fail_count=$((fail_count + 1))
  fi

  if [[ -f "${resolved_key_file}.pub" ]]; then
    pass "SSH public key exists: ${resolved_key_file}.pub"
  else
    warn "SSH public key not found: ${resolved_key_file}.pub"
    warn_count=$((warn_count + 1))
  fi
fi

echo

echo "== SSH reachability =="
if [[ -n "${target_host:-}" && "$target_host" == "127.0.0.1" ]]; then
  timeout_cmd="timeout"
  if ! command -v "$timeout_cmd" >/dev/null 2>&1; then
    timeout_cmd="gtimeout"
  fi
  if command -v "$timeout_cmd" >/dev/null 2>&1 && "$timeout_cmd" 3 bash -c "</dev/tcp/${target_host}/22" >/dev/null 2>&1; then
    pass "SSH TCP 22 reachable on $target_host"
  elif command -v "$timeout_cmd" >/dev/null 2>&1; then
    warn "SSH TCP 22 is not reachable on $target_host"
    warn_count=$((warn_count + 1))
  else
    warn "timeout utility unavailable; skipping SSH TCP reachability probe"
    warn_count=$((warn_count + 1))
  fi
else
  warn "skipping SSH port check because ansible_host is not 127.0.0.1"
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
