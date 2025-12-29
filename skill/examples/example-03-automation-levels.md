# Example 03: Using All Three Automation Levels

This example demonstrates when and how to use each level of the hybrid automation strategy.

---

## Level 1: Simple Package Installation

### User Request
"Install nginx on the new VM"

### Agent Workflow (Level 1 - Direct Commands)

**Why Level 1?** Simple operation, standard package manager, non-interactive flags available

```bash
# Execute via MCP exec tool
ssh ubuntu@192.168.101.113 "export DEBIAN_FRONTEND=noninteractive && sudo apt-get update -qq && sudo apt-get install -y nginx"
```

**Output:**
```
Reading package lists...
Building dependency tree...
nginx is already the newest version (1.24.0-1ubuntu1)
0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.
```

**Result:** ✅ Nginx installed successfully using Level 1 (direct non-interactive flags)

**Time:** ~5 seconds

---

## Level 2: Cross-Distro Development Environment Setup

### User Request
"Set up a complete development environment with Git, Node.js, Docker, and Python"

### Agent Workflow (Level 2 - Smart Wrappers)

**Why Level 2?**
- Multiple packages to install
- Different distros use different package managers
- Want reusable, tested logic
- Cross-distro compatibility important

**Step 1: Upload noninteractive.sh library**
```bash
# Read library from local project
cat /home/sblanken/working/linusstr/shared/lib/noninteractive.sh

# Upload to VM via base64 encoding (MCP exec tool)
echo 'BASE64_ENCODED_LIBRARY' | base64 -d > /tmp/noninteractive.sh
chmod +x /tmp/noninteractive.sh
```

**Step 2: Create and execute setup script**
```bash
#!/usr/bin/env bash
source /tmp/noninteractive.sh

# Package management (auto-detects Ubuntu)
pkg_update
pkg_install git curl wget vim

# Install Node.js (via NodeSource)
download_file https://deb.nodesource.com/setup_22.x /tmp/nodesource_setup.sh
bash /tmp/nodesource_setup.sh
pkg_install nodejs

# Install Docker (official method)
pkg_install ca-certificates gnupg
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list
pkg_update
pkg_install docker-ce docker-ce-cli containerd.io

# Install Python
pkg_install python3 python3-pip python3-venv

# Configure services
service_enable docker
service_start docker

# Add user to docker group
user_add_to_group ubuntu docker

echo "LINUS_RESULT:SUCCESS"
```

**Result:** ✅ Complete dev environment set up using Level 2 smart wrappers

**Benefits:**
- Same script works on Ubuntu, AlmaLinux, Rocky Linux
- Safe file operations with `safe_copy`, `safe_remove`
- Service management abstracted (systemd vs sysvinit)
- Reusable patterns

**Time:** ~2 minutes

---

## Level 3: Long-Running Kubernetes Installation

### User Request
"Install Kubernetes on the VM - this might take a while"

### Agent Workflow (Level 3 - TMUX Session)

**Why Level 3?**
- Installation takes 5-10 minutes (exceeds MCP timeout)
- Need to monitor progress in real-time
- Multiple reboots might be needed
- Want session persistence if connection drops

**Step 1: Upload tmux-helper.sh library**
```bash
# Upload library to VM
cat /home/sblanken/working/linusstr/shared/lib/tmux-helper.sh | base64 | \
  ssh ubuntu@192.168.101.113 "base64 -d > /tmp/tmux-helper.sh && chmod +x /tmp/tmux-helper.sh"
```

**Step 2: Create Kubernetes installation script**
```bash
#!/usr/bin/env bash
# k8s-install.sh

set -euo pipefail

echo "Starting Kubernetes installation..."

# Disable swap
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Install dependencies
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y apt-transport-https ca-certificates curl

# Add Kubernetes repository
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

# Install kubelet, kubeadm, kubectl
sudo apt-get update -qq
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# Initialize Kubernetes cluster (takes 5+ minutes)
echo "Initializing cluster (this takes several minutes)..."
sudo kubeadm init --pod-network-cidr=10.244.0.0/16

# Configure kubectl for ubuntu user
mkdir -p /home/ubuntu/.kube
sudo cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config

# Install Flannel CNI
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

# Wait for all pods to be ready
echo "Waiting for all system pods to be ready..."
kubectl wait --for=condition=Ready pods --all -n kube-system --timeout=300s

echo "LINUS_RESULT:SUCCESS"
echo "LINUS_K8S_VERSION:$(kubectl version --short --client 2>/dev/null | grep Client)"
echo "LINUS_NODE_STATUS:$(kubectl get nodes -o wide --no-headers | awk '{print $2}')"
```

**Step 3: Execute via TMUX session**
```bash
# On Proxmox host, create TMUX session for monitoring
ssh root@192.168.101.155

# Source tmux-helper library
source /root/linus-deployment/shared/lib/tmux-helper.sh

# Create remote TMUX session on the VM
tmux_remote_create "ubuntu@192.168.101.113" "k8s-install" "/tmp/k8s-install.sh"

# Monitor the session output (non-blocking)
tmux_remote_capture "ubuntu@192.168.101.113" "k8s-install" 20

# Monitor for completion (timeout: 15 minutes)
if tmux_monitor_output_remote "ubuntu@192.168.101.113" "k8s-install" \
                               "LINUS_RESULT:SUCCESS" \
                               "LINUS_RESULT:FAILURE" \
                               900; then
    echo "✅ Kubernetes installation complete!"

    # Capture final output
    tmux_remote_capture "ubuntu@192.168.101.113" "k8s-install" 50

    # Cleanup TMUX session
    tmux_remote_kill "ubuntu@192.168.101.113" "k8s-install"
else
    echo "❌ Kubernetes installation failed or timed out"

    # Capture error logs
    tmux_remote_capture "ubuntu@192.168.101.113" "k8s-install" 100

    # Keep session alive for debugging
    echo "TMUX session 'k8s-install' left running for investigation"
fi
```

**Agent provides real-time updates to user:**

```
⏳ Kubernetes installation in progress...

[00:30] Installing dependencies...
[01:45] Adding Kubernetes repository...
[02:30] Installing kubelet, kubeadm, kubectl...
[04:00] Initializing cluster (this may take 5-10 minutes)...
[09:30] Installing Flannel CNI...
[10:45] Waiting for system pods to be ready...

✅ Kubernetes installation complete!
- K8s Version: v1.28.0
- Node Status: Ready
- Time: 11 minutes 23 seconds
```

**Result:** ✅ Kubernetes installed successfully using Level 3 TMUX session

**Benefits:**
- Survived 11-minute installation (no timeout)
- Real-time progress monitoring
- Session persists if SSH connection drops
- Can attach to session for debugging
- Captured full installation log

**Time:** ~11 minutes (operation), ~30 seconds (setup overhead)

---

## Decision Matrix Summary

| Operation | Duration | Interaction | Complexity | Level | Tool |
|-----------|----------|-------------|------------|-------|------|
| Install single package | <30s | None | Low | 1 | Direct flags |
| Setup dev environment | 1-3 min | None | Medium | 2 | noninteractive.sh |
| Install Kubernetes | 5-15 min | None | High | 3 | tmux-helper.sh |
| Simple file copy | <10s | None | Low | 1 | cp -f |
| Multi-distro deployment | 1-5 min | None | Medium | 2 | noninteractive.sh |
| Build from source | 10+ min | Possible | High | 3 | tmux-helper.sh |
| Restart service | <5s | None | Low | 1 | systemctl |
| Configure firewall | <30s | None | Medium | 2 | noninteractive.sh |
| Database migration | 5+ min | Possible | High | 3 | tmux-helper.sh |

---

## Key Principles

1. **Start Simple:** Always try Level 1 first
2. **Escalate When Needed:** Move to Level 2 for patterns, Level 3 for long-running
3. **Don't Over-Engineer:** Most operations are Level 1 (95%)
4. **Know Your Tools:** Understand when each level adds value
5. **Test Locally First:** Verify script syntax before remote execution

---

## Complete Example: Full Stack Deployment

### User Request
"Deploy a complete LAMP stack on the VM"

### Multi-Level Approach

**Level 1: Install base packages**
```bash
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y apache2 mysql-server php libapache2-mod-php php-mysql
```

**Level 2: Configure services cross-platform**
```bash
source /tmp/noninteractive.sh

service_enable apache2
service_enable mysql
service_start apache2
service_start mysql

# Safe configuration file updates
safe_copy /etc/apache2/sites-available/000-default.conf \
          /etc/apache2/sites-available/000-default.conf.bak
```

**Level 3: Import large database (if >5 minutes)**
```bash
source /tmp/tmux-helper.sh

tmux_remote_create "ubuntu@192.168.101.113" "db-import" \
  "mysql -u root < /tmp/large-database.sql"

tmux_monitor_output_remote "ubuntu@192.168.101.113" "db-import" \
  "IMPORT COMPLETE" "ERROR" 600
```

**Result:** Efficient deployment using the right level for each task

**Total Time:** ~8 minutes
- Package installation: 2 min (Level 1)
- Service configuration: 30s (Level 2)
- Database import: 5 min (Level 3)
- Verification: 30s (Level 1)
