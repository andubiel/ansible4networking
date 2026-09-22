# PSIRT API with Ansible

Example code from the Ansible4Networking demo on automating network vulnerability management using the Cisco PSIRT openVuln API with Ansible.

## Demo Video

[Protect the Network - The PSIRT openVuln API and Ansible Automation](https://www.meetup.com/ansible4networking/)

## Overview

The `cve_audit_workflow.yml` playbook automates CVE discovery and risk assessment for Cisco IOS-XE devices. It connects to routers, collects their running configuration and software version, queries the Cisco PSIRT openVuln API for known vulnerabilities, and then filters results down to only the CVEs that are relevant based on features actually configured on each device.

## Running the Workflow

```bash
ansible-playbook cve_audit_workflow.yml
```

The playbook runs in two plays:

| Play | Hosts | Role |
|------|-------|------|
| Gather router configuration and version | `cisco` | `gather_config` |
| Audit CVEs against running configuration | `localhost` | `cve_audit` |

### Prerequisites

- Cisco PSIRT openVuln API credentials — register at [Cisco API Console](https://apiconsole.cisco.com/) to obtain your `client_id` and `client_secret`
- An inventory group named `cisco` with IOS-XE devices configured for `cisco.ios` connections
- Gitea credentials (`password`, `username`, `email`) for publishing reports

### Required Variables

The following variables must be defined (e.g. via extra vars, group vars, or Ansible Vault):

| Variable | Description |
|----------|-------------|
| `client_id` | OAuth 2.0 client ID for the Cisco PSIRT openVuln API |
| `client_secret` | OAuth 2.0 client secret for the Cisco PSIRT openVuln API |
| `password` | Gitea user password / token for publishing reports |
| `username` | Gitea username for git commit attribution |
| `email` | Gitea email for git commit attribution |

Example using extra vars:

```bash
ansible-playbook cve_audit_workflow.yml \
  -e client_id=YOUR_CLIENT_ID \
  -e client_secret=YOUR_CLIENT_SECRET \
  -e password=YOUR_GITEA_TOKEN \
  -e username=gitea \
  -e email=gitea@example.com
```

## Roles

### `gather_config`

Runs against the `cisco` inventory group to collect device state needed by the audit.

| Task | Description |
|------|-------------|
| Get running configuration | Runs `show running-config` and registers the output for later config-matching |
| Get IOS-XE version | Runs `show version` to capture the full version output |
| Extract IOS-XE version number | Parses the version string (e.g. `17.09.04a`) from the `show version` output using a regex |
| Display detected version | Prints the detected IOS-XE version and hostname for verification |

### `cve_audit`

Runs against `localhost` and is organized into four task files included from `tasks/main.yml`:

#### `authenticate.yml`

| Task | Description |
|------|-------------|
| Generate OAuth 2.0 Access Token | Authenticates to `https://id.cisco.com/oauth2/default/v1/token` using client credentials grant to obtain a bearer token for the PSIRT API |

#### `fetch_advisories.yml`

| Task | Description |
|------|-------------|
| Fetch Security Advisories for each router | Queries the PSIRT API (`/security/advisories/v2/OSType/{os_type}?version={version}`) for every router in the `cisco` group, using each device's detected IOS-XE version |
| Build advisory list with productNames from API response | Structures the raw API response into a per-host dictionary (`audit_results`) containing advisory ID, title, severity, CVEs, product names, and first-fixed versions |

#### `filter_advisories.yml`

| Task | Description |
|------|-------------|
| Filter advisories by configuration relevance | Compares each advisory's title and product names against a feature dictionary. If the advisory maps to a feature and that feature's config commands are found in the router's running config, the advisory is marked **relevant**. If no feature mapping exists, it is flagged for manual review. Advisories for features not present in the config are moved to the **skipped** list. |

The feature dictionary (`roles/cve_audit/defaults/main.yml`) maps feature names to search terms and IOS-XE config commands, covering NAT, zone-based firewall, IOx, RESTCONF, NETCONF, SNMP, SSH, BGP, OSPF, EIGRP, MPLS, QoS, AAA, IPsec, DHCP, and many more.

#### `report.yml`

| Task | Description |
|------|-------------|
| Display RELEVANT CVEs per router | Prints a summary of advisories that match the running config, including severity, CVE IDs, first-fixed versions, and the match reason |
| Display SKIPPED CVEs | Prints advisories that were filtered out because the associated feature is not configured |
| Recommend minimum safe IOS-XE version | Analyzes `firstFixed` versions from all relevant advisories and recommends the highest version on the same major train that resolves all known CVEs |
| Build workflow artifacts per router | Assembles a per-host JSON artifact containing current version, CVE counts, recommended upgrade version, and detailed CVE data |
| Retrieve repository from Gitea | Clones the target Git repository from Gitea using `ansible.scm.git_retrieve` |
| Create report directory in repository | Ensures `cve_discovery/reports/` exists in the cloned repo |
| Write JSON report per router to repository | Writes each host's audit artifact as a JSON file (e.g. `router1_cve_audit.json`) |
| Publish reports to Gitea | Commits and pushes the reports back to Gitea using `ansible.scm.git_publish` |
| Set artifacts for AAP workflow | Uses `set_stats` to expose a summary artifact (`cve_audit_summary`) for downstream nodes in an AAP workflow |
| Display artifact summary | Prints a final overview of all reports published and per-host CVE counts |

## Workflow Diagram

```
┌─────────────────────────────────────────┐
│  Play 1: Gather Config (cisco hosts)    │
│                                         │
│  show running-config ──► running_config │
│  show version ──► ios_version           │
└────────────────────┬────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────┐
│  Play 2: CVE Audit (localhost)          │
│                                         │
│  1. Authenticate ──► Bearer token       │
│  2. Fetch advisories per version        │
│  3. Filter by running config features   │
│  4. Report + publish to Gitea           │
│     └──► set_stats for AAP workflow     │
└─────────────────────────────────────────┘
```
