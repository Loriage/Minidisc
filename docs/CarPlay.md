# CarPlay

Minidisc exposes four audio tabs:

- **Home**: Smart Shuffle and recently added albums, including local files.
- **Library**: albums, artists, songs and favorite tracks.
- **Playlists**: server playlists, or playlists with playable downloads when offline.
- **Queue**: the current track and upcoming tracks from the shared player.

Selecting a song starts its displayed collection at the selected position. Album and
playlist queues retain all tracks even when the CarPlay list needs several pages.
The songs browser fetches additional server pages on demand. Now Playing uses
Apple's system template and Minidisc's existing metadata and remote commands, with
shuffle, repeat, album navigation and an Up Next button.

## Signing and testing

The app declares `com.apple.developer.carplay-audio`. Device and distribution
profiles must also authorize this entitlement. Request the audio capability from
[Apple](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements),
enable it for the app identifier once approved, and regenerate/download the profiles.

For visual verification, build and install the app in iOS Simulator with ad hoc
signing (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`) so the CarPlay entitlement
is embedded. In Simulator choose **I/O > External Displays > CarPlay**, following
[Apple's simulator guide](https://developer.apple.com/documentation/carplay/using-the-carplay-simulator).

Device Hub also provides a CarPlay Simulator window backed by a connected iPhone.
For this path, install a development-signed device build and check that both its
code signature and embedded provisioning profile contain the audio entitlement.
After Apple approves the capability, an automatic-signing build with
`-allowProvisioningUpdates` can refresh the development profile.

## Reference

The scene/template approach was informed by
[Cassette v1.13.2](https://github.com/CassetteLab/cassette/releases/tag/v1.13.2)
and its [CarPlay module](https://github.com/CassetteLab/cassette/tree/v1.13.2/Cassette/CarPlay).
Minidisc integrates this approach with its shared runtime, source isolation,
local music and offline catalogue.
