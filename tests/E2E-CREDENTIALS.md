# E2E Test Credentials Guide

This document describes how to provide credentials for running E2E tests across different providers.

## Credential Methods

### Method 1: Environment Variables (Local Testing)

Export credentials before running tests:

```bash
# AWS credentials
export AWS_ACCESS_KEY_ID=your_access_key
export AWS_SECRET_ACCESS_KEY=your_secret_key
export AWS_REGION=us-west-2
export AWS_KEY_NAME=your_key_pair

# QEMU credentials  
export QEMU_HOST=192.168.1.100
export QEMU_USER=your_username
export QEMU_SUDO_PASS=your_password

# Proxmox credentials (already in existing tests)
export PROXMOX_HOST=192.168.1.50
export PROXMOX_USER=root
export PROXMOX_TOKEN_ID=your_token
export PROXMOX_TOKEN_SECRET=your_secret
```

### Method 2: GitHub Secrets (CI/CD)

Add secrets to your repository at `Settings -> Secrets and variables -> Actions`:

| Secret Name | Required For | Description |
|-------------|--------------|-------------|
| `AWS_ACCESS_KEY_ID` | AWS E2E | AWS access key |
| `AWS_SECRET_ACCESS_KEY` | AWS E2E | AWS secret key |
| `AWS_REGION` | AWS E2E | AWS region |
| `AWS_KEY_NAME` | AWS E2E | EC2 key pair name |
| `QEMU_HOST` | QEMU E2E | QEMU/KVM host IP |
| `QEMU_USER` | QEMU E2E | SSH username |
| `QEMU_SUDO_PASS` | QEMU E2E | User password |
| `QEMU_SSH_KEY` | QEMU E2E | Private key content (base64) |
| `PROXMOX_HOST` | Proxmox E2E | Proxmox host IP |
| `PROXMOX_USER` | Proxmox E2E | API user |
| `PROXMOX_TOKEN_ID` | Proxmox E2E | API token ID |
| `PROXMOX_TOKEN_SECRET` | Proxmox E2E | API token secret |

### Method 3: AWS Credentials File

For local AWS testing, you can also use the standard AWS credentials file:

```bash
# ~/.aws/credentials
[default]
aws_access_key_id = your_access_key
aws_secret_access_key = your_secret_key
```

## Test Runner Integration

The test runner supports selecting specific provider tests:

```bash
# Run all E2E tests
./tests/run-all-tests.sh --e2e-only

# Run specific provider
./tests/e2e/test-full-workflow.sh        # Proxmox
./tests/e2e/test-aws-workflow.sh         # AWS  
./tests/e2e/test-qemu-workflow.sh        # QEMU
```

## CI/CD Considerations

### Standard GitHub Runners

- **Smoke tests**: ✅ Run automatically
- **ShellCheck**: ✅ Run automatically
- **Integration tests**: ⚠️ Require pre-existing VM
- **Proxmox E2E**: ⚠️ Requires self-hosted runner with Proxmox access
- **AWS E2E**: ⚠️ Requires runner with AWS credentials as secrets
- **QEMU E2E**: ❌ Requires self-hosted runner with QEMU/KVM access

### Self-Hosted Runners

For full E2E coverage, set up self-hosted runners with:

1. **Proxmox runner**: Access to Proxmox VE API
2. **AWS runner**: AWS credentials with limited permissions
3. **QEMU runner**: Access to QEMU/KVM host

## Security Best Practices

1. **Never commit credentials** to the repository
2. **Use GitHub Secrets** for CI/CD credentials
3. **Rotate credentials** regularly
4. **Use IAM roles** where possible (AWS)
5. **Limit permissions** - create dedicated test credentials with minimal required access
6. **Audit access** - review who has access to secrets

## AWS IAM Policy for Testing

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:RunInstances",
                "ec2:DescribeInstances",
                "ec2:DescribeInstanceStatus",
                "ec2:TerminateInstances",
                "ec2:CreateTags",
                "ec2:DescribeImages",
                "ec2:DescribeVpcs",
                "ec2:DescribeSubnets",
                "ec2:DescribeSecurityGroups"
            ],
            "Resource": "*"
        }
    ]
}
```

## Proxmox API Token

Create a token in Proxmox web UI:
1. Datacenter → API Tokens
2. Add: Token ID (e.g., `linus-test`)
3. Copy the secret value
4. Assign appropriate permissions to the token

## QEMU SSH Key Setup

```bash
# Generate dedicated test key
ssh-keygen -t ed25519 -f ~/.ssh/linus_test_key -N ""

# Copy to QEMU host
ssh-copy-id -i ~/.ssh/linus_test_key user@qemu-host

# Or use password-based auth
export QEMU_SUDO_PASS=your_password
```
