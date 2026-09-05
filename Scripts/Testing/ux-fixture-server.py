#!/usr/bin/env python3
"""Disposable loopback-only Subsonic fixture for Minidisc UX verification."""
import base64
import io
import json
import re
import threading
import time
import unicodedata
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

STATE = {"removed": False, "fail_stream": False, "slow_stream": False, "search_catalog": False, "queue_catalog": False, "home_catalog": False, "browse_catalog": False}
# Mode changes represent completed server scans, so persistent app indexes can refresh.
LAST_SCAN = time.time()
LOCK = threading.RLock()
PLAYLIST_OVERRIDES = {}
DELETED_PLAYLISTS = set()
MUTATIONS = []
REQUESTS = []
SONGS = [
    {"id": "ux-song-1", "title": "Matin tranquille", "artist": "Atelier Minidisc", "artistId": "ux-artist", "album": "Horizons de test", "albumId": "ux-album", "duration": 30, "track": 1, "size": 960044, "suffix": "wav", "contentType": "audio/wav", "isDir": False, "coverArt": "ux-cover"},
    {"id": "ux-song-2", "title": "Une très longue promenade au bord de la mer pour vérifier la lisibilité", "artist": "Atelier Minidisc", "artistId": "ux-artist", "album": "Horizons de test", "albumId": "ux-album", "duration": 30, "track": 2, "size": 960044, "suffix": "wav", "contentType": "audio/wav", "isDir": False, "coverArt": "ux-cover"},
]
ALBUM = {"id": "ux-album", "name": "Horizons de test", "artist": "Atelier Minidisc", "artistId": "ux-artist", "songCount": 2, "duration": 60, "created": "2026-09-01T12:00:00Z", "coverArt": "ux-cover", "genre": "Ambient", "year": 2026}
PLAYLIST = {"id": "ux-playlist", "name": "Escapade temporaire", "comment": "Données locales de vérification", "owner": "test", "public": False, "songCount": 2, "duration": 60, "created": "2026-09-01T12:00:00Z", "changed": "2026-09-01T12:00:00Z", "coverArt": "ux-cover"}
ARTIST = {"id": "ux-artist", "name": "Atelier Minidisc", "albumCount": 1, "coverArt": "ux-cover"}

# Deliberately return the prefix song before the exact match. The app must rank
# "Aurore" above "Aurore au piano", independently of the server response order.
SEARCH_ARTIST = {"id": "ux-search-artist", "name": "Aurore Ensemble", "albumCount": 1, "coverArt": "ux-search-cover"}
SEARCH_ALBUM = {**ALBUM, "id": "ux-search-album", "name": "Aurore — Sessions", "artist": SEARCH_ARTIST["name"], "artistId": SEARCH_ARTIST["id"], "coverArt": "ux-search-cover", "created": "2026-09-04T12:00:00Z"}
SEARCH_SONGS = [
    {**SONGS[0], "id": "ux-search-song-prefix", "title": "Aurore au piano", "artist": SEARCH_ARTIST["name"], "artistId": SEARCH_ARTIST["id"], "album": SEARCH_ALBUM["name"], "albumId": SEARCH_ALBUM["id"], "coverArt": "ux-search-cover", "track": 1},
    {**SONGS[0], "id": "ux-search-song-exact", "title": "Aurore", "artist": SEARCH_ARTIST["name"], "artistId": SEARCH_ARTIST["id"], "album": SEARCH_ALBUM["name"], "albumId": SEARCH_ALBUM["id"], "coverArt": "ux-search-cover", "track": 2},
]
SEARCH_PLAYLIST = {**PLAYLIST, "id": "ux-search-playlist", "name": "Aurore du dimanche", "comment": "Une sélection locale pour la recherche", "coverArt": "ux-search-cover"}


HOME_ARTIST = {**ARTIST, "id": "ux-home-artist", "name": "Ensemble des rives", "coverArt": "ux-home-cover"}
HOME_ALBUM = {**ALBUM, "id": "ux-home-album", "name": "Rives", "artist": HOME_ARTIST["name"], "artistId": HOME_ARTIST["id"], "created": "2026-09-05T08:00:00Z", "coverArt": "ux-home-cover"}
HOME_SONGS = [
    {**SONGS[0], "id": "ux-home-song-river", "title": "Rivière", "artist": HOME_ARTIST["name"], "artistId": HOME_ARTIST["id"], "album": HOME_ALBUM["name"], "albumId": HOME_ALBUM["id"], "coverArt": "ux-home-cover"},
    {**SONGS[1], "id": "ux-home-song-reflections", "title": "Reflets", "artist": HOME_ARTIST["name"], "artistId": HOME_ARTIST["id"], "album": HOME_ALBUM["name"], "albumId": HOME_ALBUM["id"], "coverArt": "ux-home-cover"},
]


# More than twelve distinct familiar albums prove the separate rotation/rediscovery shelves.
HOME_FREQUENT_ALBUMS = [
    {**ALBUM, "id": f"ux-home-frequent-{index:02d}", "name": f"Écoute familière {index:02d}",
     "songCount": 1, "duration": 30, "created": "2026-08-01T12:00:00Z"}
    for index in range(1, 15)
]
HOME_FREQUENT_SONGS = [
    {**SONGS[0], "id": f"ux-home-frequent-song-{index:02d}", "title": f"Repère {index:02d}",
     "album": album["name"], "albumId": album["id"]}
    for index, album in enumerate(HOME_FREQUENT_ALBUMS, 1)
]


# Twenty-four distinct records make every alphabet jump visibly move both lists
# and grids. Accents fold to E; digits belong to #. Existing fixture IDs stay intact.
BROWSE_GROUPS = [
    ("a", "A capella", "Atlas", "Aube"),
    ("e", "Écho", "Éclat", "Élan"),
    ("z", "Zénith", "Zénith", "Zéphyr"),
    ("hash", "001 Orbites", "001 Satellites", "001 Pulsations"),
]
BROWSE_ARTISTS = []
BROWSE_ALBUMS = []
BROWSE_SONGS = []
for bucket, artist_name, album_name, song_title in BROWSE_GROUPS:
    for index in range(1, 7):
        suffix = f"{bucket}-{index:02d}"
        artist = {**ARTIST, "id": f"ux-browse-artist-{suffix}", "name": f"{artist_name} {index:02d}"}
        album = {**ALBUM, "id": f"ux-browse-album-{suffix}", "name": f"{album_name} {index:02d}",
                 "artist": artist["name"], "artistId": artist["id"], "songCount": 1, "duration": 30}
        song = {**SONGS[0], "id": f"ux-browse-song-{suffix}", "title": f"{song_title} {index:02d}",
                "artist": artist["name"], "artistId": artist["id"], "album": album["name"], "albumId": album["id"]}
        BROWSE_ARTISTS.append(artist)
        BROWSE_ALBUMS.append(album)
        BROWSE_SONGS.append(song)
BROWSE_PLAYLIST = {**PLAYLIST, "id": "ux-browse-playlist", "name": "Index alphabétique",
                   "songCount": len(BROWSE_SONGS), "duration": len(BROWSE_SONGS) * 30,
                   "changed": "2026-09-05T09:00:00Z"}
BROWSE_FAVORITE_ARTIST = {**ARTIST, "id": "ux-browse-favorite-artist", "name": "Iris Ensemble", "albumCount": 0}


def fixture_catalog(state):
    if state["removed"]:
        return {"songs": [], "albums": [], "artists": [], "playlists": []}
    expanded = state["search_catalog"] or state["queue_catalog"] or state["home_catalog"]
    catalog = {
        "songs": SONGS + (SEARCH_SONGS if expanded else []),
        "albums": [ALBUM] + ([SEARCH_ALBUM] if expanded else []),
        "artists": [ARTIST] + ([SEARCH_ARTIST] if expanded else []),
        "playlists": [PLAYLIST] + ([SEARCH_PLAYLIST] if expanded else []),
    }
    if state["home_catalog"]:
        catalog["songs"] += HOME_SONGS + HOME_FREQUENT_SONGS
        catalog["albums"] += [HOME_ALBUM] + HOME_FREQUENT_ALBUMS
        catalog["artists"] = [{**item, "albumCount": 15 if item["id"] == ARTIST["id"] else item["albumCount"]}
                              for item in catalog["artists"]] + [HOME_ARTIST]
    if state["browse_catalog"]:
        catalog["songs"] += BROWSE_SONGS
        catalog["albums"] += BROWSE_ALBUMS
        catalog["artists"] += BROWSE_ARTISTS + [BROWSE_FAVORITE_ARTIST]
        catalog["playlists"] += [BROWSE_PLAYLIST]
    if state["queue_catalog"]:
        # Four long tracks leave time to inspect an edit without an automatic track boundary.
        catalog["songs"] = [{**item, "duration": 120, "size": len(QUEUE_AUDIO)} for item in catalog["songs"]]
        catalog["albums"] = [{**item, "duration": 240} for item in catalog["albums"]]
        catalog["playlists"] = [{**item, "songCount": 4 if item["id"] == PLAYLIST["id"] else 2,
                                  "duration": 480 if item["id"] == PLAYLIST["id"] else 240}
                                 for item in catalog["playlists"]]
    with LOCK:
        overrides = {key: {**value, "_song_ids": list(value["_song_ids"])} for key, value in PLAYLIST_OVERRIDES.items()}
        deleted = set(DELETED_PLAYLISTS)
    by_id = {item["id"]: item for item in catalog["songs"]}
    playlists = {item["id"]: item for item in catalog["playlists"] if item["id"] not in deleted}
    for identifier, value in overrides.items():
        if identifier in deleted:
            continue
        songs = [by_id[song_id] for song_id in value["_song_ids"] if song_id in by_id]
        playlists[identifier] = {**{key: item for key, item in value.items() if key != "_song_ids"},
                                 "songCount": len(songs), "duration": sum(item["duration"] for item in songs)}
    catalog["playlists"] = list(playlists.values())
    return catalog


def playlist_detail(playlist, catalog, state):
    with LOCK:
        stored = PLAYLIST_OVERRIDES.get(playlist["id"])
        if stored is not None:
            song_ids = list(stored["_song_ids"])
        else:
            if playlist["id"] == BROWSE_PLAYLIST["id"]:
                templates = BROWSE_SONGS
            else:
                templates = SEARCH_SONGS if playlist["id"] == SEARCH_PLAYLIST["id"] else SONGS + (SEARCH_SONGS if state["queue_catalog"] else [])
            song_ids = [item["id"] for item in templates]
    songs = {item["id"]: item for item in catalog["songs"]}
    return {**playlist, "entry": [songs[identifier] for identifier in song_ids if identifier in songs]}


def mutate_playlist(endpoint, query, state):
    """Implement the actual Subsonic mutation parameters, only for synthetic IDs."""
    with LOCK:
        catalog = fixture_catalog(state)
        identifier = query.get("playlistId", query.get("id", [""]))[0]
        previous = next((item for item in catalog["playlists"] if item["id"] == identifier), None)
        if endpoint != "createPlaylist" and previous is None:
            return {"status": "failed", "error": {"code": 70, "message": "Playlist not found"}}
        if endpoint == "deletePlaylist":
            DELETED_PLAYLISTS.add(identifier)
            PLAYLIST_OVERRIDES.pop(identifier, None)
            MUTATIONS.append({"endpoint": endpoint, "playlistId": identifier})
            return {}
        if endpoint == "createPlaylist":
            if identifier and previous is None:
                return {"status": "failed", "error": {"code": 70, "message": "Playlist not found"}}
            if not identifier:
                identifier = f"ux-created-playlist-{1 + sum(item['endpoint'] == 'createPlaylist' for item in MUTATIONS)}"
            summary = dict(previous or {**PLAYLIST, "id": identifier, "name": query.get("name", ["Fixture playlist"])[0]})
            song_ids = list(query.get("songId", []))
        else:
            summary = dict(previous)
            existing = playlist_detail(previous, catalog, state)["entry"]
            removed = {int(index) for index in query.get("songIndexToRemove", [])}
            song_ids = [item["id"] for index, item in enumerate(existing) if index not in removed]
            song_ids += query.get("songIdToAdd", [])
        known = {item["id"] for item in catalog["songs"]}
        if any(identifier not in known for identifier in song_ids):
            return {"status": "failed", "error": {"code": 70, "message": "Song not found"}}
        for key in ("name", "comment"):
            if key in query:
                summary[key] = query[key][0]
        if "public" in query:
            summary["public"] = query["public"][0].lower() == "true"
        summary["changed"] = "2026-09-05T10:00:00Z"
        PLAYLIST_OVERRIDES[identifier] = {**summary, "_song_ids": song_ids}
        MUTATIONS.append({"endpoint": endpoint, "playlistId": identifier, "songIds": list(song_ids), "name": summary["name"]})
        if endpoint == "createPlaylist":
            current = fixture_catalog(state)
            playlist = next(item for item in current["playlists"] if item["id"] == identifier)
            return {"playlist": playlist_detail(playlist, current, state)}
        return {}


def normalized(text):
    folded = "".join(char for char in unicodedata.normalize("NFD", text.casefold()) if not unicodedata.combining(char))
    return " ".join(re.findall(r"[^\W_]+", folded))


def matches_query(text, *fields):
    tokens = normalized(text).split()
    haystack = normalized(" ".join(field or "" for field in fields))
    return all(token in haystack for token in tokens)


def paged(values, query, count_key="size", offset_key="offset", default_count=20):
    offset = max(0, int(query.get(offset_key, ["0"])[0]))
    count = max(0, int(query.get(count_key, [str(default_count)])[0]))
    return values[offset:offset + count]


def search_result(catalog, query):
    text = query.get("query", [""])[0]
    artists = [item for item in catalog["artists"] if matches_query(text, item["name"])]
    albums = [item for item in catalog["albums"] if matches_query(text, item["name"], item.get("artist"))]
    songs = [item for item in catalog["songs"] if matches_query(text, item["title"], item.get("artist"), item.get("album"))]
    return {
        "artist": paged(artists, query, "artistCount", "artistOffset"),
        "album": paged(albums, query, "albumCount", "albumOffset"),
        "song": paged(songs, query, "songCount", "songOffset"),
    }


def make_audio(seconds):
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes(bytes(seconds * 16000 * 2))
    return buffer.getvalue()


AUDIO = make_audio(30)
QUEUE_AUDIO = make_audio(120)
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAABQUlEQVR4nO3Wyw3CMBBFUTqiBUqhBAqhMYphyYIdSJGiKAT7jefzMrGl2Xp8TxZJTq/bJfWc6AWaOV/viQHf+sSAqT4rYK5PCVjW5wOs6pMBfuszATbrXQDv56MwtvWWgHK3RlKotwFI00WMcr0WoElHGNX6doBVeoGB1DcCPOpXBrC+BeBXPxvwejHAu34aL0BMvdSAAiLrRYY+APH1uKEDAKseNBwdwK1HDAOAXcwBmF/pYbAHlB/YADgDkE/PAAzAkQFVg/nOAZDcZ76wAkj/K9H7z9wuAHRD9aXcAYBoqNZ3A6AYkPqeAMEGsF4GCDPg9WJAgEFULwZMZ/ZTLwMsj+2kXgDYPMxNFwDKK1jpKABcFJ8OARo2xnRDAPPLPOYvgF6mAtCzVAB6kwpAD1IB6DUqAD1FBaB3qAD0CM18ABLz2xTXyjQXAAAAAElFTkSuQmCC")

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Queries carry authentication hashes, even for fake accounts. Keep only endpoint names.
        print(self.command, urlparse(self.path).path, flush=True)

    def send(self, body, content_type="application/json", status=200, slow=False):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("X-Minidisc-UX-Fixture", "1")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        try:
            if slow:
                for offset in range(0, len(body), 16000):
                    self.wfile.write(body[offset:offset + 16000])
                    self.wfile.flush()
                    time.sleep(0.3)
            else:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def send_audio(self, slow=False, audio=AUDIO):
        start, end, status = 0, len(audio) - 1, 200
        header = self.headers.get("Range")
        if header:
            try:
                spec = header.removeprefix("bytes=").split(",")[0]
                first, last = spec.split("-", 1)
                if first:
                    start = int(first)
                    end = min(int(last) if last else end, end)
                else:
                    start = max(0, len(audio) - int(last))
                if start > end or start >= len(audio):
                    raise ValueError("Range outside fixture")
                status = 206
            except ValueError:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{len(audio)}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
        body = audio[start:end + 1]
        self.send_response(status)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(audio)}")
        self.end_headers()
        try:
            if slow:
                for offset in range(0, len(body), 16000):
                    self.wfile.write(body[offset:offset + 16000])
                    self.wfile.flush()
                    time.sleep(0.3)
            else:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        global LAST_SCAN
        if urlparse(self.path).path == "/__state":
            data = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            with LOCK:
                catalog_keys = ("removed", "search_catalog", "queue_catalog", "home_catalog", "browse_catalog")
                if any(key in data and bool(data[key]) != STATE[key] for key in catalog_keys):
                    LAST_SCAN = max(time.time(), LAST_SCAN + 1)
                STATE.update({k: bool(v) for k, v in data.items() if k in STATE})
                if data.get("reset_playlists") is True:
                    PLAYLIST_OVERRIDES.clear()
                    DELETED_PLAYLISTS.clear()
                    MUTATIONS.clear()
                if data.get("reset_requests") is True:
                    REQUESTS.clear()
                response = dict(STATE)
                if "reset_playlists" in data:
                    response["reset_playlists"] = data["reset_playlists"] is True
                if "reset_requests" in data:
                    response["reset_requests"] = data["reset_requests"] is True
            return self.send(json.dumps(response).encode())
        self.do_GET()

    def do_GET(self):
        parsed = urlparse(self.path)
        endpoint = parsed.path.split("/")[-1].removesuffix(".view")
        query = parse_qs(parsed.query)
        with LOCK:
            state = dict(STATE)
        catalog = fixture_catalog(state)
        if endpoint == "__state":
            return self.send(json.dumps(state).encode())
        if endpoint == "__mutations":
            with LOCK:
                snapshot = list(MUTATIONS)
            return self.send(json.dumps(snapshot).encode())
        if endpoint == "__requests":
            with LOCK:
                snapshot = list(REQUESTS)
            return self.send(json.dumps(snapshot).encode())
        if endpoint in ("getSimilarSongs2", "getRandomSongs", "stream", "download"):
            # Only bounded synthetic evidence; never persist request URLs or authentication.
            identifier = query.get("id", [""])[0]
            with LOCK:
                REQUESTS.append({"endpoint": endpoint, "id": identifier if identifier.startswith("ux-") else None})
                del REQUESTS[:-500]
        if endpoint == "getCoverArt":
            return self.send(PNG, "image/png")
        if endpoint in ("stream", "download"):
            if state["removed"] or state["fail_stream"]:
                return self.send(b"missing fixture stream", "text/plain", 404)
            return self.send_audio(slow=state["slow_stream"], audio=QUEUE_AUDIO if state["queue_catalog"] else AUDIO)
        response = {"status": "ok", "version": "1.16.1", "type": "navidrome", "serverVersion": "0.58.0", "openSubsonic": True}
        if endpoint == "getUser":
            response["user"] = {"username": "test", "streamRole": True, "downloadRole": True, "playlistRole": True}
        elif endpoint == "getPlaylists":
            response["playlists"] = {"playlist": catalog["playlists"]}
        elif endpoint == "getPlaylist":
            playlist = next((item for item in catalog["playlists"] if item["id"] == query.get("id", [""])[0]), None)
            if playlist is None:
                response.update(status="failed", error={"code": 70, "message": "Playlist not found"})
            else:
                response["playlist"] = playlist_detail(playlist, catalog, state)
        elif endpoint in ("createPlaylist", "updatePlaylist", "deletePlaylist"):
            response.update(mutate_playlist(endpoint, query, state))
        elif endpoint == "getSong":
            song = next((item for item in catalog["songs"] if item["id"] == query.get("id", [""])[0]), None)
            if song is None:
                response.update(status="failed", error={"code": 70, "message": "Song not found"})
            else:
                response["song"] = song
        elif endpoint == "getAlbum":
            album = next((item for item in catalog["albums"] if item["id"] == query.get("id", [""])[0]), None)
            if album is None:
                response.update(status="failed", error={"code": 70, "message": "Album not found"})
            else:
                response["album"] = {**album, "song": [item for item in catalog["songs"] if item.get("albumId") == album["id"]]}
        elif endpoint == "getAlbumList2":
            albums = catalog["albums"]
            if state["home_catalog"]:
                kind = query.get("type", ["newest"])[0]
                if kind == "frequent":
                    albums = [item for item in albums if item["id"].startswith("ux-home-frequent-")]
                elif kind == "recent":
                    albums = [item for item in albums if item["id"] == SEARCH_ALBUM["id"]]
                elif kind == "newest":
                    albums = sorted((item for item in albums if item["id"] in {HOME_ALBUM["id"], SEARCH_ALBUM["id"]}), key=lambda item: item["created"], reverse=True)
            response["albumList2"] = {"album": paged(albums, query)}
        elif endpoint == "getArtists":
            indexes = {}
            for artist in catalog["artists"]:
                initial = normalized(artist["name"])[:1].upper()
                bucket = initial if initial in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" else "#"
                indexes.setdefault(bucket, []).append(artist)
            response["artists"] = {"ignoredArticles": "The El La", "index": [
                {"name": name, "artist": sorted(values, key=lambda item: normalized(item["name"]))}
                for name, values in sorted(indexes.items())
            ]}
        elif endpoint == "getArtist":
            artist = next((item for item in catalog["artists"] if item["id"] == query.get("id", [""])[0]), None)
            if artist is None:
                response.update(status="failed", error={"code": 70, "message": "Artist not found"})
            else:
                response["artist"] = {**artist, "album": [item for item in catalog["albums"] if item.get("artistId") == artist["id"]]}
        elif endpoint == "search3":
            response["searchResult3"] = search_result(catalog, query)
        elif endpoint == "getGenres":
            response["genres"] = {"genre": [{"value": "Ambient", "songCount": len(catalog["songs"]), "albumCount": len(catalog["albums"])}]}
        elif endpoint in ("getStarred2", "getStarred"):
            favorites = {"song": [], "album": [], "artist": []}
            if state["home_catalog"] and not state["removed"]:
                favorites = {
                    "song": [item for item in catalog["songs"] if item["id"] == "ux-search-song-exact"],
                    "album": [item for item in catalog["albums"] if item["id"] == ALBUM["id"]],
                    "artist": [item for item in catalog["artists"] if item["id"] == SEARCH_ARTIST["id"]],
                }
            if state["browse_catalog"] and not state["removed"]:
                # H and I exist only in album/artist favorites, never in the song section.
                favorites = {"song": BROWSE_SONGS, "album": [ALBUM], "artist": [BROWSE_FAVORITE_ARTIST]}
            response["starred2" if endpoint.endswith("2") else "starred"] = favorites
        elif endpoint == "getScanStatus":
            response["scanStatus"] = {"scanning": False, "count": len(catalog["songs"]), "lastScan": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(LAST_SCAN))}
        elif endpoint == "getMusicFolders":
            response["musicFolders"] = {"musicFolder": [{"id": 1, "name": "Fixture"}]}
        elif endpoint == "getOpenSubsonicExtensions":
            response["openSubsonicExtensions"] = []
        elif endpoint in ("getRandomSongs", "getSongsByGenre", "getSimilarSongs2", "getTopSongs"):
            key = {"getRandomSongs": "randomSongs", "getSongsByGenre": "songsByGenre", "getSimilarSongs2": "similarSongs2", "getTopSongs": "topSongs"}[endpoint]
            songs = catalog["songs"]
            if endpoint == "getSimilarSongs2":
                seed = query.get("id", [""])[0]
                songs = sorted(songs, key=lambda item: item.get("artistId") != seed)
            if endpoint == "getTopSongs":
                name = query.get("artist", [""])[0]
                songs = [item for item in songs if item["artist"] == name]
            response[key] = {"song": paged(songs, query, "size" if endpoint == "getRandomSongs" else "count")}
        elif endpoint == "getArtistInfo2":
            response["artistInfo2"] = {"biography": "Artiste local de vérification", "similarArtist": []}
        elif endpoint == "getAlbumInfo2":
            response["albumInfo"] = {}
        return self.send(json.dumps({"subsonic-response": response}).encode())

if __name__ == "__main__":
    print("Minidisc UX fixture on http://127.0.0.1:18992", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 18992), Handler).serve_forever()
