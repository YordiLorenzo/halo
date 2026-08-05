# Contributing to Halo

Issues and pull requests are welcome.

## Before your first pull request

Halo asks contributors to agree to a [CLA](CLA.md). You keep the copyright in your work. The agreement grants a licence alongside it so the project can also be offered under terms other
than the GPL. Leave this comment on your first pull request:

```
I have read the CLA and agree to it.
```

That's the whole process. No forms, no signature service.

## Two things that will get a PR rejected

**Writing to a Photos library.** Halo's entire premise is that you can point it at an
irreplaceable library without thinking twice. Every database is opened read-only, and it
stays that way. The two existing actions that touch the system (`restartBackup`,
`restartService`) act on the Photos app and the sync daemon, never on library files.

**Expensive work on the poll path.** The monitor runs on a timer against databases that
CloudPhotos is actively writing. A held read lock stops SQLite checkpointing the write-ahead
log, and an unbounded WAL slows down the very sync you're trying to observe. `PRAGMA
quick_check` on a large library takes minutes and holds a lock the entire time, so it belongs
behind an explicit user action, which is where it lives now.

## Good first issues

**Schema breakage is the main maintenance burden.** These are private Apple databases and
they change without notice. If a query breaks on a new macOS release, that's a genuinely useful issue. Include:

- your macOS version (`sw_vers`)
- what Halo showed versus what Photos showed
- if you can, `PRAGMA table_info(<table>)` for the table involved

You can inspect your own library safely:

```sh
LIB=~/Pictures/Photos\ Library.photoslibrary
sqlite3 "file:$LIB/resources/cpl/cloudsync.noindex/storage/store.cloudphotodb?mode=ro" \
  "SELECT count(*), SUM(fileSize) FROM outgoingResources;"
```

Use `mode=ro`. Never `immutable=1`. It tells SQLite to ignore the WAL, which makes a
perfectly healthy live database report as malformed, and has sent more than one person
chasing a corruption that wasn't there.

## Building

```sh
./build.sh release        # produces build/Halo.app
open build/Halo.app
```

Swift Package plus a script; there's no Xcode project. After a rebuild the ad-hoc signature
changes, which invalidates any Full Disk Access grant, so use **Choose Library…** in the app
instead, since the security-scoped bookmark survives.

## Style

Match the surrounding code. Comments explain *why*, particularly where the reason is a
non-obvious fact about Apple's schema or SQLite's locking behaviour. Those are the comments
that stop the next person from "simplifying" a constraint back out of existence.
