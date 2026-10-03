# The Work stack

Tools for work done for other people: clients, contracts, freelance projects.
Written 2026-10-03. Single user, admin zone only, nothing public.

## Rules

1. **No client names or client data in this repository.** proxlab is public.
   Stack files, hostnames, and comments stay generic. Client records live on
   `/mnt/work` and in private per-project repositories.
2. **Client data lives on `/mnt/work`, its own disk.** Not on `/mnt/safe`, not
   on `CONFIG_ROOT`. One mount holds everything that belongs to clients, so it
   can be backed up, moved, encrypted, or handed over as one unit.
3. **Every Work service checks that `/mnt/work` is mounted before it deploys.**
   An unmounted `/mnt/work` is an empty directory on the root disk. A service
   that starts there looks like it lost every record.
4. **Formal documents are Markdown in git, not in a service.** Proposals,
   contracts, plans, and stage reports live in each project's own repository
   and are rendered to PDF with `work-kit` only when they are sent. OpenProject
   holds the live management records (risks, issues, decisions, hours).

## Layout of `/mnt/work`

```
/mnt/work
├── openproject/
│   ├── assets/      attachments            (backed up)
│   └── postgres/    live database files    (EXCLUDED - the dump is the backup)
├── db/
│   └── openproject.sql.gz   nightly dump by restic-backup.sh
└── documents/       later: signed contracts, receipts (Paperless-ngx)
```

## Services

| Stack | Name | Status |
|---|---|---|
| `stacks/work/openproject` | `projects.admin.jjventer.co.za` | Added 2026-10-03. OpenProject 17, PostgreSQL 17 |
| Paperless-ngx | - | Later, for receipts and tax documents |
| Invoice Ninja | - | Later, when a Markdown invoice template stops being enough |
| DocuSeal (e-signatures) | - | On the VPS when it exists. Must be always-on and public |

## Creating the work disk

Same pattern as `/mnt/safe` (see docs/HARDWARE.md, "Final layout on VM 110").
A thin volume on `tank`, so the size only costs what is written.

On `pve`. Same options as `scsi2` and `scsi3` (checked 2026-10-03):

```sh
qm set 110 --scsi4 tank:50,discard=on,iothread=1
echo "info block" | qm monitor 110 | grep -A4 drive-scsi4   # want discard unmap, no zeroinit
```

On `pve-prod`. Check the device name first. Letters move between boots.

```sh
lsblk -o NAME,SIZE,LABEL,MOUNTPOINT            # the new 50G disk, no label, no mount
sudo wipefs -n /dev/sdX                        # must print nothing: no old signatures
sudo mkfs.ext4 -m 0 -L work -E lazy_itable_init=0,lazy_journal_init=0 /dev/sdX
echo "UUID=$(sudo blkid -s UUID -o value /dev/sdX)  /mnt/work  ext4  defaults,nofail,x-systemd.device-timeout=10  0  2" \
  | sudo tee -a /etc/fstab
sudo mkdir -p /mnt/work && sudo systemctl daemon-reload && sudo mount /mnt/work
findmnt /mnt/work && df -h /mnt/work
```

The fstab line copies `/mnt/safe` and `/mnt/data` exactly: mount by UUID,
`nofail` so a missing disk does not stop the boot, and a 10 second device
timeout. Because of `nofail`, a missing disk leaves `/mnt/work` as an empty
directory, which is why every Work service and the backup check
`mountpoint -q /mnt/work` first.

The default inode ratio is right here. Unlike `/mnt/safe` and `/mnt/data`,
this disk holds many small files: documents, attachments, database pages.

## Backups

`backup/restic-backup.sh` dumps the OpenProject database to
`/mnt/work/db/openproject.sql.gz` and adds `/mnt/work` to the restic sources
when it is mounted. Copy 2 (jjserver) and copy 3 (B2) then carry it with
everything else.

Before any client record goes into a Work service:

1. Run the backup once by hand.
2. Confirm the dump exists and is not empty.
3. Restore it into a scratch container and log in. A dump that has never been
   restored is not yet a backup.
