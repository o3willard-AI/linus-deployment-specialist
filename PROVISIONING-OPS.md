# PROVISIONING OPS: Executable Deployment Flow

> **EXECUTABLE — every step is a command. No inference required.**
> Agents: follow numbered steps in order. Each step has a verification checkpoint.

---

## Phase 0: Pre-Flight Hygiene

### 0.1 Clean orphaned VMs from previous failed runs

```bash
# List all test VMs in the 113-199 range
curl -sk \
  -H "Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
  "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu" \
  | jq '[.data[] | select(.vmid >= 113 and .vmid <= 199) | {vmid, name, status}]'
```

IF any appear: for each VMID returned:
```bash
VMID=<from-list>
curl -sk -X POST \
  -H "Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
  "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${VMID}/status/stop"
sleep 3
curl -sk -X DELETE \
  -H "Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
  "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${VMID}?destroy-unreferenced-disks=1&purge=1"
```

### 0.2 Register the trap BEFORE provisioning anything

```bash
declare -a ALL_VM_IDS=()

cleanup_all_vms() {
    for vmid in "${ALL_VM_IDS[@]}"; do
        [[ -z "$vmid" ]] && continue
        curl -sk -X POST \
          -H "Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
          "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${vmid}/status/stop" 2>/dev/null || true
        sleep 3
        curl -sk -X DELETE \
          -H "Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
          "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${vmid}?destroy-unreferenced-disks=1&purge=1" 2>/dev/null || true
    done
}
trap cleanup_all_vms EXIT
```

### 0.3 Append every created VMID to the trap array

After any `proxmox.sh` invocation that succeeds, parse and store:
```bash
NEW_VMID=$(grep "LINUS_VM_ID:" /tmp/provision-output.txt | cut -d: -f2 | tr -d '\r\n\t ')
ALL_VM_IDS+=("$NEW_VMID")
```

---

## Phase 1: Provision Single VM

### 1.1 Export environment

```bash
export PROXMOX_HOST="${PROXMOX_HOST}"
export PROXMOX_USER="${PROXMOX_USER}"
export PROXMOX_TOKEN_ID="${PROXMOX_TOKEN_ID}"
export PROXMOX_TOKEN_SECRET="${PROXMOX_TOKEN_SECRET}"
export PROXMOX_SSH_PASS="${PROXMOX_SSH_PASS}"
export VM_CPU="${VM_CPU:-2}"
export VM_RAM="${VM_RAM:-2048}"
export VM_DISK="${VM_DISK:-20}"
```

### 1.2 Run provisioning

```bash
bash shared/provision/proxmox.sh > /tmp/provision-output.txt 2>&1 || {
    echo "PROVISIONING FAILED"
    cat /tmp/provision-output.txt
    exit 1
}
```

### 1.3 Parse and register VM

```bash
VM_ID=$(grep "LINUS_VM_ID:" /tmp/provision-output.txt | cut -d: -f2 | tr -d '\r\n\t ')
VM_IP=$(grep "LINUS_VM_IP:" /tmp/provision-output.txt | cut -d: -f2 | tr -d '\r\n\t ')
VM_USER=$(grep "LINUS_VM_USER:" /tmp/provision-output.txt | cut -d: -f2 | tr -d '\r\n\t ')
[[ -z "$VM_ID" || -z "$VM_IP" ]] && { echo "PARSE FAILED"; exit 1; }
ALL_VM_IDS+=("$VM_ID")
echo "VM_ID=$VM_ID VM_IP=$VM_IP VM_USER=$VM_USER"
```

### 1.4 Verify SSH readiness (Gate 1 → Gate 2 → Gate 3)

```bash
# Gate 1: SSH transport is alive (provisioning already waited 300s)
# Gate 2: DNS works
ssh -i ~/.ssh/id_ed25519_qemu_test -o StrictHostKeyChecking=no \
    "${VM_USER}@${VM_IP}" \
    "getent hosts archive.ubuntu.com >/dev/null 2>&1 && echo 'DNS:OK' || echo 'DNS:FAIL'"

# Gate 3: apt lock is free
ssh -i ~/.ssh/id_ed25519_qemu_test -o StrictHostKeyChecking=no \
    "${VM_USER}@${VM_IP}" \
    "apt-get update -qq 2>&1 | head -3"
```

---

## Phase 2: Bootstrap

### 2.1 Deploy bootstrap files

```bash
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519_qemu_test}"
SSH_OPTS=(-i "${SSH_KEY_FILE}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10)

# Create directories on VM
ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" "mkdir -p /tmp/linus /tmp/lib"

# Upload scripts (../lib/paths.sh resolved by all scripts — must be in /tmp/lib/)
scp "${SSH_OPTS[@]}" shared/bootstrap/ubuntu.sh "${VM_USER}@${VM_IP}:/tmp/linus/"
scp "${SSH_OPTS[@]}" shared/lib/*.sh "${VM_USER}@${VM_IP}:/tmp/lib/"
```

### 2.2 Execute bootstrap and verify SUCCESS marker

```bash
ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" \
    "cd /tmp/linus && sudo bash ubuntu.sh" > /tmp/bootstrap-output.txt 2>&1

grep -q "LINUS_RESULT:SUCCESS" /tmp/bootstrap-output.txt || {
    echo "BOOTSTRAP FAILED"
    cat /tmp/bootstrap-output.txt
    exit 1
}
```

**CHECKPOINT:** `LINUS_RESULT:SUCCESS` in `/tmp/bootstrap-output.txt`.

---

## Phase 3: Install Tools

### 3.1 Dev tools

```bash
scp "${SSH_OPTS[@]}" shared/configure/dev-tools.sh "${VM_USER}@${VM_IP}:/tmp/linus/"
ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" \
    "cd /tmp/linus && sudo bash dev-tools.sh" > /tmp/dev-tools-output.txt 2>&1
grep -q "LINUS_RESULT:SUCCESS" /tmp/dev-tools-output.txt || exit 1
```

### 3.2 Base packages

```bash
scp "${SSH_OPTS[@]}" shared/configure/base-packages.sh "${VM_USER}@${VM_IP}:/tmp/linus/"
ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" \
    "cd /tmp/linus && sudo bash base-packages.sh" > /tmp/base-packages-output.txt 2>&1
grep -q "LINUS_RESULT:SUCCESS" /tmp/base-packages-output.txt || exit 1
```

---

## Phase 4: Snapshot Cycle

### 4.1 Take snapshot

```bash
SNAP_NAME="pre-workload"
curl -sk -X POST \
  -H "Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
  "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${VM_ID}/snapshot" \
  -d "snapname=${SNAP_NAME}" -d "description=Pre-workload checkpoint"
```

**CHECKPOINT:** Snapshot appears in `qm listsnapshot ${VM_ID}` output.

### 4.2 Run workload, verify, then rollback

```bash
# Apply change
ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" \
    "sudo apt-get install -y -qq nginx && echo 'TEST DATA' | sudo tee /var/www/html/test.txt"
# Verify change took effect
ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" "curl -s http://localhost/test.txt" | grep -q "TEST DATA"

# Rollback
curl -sk -X POST \
  -H "Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
  "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${VM_ID}/snapshot/${SNAP_NAME}/rollback" \
  -d "start=1"

# Wait for VM to fully reboot after rollback
sleep 5
for i in $(seq 1 30); do
    ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" "echo ok" >/dev/null 2>&1 && break
    sleep 2
done
```

### 4.3 Verify rollback reverted the change

```bash
# Nginx must be GONE
ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" "which nginx" 2>/dev/null && { echo "ROLLBACK FAILED: nginx still present"; exit 1; }
# Base tools must still be PRESENT
for tool in curl git python3; do
    ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" "which $tool" >/dev/null 2>&1 || { echo "ROLLBACK CORRUPTED: $tool missing"; exit 1; }
done
```

---

## Phase 5: Multi-VM

### 5.1 Provision N additional VMs with multi-vm.sh

```bash
export PROVIDER="proxmox"
export VM_COUNT="${VM_COUNT:-2}"
export BASE_NAME="${BASE_NAME:-test-cluster}"
export VM_CPU="${VM_CPU:-1}"
export VM_RAM="${VM_RAM:-1024}"
export VM_DISK="${VM_DISK:-10}"

bash shared/provision/multi-vm.sh > /tmp/multi-vm-output.txt 2>&1 || {
    echo "MULTI-VM FAILED"
    cat /tmp/multi-vm-output.txt
    exit 1
}
```

### 5.2 Parse and register all new VM IDs

```bash
MULTI_VM_IDS=""
for i in $(seq 1 ${VM_COUNT}); do
    vm_id=$(grep "LINUS_VM_${i}_ID:" /tmp/multi-vm-output.txt | cut -d: -f2 | tr -d '\r\n\t ')
    vm_ip=$(grep "LINUS_VM_${i}_IP:" /tmp/multi-vm-output.txt | cut -d: -f2 | tr -d '\r\n\t ')
    [[ -n "$vm_id" ]] && ALL_VM_IDS+=("$vm_id")
    [[ -n "$vm_id" ]] && MULTI_VM_IDS="${MULTI_VM_IDS}${MULTI_VM_IDS:+,}$vm_id"
    echo "VM $i: ID=$vm_id IP=$vm_ip"
done
```

### 5.3 Verify all VMs are running

```bash
IFS=',' read -ra ID_ARRAY <<< "${MULTI_VM_IDS}"
for id in "${ID_ARRAY[@]}"; do
    status=$(curl -sk \
      -H "Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
      "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${id}/status/current" \
      | jq -r '.data.status')
    [[ "$status" != "running" ]] && { echo "VM $id is NOT running (status=$status)"; exit 1; }
done
```

---

## Phase 6: Monitoring

### 6.1 Upload and start monitoring script

```bash
scp "${SSH_OPTS[@]}" shared/snapshot/monitor-resource.sh "${VM_USER}@${VM_IP}:/tmp/"
ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" "sudo bash /tmp/monitor-resource.sh &" &
```

### 6.2 Run a stress workload and verify monitoring captured it

```bash
ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" \
    "dd if=/dev/zero of=/tmp/stress-test bs=1M count=500 2>/dev/null &"
sleep 5
# Verify monitoring output file was created and populated
ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" \
    "ls -la /tmp/resource-monitor-*.log 2>/dev/null || echo 'MONITORING FILE NOT FOUND'"
```

---

## CONTRACT: Script Execution Rules

These rules apply to ALL scripts in `shared/`:

### stdout vs stderr

| Stream | Content | Example |
|--------|---------|---------|
| **stdout** | Parseable structured data only | `LINUS_RESULT:SUCCESS`, `echo "name:ip:user:id"` |
| **stderr** | All human-readable output | `log_info`, `log_success`, `log_step`, progress bars, diagnostics |

Scripts sourced by `$()` or pipes MUST NOT emit unstructured output to stdout.

### SSH key auto-detection

Every function that opens an SSH connection MUST run this detection:

```bash
find_ssh_key() {
    for candidate in ~/.ssh/id_ed25519_qemu_test ~/.ssh/id_ed25519 ~/.ssh/id_rsa; do
        [[ -f "$candidate" ]] && { echo "$candidate"; return 0; }
    done
    return 1
}
```

### APT lock resilience

Every `apt-get` invocation MUST use retry-with-backoff:

```bash
apt_with_retry() {
    local attempt=0 max=10
    while [[ $attempt -lt $max ]]; do
        attempt=$((attempt+1))
        apt-get "$@" 2>&1 && return 0
        if echo "$OUTPUT" | grep -qE "Could not get lock|Unable to acquire the dpkg"; then
            sleep $((attempt * 3))
        else
            return 1  # non-lock error — don't retry
        fi
    done
    return 1
}
```

---

## ENVIRONMENT VARIABLES REFERENCE

| Variable | Default | Required | Notes |
|----------|---------|----------|-------|
| `PROXMOX_HOST` | — | Yes | Proxmox host IP/hostname |
| `PROXMOX_USER` | — | Yes | `root@pam` format |
| `PROXMOX_TOKEN_ID` | — | Yes | API token name |
| `PROXMOX_TOKEN_SECRET` | — | Yes | API token secret |
| `PROXMOX_SSH_PASS` | — | No | Root SSH password for `qm set --sshkeys` |
| `PROXMOX_NODE` | `moxy` | No | Proxmox node name |
| `PROXMOX_BRIDGE` | `vmbr0` | No | Network bridge |
| `PROXMOX_TEMPLATE_ID` | `9000` | No | Template VMID to clone |
| `VM_CPU` | `2` | No | Cores per VM |
| `VM_RAM` | `2048` | No | RAM in MB per VM |
| `VM_DISK` | `20` | No | Disk in GB per VM |
| `VM_SSH_USER` | `ubuntu` | No | SSH user for provisioned VMs |
| `VM_OS_TYPE` | `ubuntu` | No | `ubuntu`, `almalinux`, `rocky` |
| `SKIP_UPGRADE` | `false` | No | Skip `apt-get upgrade` in bootstrap |
| `INSTALL_EXTRAS` | `false` | No | Install extra packages in bootstrap |
