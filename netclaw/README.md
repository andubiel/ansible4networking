# NetClaw - Agentic AI with Ansible Automation Platform

These files are from a past meetup demonstrating OpenClaw as an Agentic AI assistant to automate Cisco switches with the Ansible Automation Platform.

## Meetup Recording & Resources

- **Demo Recording:** <https://youtu.be/FfEyO0StgBQ>
- **Overview Video:** <https://youtu.be/AHLc76T7tYs>
- **Slides:** <https://drive.google.com/file/d/1ZIhYeI0VbCLqLe56DFf7iA76t7jdWXqu/view?usp=sharing>

## Key Takeaways

- AI assistants are becoming very convenient for gleaning information and troubleshooting network issues quickly
- AI assistants should be guardrailed and limited from actually configuring devices directly
- Ansible AAP integrates with AI and provides a secure and efficient option for provisioning devices
- The new Ansible Automation Orchestrator has an exciting future with AI-driven workflows

## Files

| File | Description |
|------|-------------|
| `config_push.yml` | Ansible playbook that pushes port security configuration to a Cisco IOS switch using a Jinja2 template |
| `port_security.j2` | Jinja2 template that generates switchport and port-security config with sticky MAC addresses |
| `port_security_dict.j2` | Jinja2 template variant that generates switchport and port-security config from dictionary-style interface data |

