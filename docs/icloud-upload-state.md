# How to tell whether iCloud Photos has actually uploaded your library

Every photo migration ends with the same decision: is it safe to erase the drive holding the
only other copy? Answering that turns out to be harder than it should be, because a Photos
library contains two records of what has been uploaded and they do not agree.

On the library measured here, 345.9 GB of original photos and videos were sitting in
CloudPhotos' upload queue while the library index flagged them as already available in iCloud.

Everything below is reproducible on your own library. All queries are read only.

## Check your own library first

Takes about a second, writes nothing. Terminal needs Full Disk Access, under
System Settings, Privacy & Security.

```sh
LIB="$HOME/Pictures/Photos Library.photoslibrary"
sqlite3 "file:$LIB/resources/cpl/cloudsync.noindex/storage/store.cloudphotodb?mode=ro" "
ATTACH \"file:$LIB/database/Photos.sqlite?mode=ro\" AS p;
WITH uniq AS (SELECT ZFINGERPRINT f, MAX(ZREMOTEAVAILABILITY) avail FROM p.ZINTERNALRESOURCE
              WHERE ZFINGERPRINT IS NOT NULL GROUP BY 1 HAVING count(*)=1),
     q AS (SELECT DISTINCT fingerPrint f, fileSize FROM outgoingResources)
SELECT printf('%d files (%.1f GB) are queued for upload but flagged as already in iCloud',
              count(*), COALESCE(SUM(q.fileSize),0)/1e9)
FROM q JOIN uniq u ON u.f=q.f WHERE u.avail=1;"
```

A fully synced library reports `0 files`. `unable to open database file` means that library is
not the one signed into iCloud Photos; the `cloudsync` directory only exists on the system
library.

One note on the connection string. `mode=ro` matters, because these are live databases that
CloudPhotos is writing to. Do not substitute `immutable=1`. That tells SQLite to ignore the
write ahead log and will report a perfectly healthy library as malformed.

## Where the two numbers come from

A `.photoslibrary` bundle contains, among much else:

| Path | What it is |
|---|---|
| `database/Photos.sqlite` | The library index. Assets, albums, faces, edits: the model behind the Photos app. |
| `resources/cpl/cloudsync.noindex/storage/store.cloudphotodb` | CloudPhotos' own state. CPL is the sync layer, and this is its work list, kept independently of the index. |

Two tables matter.

`ZINTERNALRESOURCE` in the index has one row per *file*. An asset owns several, since a RAW+JPEG
pair, an edited rendition and the original are separate resources. It carries a
`ZREMOTEAVAILABILITY` column.

`outgoingResources` in the sync store is the upload queue: one row per file CloudPhotos still has
to send, with `fileSize`, `resourceType` and a `fingerPrint`. That fingerprint also appears as
`ZINTERNALRESOURCE.ZFINGERPRINT`, which is what makes the two databases comparable.

## The measurement

One 2.06 TB library, mid migration, iCloud Photos enabled and actively uploading.

What the index claims:

```
ZREMOTEAVAILABILITY = 1    247,964 files    1,869.8 GB
ZREMOTEAVAILABILITY = 0     49,902 files      306.0 GB
```

Read at face value, 306 GB left to go.

What the sync engine's own queue says:

```
32,441 files    680.9 GB    (20,742 distinct assets)
```

The same library, at the same moment, disagreeing with itself by 375 GB about how much work
remains.

Joining the two on fingerprint labels each queued file with what the index claims about it:

```
still queued for upload, by ZREMOTEAVAILABILITY:

  flagged 1, "available remotely"    22,037 files    420.6 GB    21,229 assets
  flagged 0                          12,481 files    324.4 GB
```

## Ruling out the boring explanations

**"Those are duplicates. An identical file was already uploaded under a different asset."**
Plausible, since the join is on content fingerprint. Excluded by restricting to fingerprints that
appear exactly once in the entire index, so no already uploaded twin can exist:

```
19,576 files    345.9 GB    unique fingerprint, queued for upload, flagged as in iCloud
```

**"Those are thumbnails and derivatives, not your originals."** The queue is 99.9% originals:

```
resourceType 17, RAW                 11,706 files    299.4 GB
resourceType 1, photo                20,456 files    232.1 GB
resourceType 1 fileKind 1, video        250 files    149.2 GB
everything else                          25 files      0.0 GB
```

**"The flag means something other than the bytes being in iCloud."** Almost certainly correct,
and it is the entire point. `ZREMOTEAVAILABILITY` appears to be set once a cloud *record* exists
for the resource, which happens when Photos registers the item with CloudKit, before the payload
has transferred. The name promises more than the column delivers.

## What this does and does not prove

Proven: `ZREMOTEAVAILABILITY = 1` is set on files CloudPhotos has not uploaded. 345.9 GB of them
here, after excluding duplicates and derivatives. Any code treating that column as "this file is
safely in iCloud" is wrong, and wrong in the direction that loses data.

Not proven: that the Photos app's progress indicator reads this column. The behaviour is
consistent with it, since Photos reported a nearly complete upload throughout, but the UI's data
path has not been traced and this document does not claim otherwise.

Also not proven: that the gap ever resolves incorrectly. Files do finish uploading and the flag is
presumably right eventually. The problem is that it is right *in advance*, which makes it useless
for the only question that matters.

A note on a dead end, since it may save someone the trip. `idMapping` in the sync store looks like
a confirmation log, and on this library 21,224 of 21,226 queued assets had no row in it. That
looked like a second independent signal until the timestamps were checked: every row fell inside a
single recent week, because the table had been rebuilt during a library repair. Absence of a row
proves nothing. It is not evidence and it is not used above.

## The number that is trustworthy

`outgoingResources` is CloudPhotos' own work list. When it reaches zero the upload is done, and it
is the only figure here that means what it appears to mean:

```sh
sqlite3 "file:$HOME/Pictures/Photos Library.photoslibrary/resources/cpl/cloudsync.noindex/storage/store.cloudphotodb?mode=ro" \
  "SELECT printf('%.1f GB still to upload, %d files', COALESCE(SUM(fileSize),0)/1e9, count(*)) FROM outgoingResources;"
```

[Halo](https://github.com/YordiLorenzo/halo) is a menu bar app built on that query and the ones
above, if you would rather watch it than run SQL. Free, GPL-3.0, read only.

## Caveats

Measured on macOS 26.2 against a single library. These are private Apple schemas that can change
without notice, and one library is one data point. If the numbers differ on yours,
[that is worth an issue](https://github.com/YordiLorenzo/halo/issues).
