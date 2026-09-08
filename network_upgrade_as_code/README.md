# Network Upgrade as Code — IOS-XE Upgrades with AAP Workflow and Approval

This demo shows how to automate Cisco IOS-XE upgrades using two Ansible playbooks stitched together with an **Ansible Automation Platform (AAP) Workflow** and an **Approval Node** between them. The workflow separates image staging from the actual upgrade, giving a network engineer or change manager the chance to review and approve before the device reloads.

## Demo Video

[IOS Upgrades with Ansible](https://youtu.be/-6OAT8dZop8)

## AAP Workflow Overview

The AAP Workflow Template (`Network-Upgrade-Workflow`) chains three nodes together:

```
┌─────────────────────┐        ┌─────────────────────┐        ┌─────────────────────┐
│   1. STAGING        │        │   2. APPROVAL NODE   │        │   3. UPGRADE         │
│                     │        │                      │        │                      │
│  staging.yml        │───────▶│  Human approval      │───────▶│  upgrade.yml         │
│                     │        │  required before      │        │                      │
│  - SCP image to     │        │  proceeding           │        │  - Set boot system   │
│    bootflash        │        │                      │        │  - Install activate   │
│  - SHA512 verify    │        │  ┌────────┐          │        │    and commit         │
│                     │        │  │Approve │ ──▶ Yes  │        │  - Wait for reboot   │
│                     │        │  │ or     │          │        │  - Verify version    │
│                     │        │  │Deny   │ ──▶ Stop │        │                      │
│                     │        │  └────────┘          │        │                      │
└─────────────────────┘        └─────────────────────┘        └─────────────────────┘
```

When you launch the workflow, AAP prompts for the IOS version (e.g., `17.15.01a`). This variable is passed through to both the staging and upgrade job templates via a **Survey** or **extra_vars**.

## How It Works — Step by Step

### Step 1: Staging (`staging.yml`)

The staging playbook prepares the device for upgrade without any disruption to the network:

| Task | What It Does |
|------|--------------|
| **Enable SCP** | Configures `ip scp server enable` and TCP/SSH window sizes for fast transfers |
| **Check bootflash** | Looks for the image on the device — skips the transfer if it already exists |
| **SCP transfer** | Copies the IOS-XE `.bin` image from an SCP server to the router's bootflash |
| **SHA512 verification** | Runs `verify /sha512` on the device to confirm the image is intact — **fails the workflow** if the hash doesn't match |

At this point the image is safely on the device, but the router is still running the old version. Nothing has changed operationally.

### Step 2: Approval Node (AAP Built-in)

The workflow **pauses** at the Approval Node. AAP sends a notification and waits for an authorized user to approve or deny the upgrade.

This is where change control happens:

- **Approve** — The workflow continues to the upgrade step
- **Deny** — The workflow stops; the staged image remains on bootflash but the device stays on the current version
- **Timeout** — If no one responds within the configured window, the workflow is denied automatically

The Approval Node is configured directly in the AAP Workflow Visualizer — no playbook needed. You can set:
- Who can approve (users, teams, or roles)
- Timeout duration
- Notification templates (email, Slack, webhook)

### Step 3: Upgrade (`upgrade.yml`)

Once approved, the upgrade playbook executes the actual IOS-XE upgrade:

| Task | What It Does |
|------|--------------|
| **Set boot system** | Clears old boot statements and sets `boot system bootflash:packages.conf` |
| **Verify image exists** | Double-checks the staged image is still on bootflash — **fails if missing** |
| **Install activate commit** | Runs `install add file bootflash:<image> activate commit` which adds, activates, and commits the new image in one operation |
| **Wait for reboot** | Monitors the SSH port (up to ~9 minutes) until the device comes back online |
| **Retry until ready** | Retries `show version` up to 10 times (30s apart) until IOS-XE is fully ready |
| **Assert version** | Verifies the running version matches the target — **fails if the upgrade didn't take** |

## Why Separate Staging from Upgrading?

| Concern | How the Workflow Addresses It |
|---------|-------------------------------|
| **Change control** | The Approval Node enforces that a human reviews and approves before any reload happens |
| **Maintenance windows** | Stage images during business hours, approve the upgrade when the maintenance window opens |
| **Risk reduction** | SHA512 verification catches corrupt images *before* the upgrade attempt |
| **Rollback safety** | If the staging fails (bad hash, transfer error), the workflow stops — the device is untouched |
| **Audit trail** | AAP logs who approved, when, and the full job output for both staging and upgrade |

## Variables

The workflow expects these variables, typically provided via an AAP Survey:

| Variable | Description | Example |
|----------|-------------|---------|
| `image_upgrade` | IOS-XE version string | `17.15.01a` |
| `new_image_ios` | Full image filename (derived) | `c8000v-universalk9.17.15.01a.SPA.bin` |
| `sha_hash` | Expected SHA512 hash of the image | *(from Cisco)* |
| `scp_server` | SCP server IP or hostname | `192.168.1.10` |
| `scp_user` | SCP username | `student` |
| `scp_password` | SCP password | *(credential in AAP)* |

## Key Takeaways

- **Staging is non-disruptive** — SCP the image and verify integrity without affecting the running network
- **Approval Nodes enforce change control** — no upgrade happens without explicit human authorization
- **Assertions validate success** — SHA512 hash check pre-upgrade, version assertion post-upgrade
- **AAP Workflow ties it all together** — a single launch stages, waits for approval, upgrades, reboots, and validates

## Return to Demo Menu

- [Menu of Demos](../README.md)
