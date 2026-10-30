# Introduction to Ansible Automation Orchestrator and MCP for Networking

These files are from the Ansible4Networking meetup **Introduction to Ansible Automation Orchestrator and MCP for Networking**, held on **October 29th, 2026**.

## Meetup Recording

- **Recording:** <https://youtu.be/-zheXw8zsy8?si=DnmVZjlp7Y4BF4zm>

## Files

### `example_ao_workflow_config.json`

Example Ansible Automation Orchestrator workflow export (`port-security-workflow`) from the demo. It combines AI agent steps, which use MCP tools, with deterministic AAP job templates. When the workflow is triggered for a `device_name`, it:

1. **SNOW | Open Incident**: opens a ServiceNow incident for the port security compliance check.
2. **Restconf MCP agent**: calls `find_unsecured_ports` on the switch through a RESTCONF MCP server and returns a JSON list of ports without port security.
3. **Condition**: if unsecured ports were found (or the check failed), the workflow moves on to review. Otherwise it closes the incident as already compliant.
4. **Review unsecured ports**: a human approval step that rejects automatically if nobody decides within 24 hours.
5. **Launch NETWORK | Port Security (AAP MCP agent)**: if the review is approved, an agent launches the port security job template through the AAP MCP server.
6. **Network | Display Port Security**: runs `deterministic/port_security_display.yml` to check and report the remediated ports.
7. **SNOW | Close Incident**: closes the incident and attaches the remediation results and the verified port security report.

If the review is rejected, an agent step reports the ports that still need remediation.

Credential, integration, and model IDs in the export belong to the demo environment. Replace them with your own before you import the workflow.

### `deterministic/`

Deterministic port security playbooks that Ansible Automation Orchestrator calls against Cisco IOS switches.

| File | Description |
|------|-------------|
| `port_security.yml` | Playbook that makes sure the VLAN exists and pushes port security config to the given interfaces |
| `port_security.j2` | Jinja2 template that generates access-mode switchport and sticky-MAC port security config for each interface |
| `port_security_display.yml` | Playbook that checks and reports port security on the remediated ports. It accepts the interface list in any of the formats Orchestrator passes in, and reports when there were no ports to fix |

### `servicenow/`

ServiceNow playbooks behind the workflow's **SNOW | Open Incident** and **SNOW | Close Incident** job templates. Both use the `servicenow.itsm` collection and read the instance details from `SN_HOST`, `SN_USERNAME`, and `SN_PASSWORD`.

| File | Description |
|------|-------------|
| `snow_open.yml` | Opens a high impact, high urgency incident from `snow_description` and passes the incident number on as the `snow_vars` artifact |
| `snow_close.yml` | Closes the incident named in `snow_vars` and adds `closed_notes` to the close notes |

## Return to Demo Menu

- [Menu of Demos](../README.md)
