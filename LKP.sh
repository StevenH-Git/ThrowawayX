#!/usr/bin/env bash
set -euo pipefail

abort() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

TTY=${TTY:-/dev/tty}
if ! [ -t 0 ] && ! [ -c "$TTY" ]; then
  abort "No controlling terminal detected for interactive prompts."
fi

restore_tty() { stty echo <"$TTY" 2>/dev/null || true; }
trap restore_tty EXIT INT TERM

prompt_secret_twice() {
  local label="$1" p1 p2
  while :; do
    printf 'Enter %s: ' "$label" >"$TTY"
    stty -echo <"$TTY"; IFS= read -r p1 <"$TTY"; stty echo <"$TTY"; printf '\n' >"$TTY"
    printf 'Re-enter %s: ' "$label" >"$TTY"
    stty -echo <"$TTY"; IFS= read -r p2 <"$TTY"; stty echo <"$TTY"; printf '\n' >"$TTY"
    if [[ "$p1" == "$p2" ]]; then
      printf '%s\n' "$p1"
      return 0
    fi
    printf 'Mismatch. Try again.\n' >"$TTY"
  done
}

is_valid_ipv4() {
  [[ "$1" =~ ^((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])$ ]]
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

have_sudo() { sudo -n true 2>/dev/null; }

install_sshpass_if_missing() {
  if need_cmd sshpass; then return 0; fi
  printf 'sshpass not found. Attempting to install...\n' >"$TTY"
  if need_cmd apt-get; then
    sudo apt-get update -y
    sudo apt-get install -y sshpass
  elif need_cmd dnf; then
    sudo dnf -y install epel-release || true
    sudo dnf -y install sshpass
  elif need_cmd yum; then
    sudo yum -y install epel-release || true
    sudo yum -y install sshpass
  else
    abort "No supported package manager; install 'sshpass' manually."
  fi
  need_cmd sshpass || abort "Failed to install sshpass."
}

printf 'Enter service account username (non-root): ' >"$TTY"
IFS= read -r SVC_USER <"$TTY"

SVC_PASS="$(prompt_secret_twice 'service account password')"
ROOT_PASS="$(prompt_secret_twice 'root password to set on targets')"

declare -a IPS=()
for label in "Control node 1" "Control node 2" "Control node 3" "Worker node 1" "Worker node 2" "Worker node 3"; do
  while :; do
    printf '%s IP: ' "$label" >"$TTY"
    IFS= read -r ip <"$TTY"
    ip="$(printf '%s' "$ip" | xargs)"
    if ! is_valid_ipv4 "$ip"; then printf 'Invalid IPv4 (e.g., 192.168.1.10)\n' >"$TTY"; continue; fi
    if printf '%s\n' "${IPS[@]}" | grep -qxF "$ip"; then
      printf 'Duplicate IP not allowed. Enter a different IP.\n' >"$TTY"; continue
    fi
    IPS+=("$ip"); break
  done
done

printf '\nSummary\n' >"$TTY"
printf 'Service account: %s\n' "$SVC_USER" >"$TTY"
printf 'Control nodes: %s, %s, %s\n' "${IPS[0]}" "${IPS[1]}" "${IPS[2]}" >"$TTY"
printf 'Worker nodes : %s, %s, %s\n\n' "${IPS[3]}" "${IPS[4]}" "${IPS[5]}" >"$TTY"

while :; do
  printf 'Type YES to continue or EXIT to quit: ' >"$TTY"
  IFS= read -r confirm <"$TTY"
  resp_uc="$(printf '%s' "$confirm" | tr '[:lower:]' '[:upper:]')"
  if [[ "$resp_uc" == "YES" ]]; then
    break
  elif [[ "$resp_uc" == "EXIT" ]]; then
    printf 'Exiting.\n' >"$TTY"
    exit 0
  else
    printf 'Enter YES or EXIT\n' >"$TTY"
  fi
done

need_cmd ssh || abort "OpenSSH client 'ssh' not found."
need_cmd ssh-keygen || abort "'ssh-keygen' not found."
need_cmd ssh-keyscan || abort "'ssh-keyscan' not found."
install_sshpass_if_missing

SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"

PUBKEY=""
if [[ -f "$SSH_DIR/id_ed25519.pub" ]]; then
  PUBKEY="$SSH_DIR/id_ed25519.pub"
elif [[ -f "$SSH_DIR/id_rsa.pub" ]]; then
  PUBKEY="$SSH_DIR/id_rsa.pub"
else
  printf 'No SSH key found. Generating RSA 4096 keypair...\n' >"$TTY"
  ssh-keygen -q -t rsa -b 4096 -N "" -f "$SSH_DIR/id_rsa"
  PUBKEY="$SSH_DIR/id_rsa.pub"
fi
[[ -s "$PUBKEY" ]] || abort "Public key file is empty: $PUBKEY"

seed_known_hosts() {
  local target_ip="$1"
  local tmp="$(mktemp)"
  ssh-keyscan -t rsa,ecdsa,ed25519 "$target_ip" 2>/dev/null | awk 'NF && $1 !~ /^#/' >"$tmp" || true
  if [[ ! -s "$tmp" ]]; then
    printf 'Warning: ssh-keyscan returned nothing for %s\n' "$target_ip" >&2
    rm -f "$tmp"; return
  fi

  local tmp2="$(mktemp)"
  while IFS= read -r line; do
    host="$target_ip"
    algo="$(awk '{print $2}' <<<"$line")"
    key="$(awk  '{print $3}' <<<"$line")"
    comment="$(awk '{sub($1 FS $2 FS $3 FS,""); print}' <<<"$line")"
    if [[ -n "$comment" ]]; then
      printf '%s %s %s %s\n'     "$host" "$algo" "$key" "$comment"  >> "$tmp2"
      printf '[%s]:22 %s %s %s\n' "$host" "$algo" "$key" "$comment" >> "$tmp2"
    else
      printf '%s %s %s\n'         "$host" "$algo" "$key"            >> "$tmp2"
      printf '[%s]:22 %s %s\n'    "$host" "$algo" "$key"            >> "$tmp2"
    fi
  done <"$tmp"
  rm -f "$tmp"

  touch "$SSH_DIR/known_hosts"; chmod 600 "$SSH_DIR/known_hosts"
  ssh-keygen -R "$target_ip"        -f "$SSH_DIR/known_hosts" >/dev/null 2>&1 || true
  ssh-keygen -R "[$target_ip]:22"   -f "$SSH_DIR/known_hosts" >/dev/null 2>&1 || true
  cat "$tmp2" >> "$SSH_DIR/known_hosts"
  awk 'NF' "$SSH_DIR/known_hosts" | sort -u > "$SSH_DIR/.kh.tmp" && mv "$SSH_DIR/.kh.tmp" "$SSH_DIR/known_hosts"

  if have_sudo; then
    sudo mkdir -p /root/.ssh
    sudo install -m 600 /dev/null /root/.ssh/known_hosts 2>/dev/null || sudo touch /root/.ssh/known_hosts
    sudo chmod 600 /root/.ssh/known_hosts
    sudo ssh-keygen -R "$target_ip"      -f /root/.ssh/known_hosts >/dev/null 2>&1 || true
    sudo ssh-keygen -R "[$target_ip]:22" -f /root/.ssh/known_hosts >/dev/null 2>&1 || true
    sudo bash -c "cat '$tmp2' >> /root/.ssh/known_hosts"
    sudo bash -c "awk 'NF' /root/.ssh/known_hosts | sort -u > /root/.ssh/.kh.tmp && mv /root/.ssh/.kh.tmp /root/.ssh/known_hosts"
  fi

  if have_sudo; then
    sudo install -m 644 /dev/null /etc/ssh/ssh_known_hosts 2>/dev/null || sudo touch /etc/ssh/ssh_known_hosts
    sudo chmod 644 /etc/ssh/ssh_known_hosts
    sudo bash -c "cat '$tmp2' >> /etc/ssh/ssh_known_hosts"
    sudo bash -c "awk 'NF' /etc/ssh/ssh_known_hosts | sort -u > /etc/ssh/.kh.tmp && mv /etc/ssh/.kh.tmp /etc/ssh/ssh_known_hosts"
  fi

  rm -f "$tmp2"
}

for ip in "${IPS[@]}"; do seed_known_hosts "$ip"; done

SSH_CONTACT_OPTS=(
  -o StrictHostKeyChecking=no
  -o PreferredAuthentications=password,keyboard-interactive
  -o PasswordAuthentication=yes
  -o KbdInteractiveAuthentication=yes
  -o PubkeyAuthentication=no
  -o NumberOfPasswordPrompts=1
)

run_remote_sudo() {
  local ip="$1" cmd="$2"
  sshpass -p "$SVC_PASS" ssh "${SSH_CONTACT_OPTS[@]}" -tt "$SVC_USER@$ip" \
    "echo \"$SVC_PASS\" | sudo -S -p '' bash -lc $'${cmd//\'/\'\\\'\'}'"
}

copy_pubkey_tmp() {
  local ip="$1" tmpname="$2"
  sshpass -p "$SVC_PASS" scp "${SSH_CONTACT_OPTS[@]}" \
    "$PUBKEY" "$SVC_USER@$ip:/tmp/$tmpname"
}

for ip in "${IPS[@]}"; do
  printf '=== %s ===\n' "$ip" >"$TTY"
  tmpfile="root_pubkey_$(date +%s)_$$.pub"

  if ! copy_pubkey_tmp "$ip" "$tmpfile"; then
    printf 'ERROR: initial scp to %s failed. Skipping.\n' "$ip" >"$TTY"
    continue
  fi

  REMOTE_CMDS=$(cat <<'EOS'
set -euo pipefail

mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
chown -R root:root /root/.ssh

if [ -s "/tmp/__TMPKEY__" ]; then
  cat /root/.ssh/authorized_keys "/tmp/__TMPKEY__" | awk 'NF' | sort -u > /root/.ssh/.auth.tmp
  mv /root/.ssh/.auth.tmp /root/.ssh/authorized_keys
  rm -f "/tmp/__TMPKEY__"
fi

mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-root-pubkey.conf <<'EOF'
PermitRootLogin yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys/%u
EOF

if command -v restorecon >/dev/null 2>&1; then
  restorecon -Rv /root/.ssh >/dev/null 2>&1 || true
fi

echo "__ROOTPASS_PLACEHOLDER__" | chpasswd
passwd -u root >/dev/null 2>&1 || true

# Restart ssh daemon across Ubuntu/RHEL variants
if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files | grep -q '^ssh\.service'; then
    systemctl restart ssh
  elif systemctl list-unit-files | grep -q '^sshd\.service'; then
    systemctl restart sshd
  else
    service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
  fi
else
  service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
fi

sshd -t
sshd -T 2>/dev/null | egrep -i '^(permitrootlogin|pubkeyauthentication|authorizedkeysfile)\s' || true
EOS
)
  REMOTE_CMDS="${REMOTE_CMDS//$'\r'/}"
  REMOTE_CMDS="${REMOTE_CMDS//__TMPKEY__/$tmpfile}"
  REMOTE_CMDS="${REMOTE_CMDS//__ROOTPASS_PLACEHOLDER__/root:$ROOT_PASS}"

  if ! run_remote_sudo "$ip" "$REMOTE_CMDS"; then
    printf 'ERROR: remote setup on %s failed. Skipping verification.\n' "$ip" >"$TTY"
    continue
  fi

  if ssh -o BatchMode=yes "root@$ip" true 2>/dev/null; then
    printf 'Root key login OK on %s\n' "$ip" >"$TTY"
  else
    printf 'WARNING: Root key login failed on %s\n' "$ip" >"$TTY"
  fi
done

printf '\n==== Summary ====\n' >"$TTY"
printf '%-15s %s\n' "Control 1" "${IPS[0]}" >"$TTY"
printf '%-15s %s\n' "Control 2" "${IPS[1]}" >"$TTY"
printf '%-15s %s\n' "Control 3" "${IPS[2]}" >"$TTY"
printf '%-15s %s\n' "Worker 1"  "${IPS[3]}" >"$TTY"
printf '%-15s %s\n' "Worker 2"  "${IPS[4]}" >"$TTY"
printf '%-15s %s\n' "Worker 3"  "${IPS[5]}" >"$TTY"
printf 'Completed.\n' >"$TTY"