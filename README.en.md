# IT infrastructure audit kit

[![ci](https://github.com/eightpaws/it-infra-audit-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/eightpaws/it-infra-audit-kit/actions/workflows/ci.yml)

Read-only checks for the three things that fail quietly: an Active Directory domain, a Proxmox VE
hypervisor, and the backup system that everyone believes in until the day they need it.

Every check only reads. Findings are written as JSONL and rendered into one report with risk levels,
so the top of the page answers "what do I fix first". A critical finding makes the renderer exit 1,
which makes the report usable as a monitoring probe.

**[Sample report](https://eightpaws.github.io/it-infra-audit-kit/)** (Russian; generated from the same code)

## Quick start

```powershell
.\windows\Invoke-AdAudit.ps1 -OutFile out\ad-audit.jsonl
.\windows\Invoke-BackupAudit.ps1 -OutFile out\backup-audit.jsonl
```

```bash
./linux/audit-pve.sh out/pve-audit.jsonl
./linux/audit-backups.sh out/backup-audit.jsonl
python3 tools/render.py out/*.jsonl -o out/report.md
```

## What it checks

| Area | Checks |
|---|---|
| Domain | forest mode, FSMO roles, replication errors, privileged group size, Protected Users, `adminCount` leftovers, LAPS coverage, krbtgt age, GPO changes, `MachineAccountQuota` |
| Windows backups | Windows Server Backup versions and age, `Backup-GPO` freshness, VSS writers, DSRM password saved or not |
| Proxmox VE | quorum, `vzdump` jobs (missing, disabled, `suspend` mode), last run log, storage fill, replication, cluster config age |
| Linux backups | backup timers, age of backup directories, database dumps, restore-drill log |

## Why the checks look like this

They come from operational failures, not from articles: `MachineAccountQuota` returns a collection
instead of a number; `Get-DnsServerZone` without `-ComputerName` silently returns nothing, which reads
as "no zones" instead of "nobody to ask"; a backup job reporting success does not mean it restores;
`suspend` in `vzdump` stops the VM. Each pitfall is documented, and an empty value is reported as a
finding rather than as health.

## Limits

- No asset inventory, licensing or hardware auditing: this is state of domain, VMs and copies.
- AD checks need the `ActiveDirectory` module; `repadmin`, `dcdiag`, `vssadmin` need elevation and are
  marked as unreadable when it is missing.
- Severity is expert judgement: what stops the business or leaks data, not a formal standard.

## Related repositories

| Repository | What it adds |
|---|---|
| [v100-field-notes](https://github.com/eightpaws/v100-field-notes) | the measurements the model-selection rules come from |
| [onprem-llm-closed-loop](https://github.com/eightpaws/onprem-llm-closed-loop) | an LLM stand with no route to the internet, isolation verified by a script |
| [eightpaws](https://github.com/eightpaws) | profile: what else is published |

Russian documentation: [README.md](README.md). License: MIT for code (`LICENSE`), CC BY 4.0 for text and docs (`LICENSE-DOCS`).
