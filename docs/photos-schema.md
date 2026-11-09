# Apple Photos library schema: a working reference

Notes for anyone reading a `.photoslibrary` bundle programmatically. Everything here was
verified against a real 2 TB library on macOS 26.2 during a Lightroom migration. These are
private Apple schemas with no public contract; treat every claim as "true on 26.2" and
re-check on other versions.

## Read these three rules first

**1. `mode=ro`, never `immutable=1`.**

```sh
sqlite3 "file:$LIB/database/Photos.sqlite?mode=ro"      # correct
sqlite3 "file:$LIB/database/Photos.sqlite?immutable=1"  # WRONG
```

`immutable=1` tells SQLite the file cannot change, so it skips the write-ahead log. On a live
library that WAL holds committed data, and ignoring it makes a perfectly healthy database
report as **malformed**. This has sent more than one person chasing a corruption that was
never there.

**2. Keep reads short and non-overlapping.** These databases are being written by
`cloudphotod` and `photolibraryd` continuously. A held read lock prevents SQLite from
checkpointing the WAL; leave several readers open and the WAL grows without bound, at which
point every subsequent read scans it first and you have measurably slowed down the sync you
were trying to observe. Open, query, close. Guard any polling loop against re-entrancy.

**3. `PRAGMA quick_check` costs minutes, not milliseconds.** Roughly 3 minutes on a 2.2 GB
`Photos.sqlite`, holding a read lock the whole time. Never put it on a timer.

## The two databases

A library bundle contains two independent stores that routinely disagree:

| Path | Owner | What it holds |
|---|---|---|
| `database/Photos.sqlite` | `photolibraryd` | The library index. Assets, albums, faces, moments, memories. This is what the Photos app displays. Core Data schema, hence the `Z` prefixes. |
| `resources/cpl/cloudsync.noindex/storage/store.cloudphotodb` | `cloudphotod` | CloudPhotos (CPL) sync engine state. Work queues, id mappings, quarantine. Plain SQLite, no `Z` prefix. |

There is also `database/search/psi.sqlite` (search index) and various `.noindex` caches, not
covered here.

Timestamps in both are **Apple epoch**: seconds since 2001-01-01. Add `978307200` for Unix.

```sql
datetime(ZDATECREATED + 978307200, 'unixepoch')
```

---

## Photos.sqlite

Row counts below are from one 77k-asset library, for scale only.

| Table | Rows | Notes |
|---|---|---|
| `ZASSET` | 77,782 | One row per photo or video |
| `ZINTERNALRESOURCE` | 409,382 | One row per **file**. ~5 per asset |
| `ZADDITIONALASSETATTRIBUTES` | 77,782 | 1:1 with ZASSET; holds `ZORIGINALFILENAME` |
| `ZGENERICALBUM` | 3,793 | Albums, folders, and many system collections |
| `ZPERSON` / `ZDETECTEDFACE` | 19,539 / 62,210 | Face recognition |
| `ZMOMENT` / `ZMEMORY` | 7,387 / 1,463 | Auto-generated groupings |

### ZASSET

The columns that actually matter:

| Column | Meaning |
|---|---|
| `Z_PK` | Primary key. `ZINTERNALRESOURCE.ZASSET` points here |
| `ZUUID` | Stable UUID. This is what CPL calls a "local identifier" |
| `ZDIRECTORY` / `ZFILENAME` | Path under `originals/`, e.g. `F` + `F66B9BF8-….jpeg` |
| `ZTRASHEDSTATE` | 0 = live, 1 = in Recently Deleted. **Filter on this or your counts are wrong** |
| `ZHIDDEN`, `ZVISIBILITYSTATE` | Hidden album, and non-user-visible assets |
| `ZKIND` | 0 = photo, 1 = video |
| `ZDATECREATED` | Capture date, Apple epoch |
| `ZCLOUDLOCALSTATE` | Cloud participation state |

`ZADDITIONALASSETATTRIBUTES.ZORIGINALFILENAME` holds the filename the file had when
imported (`IMG_1234.CR2`). `ZASSET.ZFILENAME` is the library's internal UUID-based name. They
are different things and the distinction matters constantly.

### ZINTERNALRESOURCE — the important one

One row per file on disk. A single photo owns several: the original, a RAW sibling, an
adjusted render, and multiple thumbnail sizes.

| Column | Meaning |
|---|---|
| `ZASSET` | FK to `ZASSET.Z_PK` |
| `ZRESOURCETYPE` + `ZDATASTORESUBTYPE` | What kind of file (see below) |
| `ZDATALENGTH` | Size in bytes |
| `ZFINGERPRINT` | Content hash. **The only reliable join to the CPL store** |
| `ZLOCALAVAILABILITY` | 1 = bytes on disk, 0 = not, **-32768 = placeholder, file was never here** |
| `ZREMOTEAVAILABILITY` | See the warning below |
| `ZUPLOADATTEMPTS` | Attempts, not failures. `> 0` does not mean broken |

Observed type/subtype pairs, largest first:

```
type=0 subtype=1    originals            659 GB
type=4 subtype=17   RAW                  496 GB
type=0 subtype=3    adjusted renders      53 GB
type=0 subtype=4    large derivatives     48 GB
type=0 subtype=2                          38 GB
type=0 subtype=5    small thumbnails       5 GB
type=14             analysis artefacts     1 GB
```

To sum "the library" without double-counting derivatives, the working predicate is:

```sql
WHERE ZRESOURCETYPE IN (1,4) OR (ZRESOURCETYPE = 0 AND ZDATASTORESUBTYPE = 1)
```

Type 0 with subtype > 1 is locally generated preview data that never occupies iCloud.
Including it inflates any "uploaded bytes" figure.

### ZREMOTEAVAILABILITY does not mean what it says

**This is the single biggest trap in the schema.**

`ZREMOTEAVAILABILITY = 1` is set when Photos *creates a cloud record* for the resource, not
when iCloud confirms it has received the bytes. The two events can be days apart.

Measured on one library mid-upload: **19,576 files, 345.9 GB** were flagged `= 1` while
sitting in the sync engine's outgoing queue, after excluding duplicate fingerprints and
derivatives. `Photos.sqlite` claimed 306 GB remained; the sync engine's own queue said 681 GB.

If you need to know whether a file is safely in iCloud, **do not read this column.** Read
`outgoingResources` (below). Anything built on `ZREMOTEAVAILABILITY` will tell users their
photos are backed up before they are, which is the direction that loses data.

Also note it lives on `ZINTERNALRESOURCE`, not `ZASSET`. There is no such column on `ZASSET`.

### ZGENERICALBUM

| `ZKIND` | Meaning |
|---|---|
| 2 | User album |
| 4000 | User folder |
| others | System collections: Recently Deleted, imports, syndication, many more |

Filter `ZKIND = 2 AND ZTRASHEDSTATE = 0` for "albums the user made". Counting the whole table
gives thousands and is always wrong.

Album membership lives in a `Z_nnASSETS` join table whose number varies by schema version.
Find it dynamically:

```sql
SELECT name FROM sqlite_master WHERE name LIKE 'Z_%ASSETS';
```

**There is no library-scope column on `ZGENERICALBUM`.** This matters: iCloud Shared Photo
Library shares *assets* but not album structure, and the schema shows why — an album has no
field that could say which library it belongs to. Moving albums into a shared library is not
"unimplemented", it is structurally impossible.

---

## store.cloudphotodb (CPL sync engine)

| Table | Purpose |
|---|---|
| `outgoingResources` | **The upload queue.** Empty = upload complete |
| `pushRepository` | Metadata change queue (albums, edits, relations) |
| `idMapping` | Local UUID ↔ cloud identifier, with confirmation timestamps |
| `quarantinedRecords` | Records the engine gave up on, with a reason string |
| `ignoredRecords` | Records deliberately skipped |
| `pullQueue` / `downloadQueue` | Inbound work |
| `scopes` | One row per library scope (personal, shared) |

### outgoingResources — the authoritative "what's left"

```sql
CREATE TABLE outgoingResources (
  scopeIndex INTEGER, itemIdentifier TEXT, resourceType INTEGER,
  fingerPrint TEXT, fileUTI TEXT, fileKind INTEGER,
  fileSize INTEGER, uploadIdentifier TEXT);
```

This is CloudPhotos' own work list. A row exists while a file still needs sending, and is
removed when the upload completes. **When this table is empty, the upload is genuinely
finished.** It is the only figure in either database that means what it appears to mean.

```sql
-- what is actually left
SELECT count(*), count(DISTINCT itemIdentifier), SUM(fileSize)
FROM outgoingResources;
```

- `resourceType`: 17 = RAW, 1 = original photo/video, 2 and 10 = derivatives (rare)
- `fileKind`: 1 = video
- `itemIdentifier` is a CloudKit record name, **not** a UUID
- `fingerPrint` joins to `ZINTERNALRESOURCE.ZFINGERPRINT` — the only cross-database join

Cross-database queries need `ATTACH`, and the path must have apostrophes doubled:

```sql
ATTACH DATABASE 'file:/path/to/Photos.sqlite?mode=ro' AS p;
```

A library at `/Volumes/Someone's Drive/…` will silently fail to attach otherwise.

### idMapping — confirmations, with a large caveat

```sql
CREATE TABLE idMapping (
  stableScopeIndex INTEGER, cloudIdentifier TEXT, localIdentifier TEXT,
  mappingState INTEGER, addTimestamp TIMESTAMP, addDirection INTEGER,
  deleteTimestamp TIMESTAMP, deleteDirection INTEGER);
```

A row appears when an item is established in iCloud. `localIdentifier` is `ZASSET.ZUUID` for
asset rows; many rows are albums, memories and other records that match no asset.

- **`addDirection = 1` is device→cloud.** Direction 2 is inbound. Omitting this filter counts
  downloads as uploads, so a Mac doing an initial sync reports large outbound figures while
  sending nothing.
- `mappingState` 0 and 1 both indicate an established mapping; it does not distinguish
  pending from confirmed.

**Do not use this as an upload-throughput measure.** Two reasons, both learned by shipping it
and being wrong:

1. A **library repair rebuilds the table**, remapping everything already in iCloud in one
   burst with current timestamps. That reads as a library's worth of bytes in a single hour.
   Detectable as a large cluster within seconds of `MIN(addTimestamp)`.
2. Mappings are **per asset**, uploads are **per resource**. Once a library is mostly
   registered, assets stop getting new mappings while their payloads are still transferring.
   Measured divergence against real queue drain: 20% on a one-day window, and it under-reports
   badly late in a migration.

For throughput, sample `SUM(fileSize)` from `outgoingResources` over time instead. That is
ground truth: a file leaves the queue when it is sent.

### pushRepository — metadata queue

```
CPLAssetChange              asset metadata
CPLMasterChange             original file metadata
CPLContainerRelationChange  which photo belongs to which album
CPLAlbumChange              the albums themselves
CPLMemoryChange, CPLFaceCropChange, CPLSuggestionChange
```

`dequeueOrder` reveals whether the queue is being worked: if `count`, `MIN` and `MAX` are all
unchanged across a sampling interval, nothing is being processed.

Album relations appear to be **deferred until the assets they reference exist in the cloud**.
A `CPLContainerRelationChange` count that sits frozen for days while asset queues drain is
expected, not stuck — it drains after the byte queue empties. This is why albums appear on
other devices before their contents do.

### quarantinedRecords — why something never uploaded

```sql
CREATE TABLE quarantinedRecords (
  scopeIndex INTEGER, localIdentifier TEXT, quarantineDate TIMESTAMP,
  class TEXT, related INTEGER, reason TEXT);
```

`reason` is a human-readable string. Real example, 260 photos:

```
260  CPLMasterChange  sparse resources with no record on server
260  CPLAssetChange   Master has been quarantined
```

Each affected photo produces **two** rows, so halve the count before reporting it to a user.

**`localIdentifier` changes format by class.** `CPLAssetChange` rows hold a `ZASSET.ZUUID`
and join directly. `CPLMasterChange` rows hold a CloudKit record name and do not. Joining
without filtering on class returns zero matches and looks like the data is unrelated.

"Sparse resources with no record on server" means the library has database rows and
thumbnails for an asset whose original file exists neither on disk
(`ZLOCALAVAILABILITY = -32768`) nor in iCloud. Typically a referenced-but-never-copied import
whose source was later deleted. There is nothing to upload and never was.

---

## Recipes

```sql
-- Is the upload finished?
SELECT SUM(fileSize), count(*) FROM outgoingResources;   -- 0 rows = done

-- Files queued but flagged as already in iCloud (the ZREMOTEAVAILABILITY lie),
-- excluding duplicate fingerprints so no already-uploaded twin explains it
ATTACH DATABASE 'file:/path/Photos.sqlite?mode=ro' AS p;
WITH uniq AS (SELECT ZFINGERPRINT f, MAX(ZREMOTEAVAILABILITY) avail
              FROM p.ZINTERNALRESOURCE WHERE ZFINGERPRINT IS NOT NULL
              GROUP BY 1 HAVING count(*) = 1),
     q AS (SELECT DISTINCT fingerPrint f, fileSize FROM outgoingResources)
SELECT count(*), SUM(q.fileSize) FROM q JOIN uniq u ON u.f = q.f WHERE u.avail = 1;

-- User albums only
SELECT count(*) FROM ZGENERICALBUM WHERE ZKIND = 2 AND ZTRASHEDSTATE = 0;

-- Assets whose original bytes are missing locally
SELECT count(*) FROM ZINTERNALRESOURCE WHERE ZLOCALAVAILABILITY = -32768;

-- Verify a folder of files exists in the library, by name AND exact size
SELECT count(*) FROM ZADDITIONALASSETATTRIBUTES aa
JOIN ZASSET a ON a.Z_PK = aa.ZASSET
JOIN ZINTERNALRESOURCE r ON r.ZASSET = a.Z_PK
WHERE aa.ZORIGINALFILENAME = ?1 AND r.ZDATALENGTH = ?2 AND a.ZTRASHEDSTATE = 0;
```

## Things that will waste your time

- `ZIMPORTSESSIONID` is empty on every asset in a migrated library. It records which app
  imported, not where from. There is no "original path" column anywhere.
- Photos' own UI counter is not read from `outgoingResources`. It was observed decreasing
  while every counter in both databases was byte-identical and both daemons sat at 0% CPU.
  Do not try to reconcile the two numbers; they measure different things.
- `launchctl kickstart -k gui/<uid>/com.apple.cloudphotod` **fails under SIP** — "Operation
  not permitted" — and still exits 0. It is not a usable restart mechanism.
- The reliable way to restart a stalled sync is Photos' own Pause → Resume, which requeues
  the session as user-initiated rather than discretionary background work.
- Sync throughput collapses when the machine is busy. Observed: 0.0% CPU for `cloudphotod`
  at load average 52 on 10 cores, versus 20 GB/hour on an idle machine. It is descheduled,
  not rate-limited.
