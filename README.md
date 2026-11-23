# Sentinel Ops Installer

Installs and runs Sentinel Ops on a Linux server: self-hosted **Supabase**,
**Logflare** and the **Sentinel Ops frontend**, all in Docker. One command
turns a clean server and a deploy key into a working installation; the same
`sentinel-ops` command then handles updates, backups, restores, rollbacks,
hardening and disk hygiene.

## Documentation

**All documentation is in the [wiki](https://github.com/BrainStation-23/ComplianceOS-installer/wiki)**,
written as a playbook:

- [Before you install](https://github.com/BrainStation-23/ComplianceOS-installer/wiki/Before-You-Install) and [Install](https://github.com/BrainStation-23/ComplianceOS-installer/wiki/Install)
- [Go live on a domain](https://github.com/BrainStation-23/ComplianceOS-installer/wiki/Go-Live-on-a-Domain)
- [Deploy a release](https://github.com/BrainStation-23/ComplianceOS-installer/wiki/Deploy-a-Release), [Backup and restore](https://github.com/BrainStation-23/ComplianceOS-installer/wiki/Backup-and-Restore), [Troubleshooting](https://github.com/BrainStation-23/ComplianceOS-installer/wiki/Troubleshooting)
- [Command reference](https://github.com/BrainStation-23/ComplianceOS-installer/wiki/Command-Reference)

On a server, `sentinel-ops --help` lists every command.

## Contributing

```bash
./tests/run.sh
```

Pull requests go to `main`. A change that alters behaviour updates the wiki too;
see [Contributing](https://github.com/BrainStation-23/ComplianceOS-installer/wiki/Contributing).
