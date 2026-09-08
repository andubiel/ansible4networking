# ZTNA — Zero Trust Network Access with MAB, EDA, and NetBox SSOT

This demo shows how FreeRADIUS, Event Driven Ansible (EDA), Ansible Automation Platform (AAP), and NetBox work together to implement Zero Trust Network Access using MAC Authentication Bypass (MAB). When an endpoint connects to a switch port, the system automatically authenticates it, moves it to the correct VLAN, updates NetBox as the Single Source of Truth (SSOT), and opens/closes a ServiceNow incident — all without human intervention.

## Architecture Overview

```
┌──────────────┐    MAB Auth     ┌──────────────┐   Webhook (POST)   ┌──────────────┐
│   Endpoint   │───────────────▶ │  Catalyst 9k │──────────────────▶ │  FreeRADIUS   │
│  (host1/2)   │                 │   (leaf1)     │                    │              │
└──────────────┘                 └──────┬───────┘                    └──────┬───────┘
                                       │                                    │
                                       │                          eda_webhook.sh
                                       │                          (exec module)
                                       │                                    │
                                       │                                    ▼
                                       │                            ┌──────────────┐
                                       │                            │  EDA Rulebook │
                                       │◀───── remediate.yml ──────│  Activation   │
                                       │     (move VLAN, update     │  (port 5000)  │
                                       │      description)          └──────┬───────┘
                                       │                                    │
                                       │                          run_job_template:
                                       │                          "ZTNA Remediate"
                                       │                                    │
                                       ▼                                    ▼
                                ┌──────────────┐                    ┌──────────────┐
                                │   NetBox      │◀── Update SSOT ───│     AAP      │
                                │   (SSOT)      │                   │  Workflow     │
                                └──────────────┘                    └──────┬───────┘
                                                                           │
                                                                    ┌──────┴───────┐
                                                                    │  ServiceNow  │
                                                                    │  (incident)  │
                                                                    └──────────────┘
```

## How It Works — Step by Step

### 1. Endpoint Connects (MAB Authentication)

When an endpoint plugs into a switch port (e.g., `GigabitEthernet1/0/2`), the Catalyst 9000 switch initiates **MAC Authentication Bypass (MAB)**. The switch sends the endpoint's MAC address to FreeRADIUS for authentication.

- **Switch config**: `config_cat9k.yml` configures AAA, RADIUS, dot1x, and MAB on access ports
- **Initial state**: Unauthenticated ports start in VLAN 999 (`BLACKHOLE`)

### 2. FreeRADIUS Authenticates and Triggers EDA

FreeRADIUS checks the MAC address against the `authorize` file, which maps known MACs to Security Group Tags (SGTs):

```
001a2b3c4d5e Cleartext-Password := "001a2b3c4d5e"
    Cisco-AVPair = "cts:security-group-tag=0000-00-000F"
```

On successful authentication, FreeRADIUS executes the `eda_exec` module, which calls `eda_webhook.sh`. This script sends a webhook POST to the EDA rulebook activation listener with the switch name, IP, MAC address, SGT, and interface.

### 3. EDA Rulebook Activation Receives the Event

The `rulebooks/ztna.yml` rulebook listens on port 5000 for webhook events. When it receives a `MAB_Authenticated` event, it:

1. **Logs** the authentication details (switch, MAC, SGT, interface)
2. **Triggers** the `ZTNA Remediate` job template in AAP, passing all event data as extra vars
3. **Throttles** duplicate events — same MAC address is processed only once within 30 seconds

### 4. AAP Workflow Remediates the Network and Updates SSOT

The `remediate.yml` playbook runs as an AAP workflow and performs four actions:

| Step | Action | Detail |
|------|--------|--------|
| 1 | **Open ServiceNow incident** | Creates a high-urgency ticket documenting the MAB authentication event |
| 2 | **Move port to Users VLAN** | Switches the authenticated port from VLAN 999 (BLACKHOLE) to VLAN 50 (ZTNA_USERS) |
| 3 | **Update interface description** | Changes the port description to reflect "Authenticated MAB Endpoint" |
| 4 | **Update NetBox SSOT** | Updates the `MAB_PORTS` config context in NetBox with the new VLAN and auth status |
| 5 | **Close ServiceNow incident** | Closes the ticket with the updated NetBox SSOT configuration as proof |

### 5. NetBox Reflects the Current Truth

After remediation, NetBox's `MAB_PORTS` config context is updated to reflect the real network state — which ports are authenticated, what VLAN they're in, and their status. This keeps NetBox as the **Single Source of Truth** for the ZTNA deployment.

The `diff.yml` playbook can then compare the live switch NTP configuration against NetBox config contexts to detect drift.

## Directory Structure

```
ztna/
├── eda_webhook.sh              # Webhook script called by FreeRADIUS on MAB auth
├── group_vars/
│   └── all.yml                 # NetBox URL, sites, device types, platforms, devices
├── host_vars/
│   └── leaf1/
│       └── vars.yml            # RADIUS config, VLANs, MAB port definitions
├── playbooks/
│   ├── setup_netbox.yml        # Populate NetBox with sites, devices, config contexts
│   ├── config_cat9k.yml        # Configure switch: VLANs, AAA, RADIUS, MAB, OSPF
│   ├── authenticate.yml        # Trigger and verify MAB authentication
│   ├── remediate.yml           # Move VLAN, update NetBox SSOT, SNOW ticket lifecycle
│   └── diff.yml                # Drift detection: compare live config vs NetBox SSOT
├── radius_config/
│   ├── authorize               # FreeRADIUS MAB entries (MAC → SGT mapping)
│   ├── clients.conf            # RADIUS client definitions (switch → shared secret)
│   ├── eda_exec                # FreeRADIUS exec module: calls eda_webhook.sh
│   └── exec                    # Default FreeRADIUS exec module config
└── rulebooks/
    └── ztna.yml                # EDA rulebook: webhook listener → AAP job template
```

## Workflow Execution Order

1. **`setup_netbox.yml`** — One-time setup: populate NetBox with sites, devices, platforms, config contexts (NTP_IOS, MAB_PORTS), and config templates
2. **`config_cat9k.yml`** — Configure the Catalyst 9000 switch with VLANs, SVIs, AAA, RADIUS, MAB, OSPF, and NTP
3. **Deploy FreeRADIUS** — Install `radius_config/` files on the RADIUS server
4. **Activate EDA Rulebook** — Start the `ztna.yml` rulebook activation in AAP listening on port 5000
5. **`authenticate.yml`** — (Optional) Trigger MAB authentication from test endpoints
6. **Automated loop**: endpoint connects → RADIUS authenticates → webhook fires → EDA triggers → AAP remediates → NetBox updated → SNOW ticket closed
7. **`diff.yml`** — (Optional) Run drift detection against NetBox SSOT

## Return to Demo Menu

- [Menu of Demos](../README.md)
