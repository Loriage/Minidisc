#!/usr/bin/env python3
"""Disposable loopback-only Subsonic fixture for Minidisc UX verification."""
import base64
import io
import json
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

STATE = {"removed": False, "fail_stream": False, "slow_stream": False}
LOCK = threading.Lock()
SONGS = [
    {"id": "ux-song-1", "title": "Matin tranquille", "artist": "Atelier Minidisc", "artistId": "ux-artist", "album": "Horizons de test", "albumId": "ux-album", "duration": 30, "track": 1, "size": 960044, "suffix": "wav", "contentType": "audio/wav", "isDir": False, "coverArt": "ux-cover"},
    {"id": "ux-song-2", "title": "Une très longue promenade au bord de la mer pour vérifier la lisibilité", "artist": "Atelier Minidisc", "artistId": "ux-artist", "album": "Horizons de test", "albumId": "ux-album", "duration": 30, "track": 2, "size": 960044, "suffix": "wav", "contentType": "audio/wav", "isDir": False, "coverArt": "ux-cover"},
]
ALBUM = {"id": "ux-album", "name": "Horizons de test", "artist": "Atelier Minidisc", "artistId": "ux-artist", "songCount": 2, "duration": 60, "created": "2026-09-01T12:00:00Z", "coverArt": "ux-cover", "genre": "Ambient", "year": 2026}
PLAYLIST = {"id": "ux-playlist", "name": "Escapade temporaire", "comment": "Données locales de vérification", "owner": "test", "public": False, "songCount": 2, "duration": 60, "created": "2026-09-01T12:00:00Z", "changed": "2026-09-01T12:00:00Z", "coverArt": "ux-cover"}
ARTIST = {"id": "ux-artist", "name": "Atelier Minidisc", "albumCount": 1, "coverArt": "ux-cover"}
buffer = io.BytesIO()
with wave.open(buffer, "wb") as wav:
    wav.setnchannels(1)
    wav.setsampwidth(2)
    wav.setframerate(16000)
    wav.writeframes(bytes(30 * 16000 * 2))
AUDIO = buffer.getvalue()
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a2ioAAAAASUVORK5CYII=")

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

    def send_audio(self, slow=False):
        start, end, status = 0, len(AUDIO) - 1, 200
        header = self.headers.get("Range")
        if header:
            try:
                spec = header.removeprefix("bytes=").split(",")[0]
                first, last = spec.split("-", 1)
                if first:
                    start = int(first)
                    end = min(int(last) if last else end, end)
                else:
                    start = max(0, len(AUDIO) - int(last))
                if start > end or start >= len(AUDIO):
                    raise ValueError("Range outside fixture")
                status = 206
            except ValueError:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{len(AUDIO)}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
        body = AUDIO[start:end + 1]
        self.send_response(status)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(AUDIO)}")
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
        if urlparse(self.path).path == "/__state":
            data = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            with LOCK:
                STATE.update({k: bool(v) for k, v in data.items() if k in STATE})
            return self.send(json.dumps(STATE).encode())
        self.do_GET()

    def do_GET(self):
        parsed = urlparse(self.path)
        endpoint = parsed.path.split("/")[-1].removesuffix(".view")
        query = parse_qs(parsed.query)
        with LOCK:
            state = dict(STATE)
        if endpoint == "__state":
            return self.send(json.dumps(state).encode())
        if endpoint == "getCoverArt":
            return self.send(PNG, "image/png")
        if endpoint in ("stream", "download"):
            if state["removed"] or state["fail_stream"]:
                return self.send(b"missing fixture stream", "text/plain", 404)
            return self.send_audio(slow=state["slow_stream"])
        response = {"status": "ok", "version": "1.16.1", "type": "navidrome", "serverVersion": "0.58.0", "openSubsonic": True}
        if endpoint == "getUser":
            response["user"] = {"username": "test", "streamRole": True, "downloadRole": True, "playlistRole": True}
        elif endpoint == "getPlaylists":
            response["playlists"] = {"playlist": [] if state["removed"] else [PLAYLIST]}
        elif endpoint == "getPlaylist":
            if state["removed"]:
                response.update(status="failed", error={"code": 70, "message": "Playlist not found"})
            else:
                response["playlist"] = {**PLAYLIST, "entry": SONGS}
        elif endpoint == "getSong":
            if state["removed"]:
                response.update(status="failed", error={"code": 70, "message": "Song not found"})
            else:
                response["song"] = next((s for s in SONGS if s["id"] == query.get("id", [""])[0]), SONGS[0])
        elif endpoint == "getAlbum":
            response["album"] = {**ALBUM, "song": [] if state["removed"] else SONGS}
        elif endpoint == "getAlbumList2":
            response["albumList2"] = {"album": [] if int(query.get("offset", ["0"])[0]) > 0 or state["removed"] else [ALBUM]}
        elif endpoint == "getArtists":
            response["artists"] = {"ignoredArticles": "The El La", "index": [] if state["removed"] else [{"name": "A", "artist": [ARTIST]}]}
        elif endpoint == "getArtist":
            response["artist"] = {**ARTIST, "album": [] if state["removed"] else [ALBUM]}
        elif endpoint == "search3":
            response["searchResult3"] = {"artist": [ARTIST], "album": [ALBUM], "song": [] if int(query.get("songOffset", ["0"])[0]) > 0 or state["removed"] else SONGS}
        elif endpoint == "getGenres":
            response["genres"] = {"genre": [{"value": "Ambient", "songCount": 2, "albumCount": 1}]}
        elif endpoint in ("getStarred2", "getStarred"):
            response["starred2" if endpoint.endswith("2") else "starred"] = {"song": [], "album": [], "artist": []}
        elif endpoint == "getScanStatus":
            response["scanStatus"] = {"scanning": False, "count": 2, "lastScan": "2026-09-01T12:00:00Z"}
        elif endpoint == "getMusicFolders":
            response["musicFolders"] = {"musicFolder": [{"id": 1, "name": "Fixture"}]}
        elif endpoint == "getOpenSubsonicExtensions":
            response["openSubsonicExtensions"] = []
        elif endpoint in ("getRandomSongs", "getSongsByGenre", "getSimilarSongs2", "getTopSongs"):
            key = {"getRandomSongs": "randomSongs", "getSongsByGenre": "songsByGenre", "getSimilarSongs2": "similarSongs2", "getTopSongs": "topSongs"}[endpoint]
            response[key] = {"song": [] if state["removed"] else SONGS}
        elif endpoint == "getArtistInfo2":
            response["artistInfo2"] = {"biography": "Artiste local de vérification", "similarArtist": []}
        elif endpoint == "getAlbumInfo2":
            response["albumInfo"] = {}
        return self.send(json.dumps({"subsonic-response": response}).encode())

if __name__ == "__main__":
    print("Minidisc UX fixture on http://127.0.0.1:18992", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 18992), Handler).serve_forever()
