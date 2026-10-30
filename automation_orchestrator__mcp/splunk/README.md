# Splunk Enterprise (Docker Compose)

Single-instance Splunk Enterprise for the network demos, running on this host under
Docker Compose. Host ports are deliberately remapped into the `18xxx` range so nothing
collides with the services already bound on this box.

- **Image:** `splunk/splunk:10.6.0` (running `10.6.0.5`, build `86587d4e3b27`)
- **Container / hostname:** `splunk`
- **Restart policy:** `unless-stopped`
- **Runs as:** uid `ansible` inside the container

## Ports

| Host port | Container port | Protocol | Purpose |
|-----------|----------------|----------|---------|
| 18000 | 8000 | HTTP | Splunk Web UI |
| 18089 | 8089 | HTTPS | Management / REST API |
| 18088 | 8088 | HTTPS | HTTP Event Collector (HEC) |
| 19997 | 9997 | TCP | Forwarder receiving (S2S) |

### Why these ports

The host already has 22, 53, 80, 111, 443, 2222, 3000, 3001, 5355, 5900, 6443, 8087 and
36353 bound. Splunk's stock ports would have been a near miss on 8087/8088, so the whole
set is shifted by 10000. **Keep the container side unchanged** — Splunk writes its own
ports into `web.conf` / `server.conf` and forwarders assume the defaults; only the host
side is remapped.

## Credentials

Live in `.env` in this directory (mode `0600`, git-ignored — **never commit it**):

```
SPLUNK_PASSWORD=...     # admin password for the Web UI and REST API
SPLUNK_HEC_TOKEN=...    # bearer token for the HTTP Event Collector
```

Username is `admin`. To regenerate:

```bash
umask 077
printf 'SPLUNK_PASSWORD=%s\nSPLUNK_HEC_TOKEN=%s\n' \
  "$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)" "$(uuidgen)" > .env
```

Changing `SPLUNK_PASSWORD` after first boot does **not** reset the existing admin
password — that is baked into the volume. Either reset it via the CLI (see below) or
destroy the volumes and start clean.

## Licensing

Splunk 10.x refuses to start unattended without **both** of these, which the compose file
sets:

- `SPLUNK_START_ARGS=--accept-license`
- `SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com`

Together these accept the [Splunk General Terms](https://www.splunk.com/en_us/legal/splunk-general-terms.html).
The instance runs on the free/trial license by default — check `licenseState` via the REST
API call below, and mind the daily ingest cap for anything beyond demo volumes.

## Running it

```bash
docker compose up -d          # start (first boot takes ~75s — Splunk self-provisions via Ansible)
docker compose ps             # status
docker compose logs -f splunk # follow logs
docker compose restart        # restart
docker compose down           # stop, keep data
docker compose down -v        # stop and DESTROY all Splunk data
```

Wait for health before using it — the container reports `starting` for over a minute:

```bash
docker inspect -f '{{.State.Health.Status}}' splunk
```

## Access

### From this host

<http://localhost:18000>

### From elsewhere in the VNet

<http://172.16.0.5:18000>

No firewalld change is required. Docker installs its DNAT rules in `nat/DOCKER` and the
`FORWARD` chain jumps to `DOCKER-USER`/`DOCKER-FORWARD` ahead of firewalld's rules, so
published ports bypass the `public` zone entirely.

### From outside the VNet

This VM has **no public IP**, so use an SSH tunnel from your workstation:

```bash
ssh -L 18000:localhost:18000 -L 18089:localhost:18089 azureuser@<this-host>
```

Then browse <http://localhost:18000>.

Exposing it directly would need a public IP plus an Azure NSG allow rule. Do not do that
without first enabling TLS on Splunk Web and restricting the source IP range — the Web UI
is plain HTTP by default.

## Sending data in

### HEC (one-off events, webhooks, scripts)

```bash
. ./.env
curl -sk -H "Authorization: Splunk $SPLUNK_HEC_TOKEN" \
  https://localhost:18088/services/collector/event \
  -d '{"event":"hello from the demo","sourcetype":"manual","index":"main"}'
```

A healthy response is `{"text":"Success","code":0}`. HEC uses a self-signed cert, hence
`-k`.

### Syslog from the Catalyst leafs (UDP 1544)

`setup_splunk.yml` wires this up end to end — it creates the Splunk input, configures the
switches, and then polls Splunk until events from every switch have actually arrived, so
a green run means the pipeline really works. It is idempotent: a second run is
`changed=0`.

Run it through the **Network | setup splunk** job template (AAP id 178, project
`network demos`, inventory `local inventory`), or locally:

```bash
ansible-playbook splunk/setup_splunk.yml -e SPLUNK_PASSWORD='...'
```

The job template carries two credentials for this part, plus a third for the
Event-Driven Ansible play described further down:

| Credential | Type | Provides |
|------------|------|----------|
| `network-devices` | Machine | SSH to the leafs |
| `splunk` | custom `splunk` type | `SPLUNK_HOST`, `SPLUNK_MGMT_PORT`, `SPLUNK_USERNAME`, `SPLUNK_PASSWORD` as extra vars |

The `splunk` credential type stores the password in a `secret: true` field, so it is
encrypted at rest rather than sitting in the template's extra vars.

What it builds:

| Piece | Value |
|-------|-------|
| Listener | UDP 1544, published by `compose.yaml` |
| Index | `cisco_ios` |
| Sourcetype | `cisco:ios` (the TA retypes some lines to `cisco:ios:traceback`) |
| Switch target | `172.20.20.1` — the clab gateway |

Two things about this path are easy to get wrong:

**The leaf management interface is in `Mgmt-vrf`.** `logging host 172.20.20.1 transport
udp port 1544` routes out of the global table and silently goes nowhere. The statement
must name the VRF:

```
logging host 172.20.20.1 vrf Mgmt-vrf transport udp port 1544
```

**Docker rewrites the syslog source address.** Published-port traffic is SNATed to the
bridge gateway, so with the obvious `connection_host = ip` every switch arrives as
`172.18.0.1` and the leafs are indistinguishable. Instead the input uses
`connection_host = none` and an index-time transform lifts the device name out of the
IOS origin-id:

```ini
# transforms.conf
[cisco_ios_host_from_origin_id]
DEST_KEY = MetaData:Host
REGEX    = ^(?:\w{3}\s+\d+\s+[\d:]+\s+\S+\s+)?\d+:\s+([^:\s]+):
FORMAT   = host::$1

# props.conf — bound to the input's source, so retyped traceback lines get it too
[source::udp:1544]
TRANSFORMS-cisco_ios_host = cisco_ios_host_from_origin_id
```

This is index-time config, so it only applies after a splunkd restart and only to events
indexed afterwards. The playbook restarts Splunk only when it actually changes the config.

Check what is arriving:

```bash
. ./.env
curl -sk -u "admin:$SPLUNK_PASSWORD" https://localhost:18089/services/search/jobs/export \
  -d search='search index=cisco_ios earliest=-15m | stats count by host, sourcetype' \
  -d output_mode=csv
```

Healthy output names the devices, not an IP:

```
host,sourcetype,count
Leaf1,"cisco:ios",23
Leaf2,"cisco:ios",17
```

If `host` comes back as `172.18.0.1` or `splunk`, the transform is not loaded — restart
Splunk.

#### Logging CLI configuration changes

The playbook also turns on the IOS configuration change notification feature, so every
command entered at the CLI produces its own syslog:

```
archive
 log config
  logging enable
  logging size 200
  notify syslog contenttype plaintext
```

IOS already sends `%SYS-5-CONFIG_I` when someone leaves config mode, but that only says
*that* something changed. This adds `%PARSER-5-CFGLOG_LOGGEDCMD`, which carries the user
and the exact command:

```
%PARSER-5-CFGLOG_LOGGEDCMD: User:admin  logged command:snmp-server location RACK-42
```

Find them with:

```bash
. ./.env
curl -sk -u "admin:$SPLUNK_PASSWORD" https://localhost:18089/services/search/jobs/export \
  -d search='search index=cisco_ios CFGLOG_LOGGEDCMD | table _time host _raw' \
  -d earliest_time=-24h -d output_mode=csv
```

#### From a config change to Event-Driven Ansible

The last play of `setup_splunk.yml` turns those syslog lines into events:

```
switch CLI -> syslog -> cisco_ios index -> saved search alert
  -> Event-Driven Ansible Add-on for Splunk (webhook)
  -> AAP event stream -> activation of extensions/eda/rulebooks/splunk_compliance.yml
```

| Piece | Name / value |
|-------|--------------|
| Splunk alert | `Cisco IOS - CLI configuration change`, cron `* * * * *` |
| Splunk add-on | `ansible_addon_for_splunk` ("Event-Driven Ansible Add-on for Splunk"), environment `eda` |
| AAP organization | `Network` |
| AAP event stream | `Splunk config change`, Basic auth |
| AAP decision environment | `registry.redhat.io/ansible-automation-platform-27/de-supported-rhel9:latest` |
| AAP project | `network-demos` (this repo, from gitea) |
| AAP activation | `Splunk compliance`, running `extensions/eda/rulebooks/splunk_compliance.yml` |

The rulebook only prints — it logs the saved search name, the matched rows and the
whole event. It is the place to hang real remediation off.

The job template needs a third credential for this play, on top of the two above:

| Credential | Type | Provides |
|------------|------|----------|
| `AAP Credential` | Red Hat Ansible Automation Platform | `CONTROLLER_HOST` and `CONTROLLER_OAUTH_TOKEN` in the environment |

Running it outside AAP needs the same connection details as extra vars:

```bash
ansible-playbook splunk/setup_splunk.yml \
  -e SPLUNK_PASSWORD='...' \
  -e AAP_HOST=https://aap-aap-operator.apps.127.0.0.1.nip.io \
  -e AAP_USERNAME=admin -e AAP_PASSWORD='...'
```

Five things here are easy to get wrong.

**The rulebook's directory is not a free choice.** `eda-server` scans exactly
two paths, in this order, both relative to the repository root:
`extensions/eda/rulebooks`, then `rulebooks`. Nothing else — not `eda/rulebooks`,
not anything deeper. Put it elsewhere and the project sync fails the import with

```
The 'extensions/eda/rulebooks' or 'rulebooks' directory doesn't exist within the project root.
```

and drops the rulebook from the project, which breaks the activation. Worse, the
AAP objects keep running on whatever revision imported successfully last, so the
breakage stays invisible until the next sync. Hence `extensions/eda/rulebooks`,
the first path AAP tries.


**The AAP route is selected by SNI.** `aap-aap-operator.apps.127.0.0.1.nip.io`
resolves to `127.0.0.1`, which inside the Splunk container is the container
itself; connecting to the ingress IP directly returns `503` because the router
has no hostname to match. `compose.yaml` therefore maps the route name to
`host-gateway`, and the add-on keeps posting to the hostname.

**The shared secret is derived, not stored.** The event stream authenticates the
add-on with HTTP Basic, and both ends need the same password on every run or the
playbook would have to rotate the secret each time to stay idempotent. Unless
`EDA_EVENT_STREAM_PASSWORD` is passed in, the password is
`sha256(SPLUNK_PASSWORD:<event stream name>)` — reproducible run to run, and
derivable only by someone who already holds the Splunk admin password. Change
`SPLUNK_PASSWORD` and both the AAP credential and the add-on environment have to
be recreated.

**Saved searches fork if you update them from a user namespace.** Posting a
change to an app-shared object through `servicesNS/admin/...` silently clones it
into admin's private namespace, and from then on there are two searches with the
same name drifting apart — the private one shadowing the shared one, and the ACL
call failing with `Cannot overwrite existing app object`. The playbook creates
and updates the alert through `servicesNS/nobody/search` instead, which is
app-shared from the start and does not fork.

**`results` is not always a list.** The add-on sends a list of rows when the
alert matched several changes in the same minute and a bare dict when it matched
exactly one, so anything in the rulebook that iterates it has to handle both.

The alert runs every minute over `-1m@m` to `@m` — the minute that has just
closed — so the windows do not overlap and nothing is sent twice or skipped.
That needs `realtime_schedule = 0`; left at the default, Splunk runs the search
whenever it can and drops windows when the scheduler is busy. `alert.digest_mode
= 1` sends one webhook per run carrying every change in the window rather than
one webhook per change.

Watch the other end of the chain with:

```bash
kubectl logs -n aap-operator -f \
  "$(kubectl get pods -n aap-operator -o name | grep activation-job | head -1)"
```

A change made on a leaf CLI shows up there within about a minute:

```
** [debug] *********************************************************************
Splunk saved search 'Cisco IOS - CLI configuration change' fired
********************************************************************************
```

Nothing arriving? Check in this order: the event is in the index
(`index=cisco_ios CFGLOG_LOGGEDCMD`), the alert fired
(`index=_internal sourcetype=scheduler savedsearch_name="Cisco IOS - CLI
configuration change"`), the add-on sent it
(`/opt/splunk/var/log/splunk/ansible_addon_for_splunk_*.log` in the container), and the
event stream received it (`events_received` on the event stream in the AAP UI).

**Secrets are masked by `hidekeys`.** Without it, any config line containing a credential
would be shipped to Splunk in clear text. It is the default on this platform and does not
appear in plain `running-config`, so enforcing it would make the task report changed
forever — the playbook asserts it is active instead. Verified: `snmp-server community
<secret> ro` is logged as `snmp-server community * ro`, and the secret itself never
reaches the index.

Two smaller traps, both already handled in the playbook:

- `logging trap informational` is the IOS default, so it never shows in
  `show running-config`. Enforcing it would make the task report changed forever, so the
  playbook leaves it alone.
- `save_when: modified` is wrong on the cat9kv. The image keeps self-signed certificate
  material in running-config that never matches startup, so running is permanently
  "modified" and the config is saved on every run. The playbook uses `save_when: changed`,
  which saves only when the task actually altered the device.
- A duplicate UDP input returns **400** from Splunk, not the 409 that indexes and conf
  stanzas return. The playbook lists the existing inputs and creates only when absent,
  rather than treating 400 as success.

### Onboarding new switches (`setup_splunk_device.yml`)

After a `containerlab redeploy` the leafs come back with their startup config and none
of the above. Run **Splunk | Setup Devices** (AAP id 180, credentials `network-devices`
and `splunk`; limit and extra vars prompted on launch) to bring them back in. Splunk
itself is left alone. It must already be set up by `setup_splunk.yml`.

Per switch it:

1. applies the compliance roles from `extensions/eda/roles`: `logging`, `ntp`, `snmp`
   and `stig-ios`, the same baseline `EDA | Continuous Compliance` enforces;
2. turns on config-change logging (`archive / log config`) and the syslog the Cisco
   Catalyst app dashboards chart: `login on-success log`, `login on-failure log` and
   `spanning-tree logging`. Link up/down, reload and `%SYS-5-CONFIG_I` are on by default;
3. saves once, only if the configuration changed;
4. sends a test event and waits until Splunk has it from every switch in the run.

A second run is `changed=0`. Everything the first run configures is logged as a CLI
change, so the compliance activation fires once against the new switch a minute later
and finds nothing to fix.

The Splunk syslog host is part of the **logging role's baseline**, not just this
playbook. The role uses `state: replaced`, so any host it doesn't list gets removed,
and every compliance run would otherwise cut the switch off from Splunk. Its trap level
is pinned to `informational`: leave `trap` out and the module pushes `no logging trap`,
which on IOS-XE turns syslog to all hosts **off** rather than back to the default.

The `snmp` role passes through SNMPv3 users whose visible settings already match.
IOS never shows user secrets, so without that the role re-sent the user on every run.
Each re-send was logged, alerted on, and launched compliance again, a loop that opened
a ServiceNow incident every couple of minutes.

### Universal Forwarder

Point the forwarder's `outputs.conf` at `<this-host>:19997`. The S2S receiver is enabled
automatically by `SPLUNK_ENABLE_LISTEN: "9997"` in the compose file.

### REST API

```bash
. ./.env
curl -sk -u "admin:$SPLUNK_PASSWORD" \
  'https://localhost:18089/services/server/info?output_mode=json'
```

Run a search:

```bash
. ./.env
curl -sk -u "admin:$SPLUNK_PASSWORD" \
  https://localhost:18089/services/search/jobs/export \
  -d search='search index=main | head 10' -d output_mode=json
```

## Indexes

Out of the box: `main`, `history`, `summary`, `splunklogger`, plus the `_*` internal
indexes. Create more via Settings → Indexes in the UI, or:

```bash
. ./.env
docker exec -u splunk splunk /opt/splunk/bin/splunk add index netops \
  -auth "admin:$SPLUNK_PASSWORD"
```

## Cisco Catalyst app — data model acceleration

The `cisco-catalyst-app` dashboards query the `Cisco_Catalyst_App` data model through a
`summariesonly` macro. Two independent settings control whether they return anything:

| Setting | Where | Current value |
|---------|-------|---------------|
| `acceleration` | `cisco-catalyst-app/local/datamodels.conf` | `true` |
| `summariesonly` macro | `cisco-catalyst-app/local/macros.conf` | `summariesonly=true allow_old_summaries=true` |

The app's packaged default (in `default/macros.conf`) is
`summariesonly=false allow_old_summaries=true` — deliberately chosen so dashboards fall
back to raw search *before* acceleration is ready. A local override set it to
`summariesonly=true` while acceleration was still disabled, which guarantees empty
dashboards: strict summary-only searches against a non-accelerated model match nothing.
Acceleration is now enabled, so the two are consistent again.

Check both before debugging an empty dashboard:

```bash
. ./.env
# acceleration state
docker exec -u splunk splunk /opt/splunk/bin/splunk btool datamodels list Cisco_Catalyst_App --debug | grep acceleration
# effective macro
docker exec -u splunk splunk bash -lc \
  "awk '/^\[summariesonly\]/{p=1;print;next} /^\[/{p=0} p' \
   /opt/splunk/etc/apps/cisco-catalyst-app/local/macros.conf"
```

### Readiness diagnostic

Run all three. The third bypasses the summary entirely, so it separates an acceleration
problem from a *no data* problem:

```bash
. ./.env
for v in 'summariesonly=true  allow_old_summaries=false' \
         'summariesonly=true  allow_old_summaries=true'  \
         'summariesonly=false allow_old_summaries=false'; do
  printf '%-45s ' "$v"
  curl -sk -u "admin:$SPLUNK_PASSWORD" https://localhost:18089/services/search/jobs/export \
    -d search="| tstats $v count from datamodel=Cisco_Catalyst_App" \
    -d earliest_time=0 -d latest_time=now -d output_mode=csv 2>/dev/null | tail -1
done
```

- **All three return 0** → no source data. Acceleration is not the problem; fix ingestion.
- **Third returns rows, first two return 0** → genuine acceleration gap. Let the scheduled
  build run, or rebuild (see below).
- **Second returns rows, first does not** → summaries are stale against the current
  definition. Use `allow_old_summaries=true` or rebuild.

### Summary build

`manual_rebuilds = true` is set, so Splunk will *not* auto-rebuild when the model
definition changes — the scheduled search (`*/15 * * * *`, `earliest_time = -1w`) only
summarizes new data going forward. Inspect state with:

```bash
. ./.env
curl -sk -u "admin:$SPLUNK_PASSWORD" \
  "https://localhost:18089/services/admin/summarization?output_mode=json&count=0"
```

An empty response means no summary is registered yet — expected when nothing matches the
model's constraints. On-disk summaries live in
`/opt/splunk/var/lib/splunk/<index>/datamodel_summary/`.

Only run a manual rebuild when the current definition genuinely must be applied to the
retained time range. **It can take hours** on a populated index, so do it deliberately,
not as a debugging reflex.

### Current state on this instance

Acceleration is enabled, and the Catalyst leafs now feed `cisco:ios` syslog into the
`cisco_ios` index (see the syslog section above), which populates the
`Cisco_Catalyst_IOS_Devices_Events` dataset and the `cisco_ios_*` dashboards.

Everything else in the model — ISE, Meraki, SD-WAN, Cyber Vision, NetFlow, ThousandEyes,
Tenable — still has no source data, so those dashboards stay empty. That is a missing
ingestion problem, not an acceleration one; the readiness diagnostic above tells the two
apart.

## Data and persistence

Two named Docker volumes, so `docker compose down` is safe:

| Volume | Container path | Holds |
|--------|----------------|-------|
| `splunk_splunk-etc` | `/opt/splunk/etc` | configuration, apps, users, licenses |
| `splunk_splunk-var` | `/opt/splunk/var` | indexed data, logs |

On disk under `/var/lib/docker/volumes/`. Named volumes are used rather than bind mounts
to sidestep both the container's uid mismatch and SELinux relabelling on this RHEL 9 host.

Back up configuration:

```bash
docker run --rm -v splunk_splunk-etc:/data -v "$PWD:/backup" \
  alpine tar czf /backup/splunk-etc-$(date +%F).tar.gz -C /data .
```

The archive lands in the current directory owned by `root` (the helper container runs as
root) and is roughly 500 MB, since `etc` carries the bundled apps. `chown` it afterwards
if you need it readable as `azureuser`, and write it somewhere outside this repo.

## Operations

Shell in:

```bash
docker exec -it -u splunk splunk bash
```

Splunk CLI (binary at `/opt/splunk/bin/splunk`). **Always pass `-u splunk`** — `docker exec`
defaults to the `ansible` user, which cannot read splunkd's pid file or config, and every
CLI call fails with confusing `Permission denied` errors:

```bash
. ./.env
docker exec -u splunk splunk /opt/splunk/bin/splunk status
docker exec -u splunk splunk /opt/splunk/bin/splunk list index -auth "admin:$SPLUNK_PASSWORD"
docker exec -u splunk splunk /opt/splunk/bin/splunk restart
```

(The repeated `splunk splunk` is not a typo — it is `-u <user>` followed by the container
name.)

Reset the admin password:

```bash
docker exec -u splunk splunk /opt/splunk/bin/splunk edit user admin \
  -password '<new>' -auth 'admin:<current>'
```

## Troubleshooting

**Container is `unhealthy` and the logs mention the license.** One of the two license
env vars is missing — see the Licensing section.

**Container is `unhealthy` right after `up`.** Expected for the first ~75s while Splunk
provisions itself. Watch `docker compose logs -f splunk` for the Ansible play to finish.

**`SPLUNK_PASSWORD` variable is not set.** `.env` is missing or unreadable. Compose is
configured to fail loudly rather than start with a blank password.

**Web UI unreachable from another machine.** Check the VNet route first
(`curl -s -o /dev/null -w '%{http_code}' http://172.16.0.5:18000/en-US/account/login` from
the host). If that works, the block is upstream — Azure NSG or no public IP.

**Password change in `.env` had no effect.** Expected; the password lives in the volume
after first boot. Reset it via the CLI above.

**`Permission denied` / `splunkd.pid file is unreadable` from `docker exec`.** You are
running as `ansible`. Add `-u splunk`.
