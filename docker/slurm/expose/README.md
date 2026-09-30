# caper-expose — control which host paths caper-server can see

Add or revoke host directories visible inside the `caper-server` container **live**,
without restarting it. Paths appear at the same location as on the host and compute
nodes, `ro` or `rw`.

## Quick reference

From a Claude Code `!` prompt, use `sudo bash -c '…'` (plain `sudo` needs a
password and `!` has no tty).

```bash
sudo bash -c '/usr/local/sbin/caper-expose add /mnt/altnas/work/foo ro'   # expose (ro|rw)
sudo bash -c '/usr/local/sbin/caper-expose rm  /mnt/altnas/work/foo'      # revoke
sudo bash -c '/usr/local/sbin/caper-expose list'                          # config + live state
sudo bash -c '/usr/local/sbin/caper-expose reload'                        # after an NFS remount
```

`add`/`rm` also update `/etc/caper-expose.conf`, so changes survive reboot.

Check from inside: `docker exec caper-server ls /mnt/altnas/work/foo`.

## How it works

```
host                                         container (caper-server)
/mnt/altnas/work/ultima/FASTQ
   │ mount --bind -o ro,nosuid,nodev
   ▼
/srv/caper-view/mnt/altnas/work/ultima/FASTQ ──rslave──▶ /mnt/altnas/work/ultima/FASTQ
/srv/caper-view/gpfs0/...                    ──rslave──▶ /gpfs0/...
/srv/caper-view/gpfs0-old/...                ──rslave──▶ /gpfs0-old/...
```

- `docker-compose.yml` binds only three staging dirs:
  `/srv/caper-view/{gpfs0,gpfs0-old,mnt}` → `/{gpfs0,gpfs0-old,mnt}`, with
  `bind: {propagation: rslave}`.
- **rslave** = the container's copy of the mount is a *slave* of the host's: any mount
  or unmount the host does **under** the source path propagates into the container
  (within ~1 s). Nothing propagates back out. The `r` makes it recursive (applies to
  submounts). It requires the host mount to be `shared` (it is: `/` and
  `/srv/caper-view` are shared).
- `caper-expose` bind-mounts each configured host path at the same relative path
  under `/srv/caper-view`. The `ro` flag lives on the host mount itself and travels
  with it — it doesn't depend on Docker's `read_only`.
- `/srv/caper-view` is self-bound as its own shared mount, so staging mounts form a
  separate peer group and don't leak into other containers that bind `/`.

## Behaviors and gotchas

- **Non-recursive binds**: submounts under an exposed path (e.g. rclone fuse mounts
  like `/gpfs0/work/olga/dropbox`) are *not* visible. Expose them explicitly if needed.
- **Parents before children**: nested entries are fine (`ro /gpfs0/work` +
  `rw /gpfs0/work/caper`); `apply` sorts parents first. `rm` refuses a parent that
  still has exposed children — remove the children first.
- **A child under an `ro` parent must already exist** in the source (can't `mkdir`
  through a read-only bind).
- **Fail-closed**: staging dirs are root-owned 755. If a mount is missing, the
  container user gets `Permission denied` instead of silently writing to local disk.
- **New top-level dir** (anything outside `/gpfs0`, `/gpfs0-old`, `/mnt`) needs a new
  bind in `docker-compose.yml` + container recreate.
- **NFS remount**: rslave does *not* follow a remount of the NFS filesystem itself
  (the event happens above the bound path). Run `caper-expose reload` — paths vanish
  from the container for a moment.
- **Security**: the installed script (`/usr/local/sbin`) and config (`/etc`) are
  deliberately *copies* outside `/gpfs0/work/caper`, which the container can write.
  Never point the systemd unit at the repo copies.

## Files

| Repo file | Installed to | Role |
|---|---|---|
| `caper-expose` | `/usr/local/sbin/caper-expose` | the helper (root only) |
| `caper-expose.conf` | `/etc/caper-expose.conf` | `ro\|rw PATH` per line (initial copy only) |
| `caper-expose.service` | `/etc/systemd/system/` | runs `apply` at boot: after remote-fs, before docker |
| `install.sh` | — | installs the above, enables + starts the service |

Install / update after editing repo copies (does **not** overwrite an existing
`/etc/caper-expose.conf`; safe while caper-server runs):

```bash
sudo bash /gpfs0/work/caper/caper/docker/slurm/expose/install.sh
```

Env overrides for testing: `CAPER_EXPOSE_STAGE`, `CAPER_EXPOSE_CONF`.

## Timezone (same change set)

Container shells/SSH use cluster time (America/Chicago, matches host + all nodes);
Cromwell's JVM stays UTC. In `docker-compose.yml`:

- `TZ: America/Chicago` + `/etc/localtime:/etc/localtime:ro` (SSH sessions don't
  inherit container env, so the localtime bind is needed too).
- `JAVA_TOOL_OPTIONS: -Duser.timezone=UTC` — Cromwell writes JVM-local time into
  Postgres `timestamp without time zone` columns (`WORKFLOW_STORE_ENTRY.HEARTBEAT_TIMESTAMP`,
  `METADATA_ENTRY.METADATA_TIMESTAMP`, …) and existing rows are UTC. Switching the JVM
  to Chicago would make in-flight heartbeats look 5 h in the future, delaying workflow
  pickup after restart. Cromwell logs therefore stay UTC (with a
  `Picked up JAVA_TOOL_OPTIONS` line at startup).

The running container (pre-recreate) had `/etc/localtime` switched live with
`docker exec -u 0 caper-server ln -sfn /usr/share/zoneinfo/America/Chicago /etc/localtime`;
that survives `docker restart` but not a recreate — compose covers the recreate.

## Status / cutover (as of 2026-09-30)

- [x] caper-expose installed, `caper-expose.service` enabled, 6 paths mounted
- [x] Live add/rm verified in a test container (537 → 0 → 537 entries, no restart)
- [ ] **Recreate caper-server once running jobs finish** — switches it from the old
      per-path binds to `/srv/caper-view` and applies the TZ settings:
      ```bash
      cd /gpfs0/work/caper/caper/docker/slurm && docker compose up -d caper
      ```
      Fails fast if `/srv/caper-view` is missing. Previous compose:
      `docker-compose.yml.bak-20260930`.
