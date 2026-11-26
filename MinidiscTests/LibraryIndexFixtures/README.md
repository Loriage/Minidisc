# Library index fixtures

These independent SQLite stores contain synthetic data written by historical
models. Do not regenerate them from current models to make a test pass.

- V1 exercises the complete lightweight migration chain, starting with tracks,
  albums, artists and synchronization markers (04e1ac90).
- V3 checks that populated playlists (including duplicate track occurrences) and
  cached recommendations survive migration to the current schema (ae24b083).
- V4 verifies reopening an installed database containing the retained
  TrackSearchIndexState marker from the withdrawn artist-credits feature.

LibraryIndexMigrationTests copies each store, checks its data through the
production factory, then reopens it to verify the next launch. The intermediate
V2 fixture is omitted: V1 exercises its migration stages, and V3 checks preservation
of the playlist data it introduced. The stores have no WAL sidecars.

Keep production historical schemas immutable. Add a fixture when a new migration
introduces a distinct data-preservation risk.
