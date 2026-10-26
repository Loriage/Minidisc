# Library index migration fixtures

These SQLite stores contain synthetic data written before the historical models
were moved into immutable schema namespaces. They are independent of today's model
definitions and must not be regenerated from those definitions to make a test pass.

- V1: tracks, albums, artists and their synchronization markers (`04e1ac90`).
- V2: adds playlist summaries, details and synchronization markers (`e6ebfdc1`).
- V3: adds cached album recommendations (`ae24b083`).
- V4: adds `TrackSearchIndexState(serverId: UUID, version: Int)` with a unique
  server ID. This version was installed during the subsequently withdrawn artist
  credits work. Its database format remains supported even though the feature was
  removed.

Each store contains one synthetic track, album and artist. V2 and later also
contain a playlist with two occurrences of the track; V3 adds a recommendation;
V4 adds its legacy marker. The playlist detail JSON was normalized to the existing
`IndexedPlaylistPayload` format. No store schema or model metadata was rewritten.
The stores were checkpointed into standalone SQLite files, without WAL sidecars.

`LibraryIndexMigrationTests` copies each fixture, opens it using the production
factory, checks the retained content and opens it again to verify the next launch.

For future changes, leave historical model definitions untouched, add a new schema
and migration stage, and update the active aliases and factory. Retain every schema
that has reached a device, including test builds and withdrawn features. Add a
fixture for the new persisted version without replacing these older fixtures.
