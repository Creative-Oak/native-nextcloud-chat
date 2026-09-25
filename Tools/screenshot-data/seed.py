#!/usr/bin/env python3
"""Fill a Nextcloud Talk server with the conversations in scenario.json.

Made for the throwaway server in compose.yaml (see README.md), where it can also backdate
every message, so screenshots show "Yesterday" and "09:14" rather than a transcript that was
all written a few seconds ago. Standard library only; nothing to install.

    python3 seed.py                     # seed http://localhost:8080 and backdate
    python3 seed.py --wipe              # first delete every conversation the users are in
    python3 seed.py --keep-call         # keep the scenario's live call going until Ctrl-C
    python3 seed.py --no-backdate       # any server; timestamps stay "just now"
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.cookiejar
import json
import math
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
import zlib
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote, urlencode

HERE = Path(__file__).resolve().parent
MEDIA = HERE / "media"
STATE = HERE / ".seed-state.json"
COOKIES = HERE / ".seed-cookies"
TALK = "/ocs/v2.php/apps/spreed/api"


class SeedError(Exception):
    pass


def warn(text: str) -> None:
    print(f"  ! {text}", file=sys.stderr)


# --- Timestamps ---------------------------------------------------------------------------

def parse_at(spec: str, previous: datetime | None, now: datetime) -> datetime:
    """`-40m`, `-2h`, `+5m`, `today 09:14`, `yesterday 17:30`, `-3d 12:05`, `tomorrow 09:00`,
    `+4d 09:00` — in local time."""
    spec = spec.strip()
    if m := re.fullmatch(r"-(\d+)([mh])", spec):
        amount = int(m[1])
        return now - (timedelta(minutes=amount) if m[2] == "m" else timedelta(hours=amount))
    if m := re.fullmatch(r"\+(\d+)m", spec):
        if previous is None:
            raise SeedError(f"'{spec}' needs an earlier message to count from")
        return previous + timedelta(minutes=int(m[1]))
    if m := re.fullmatch(r"(today|yesterday|tomorrow|([-+])(\d+)d)\s+(\d{1,2}):(\d{2})", spec):
        days = {"today": 0, "yesterday": -1, "tomorrow": 1}.get(m[1])
        if days is None:
            days = int(m[3]) * (1 if m[2] == "+" else -1)
        day = now.date() + timedelta(days=days)
        return datetime(day.year, day.month, day.day, int(m[4]), int(m[5])).astimezone()
    raise SeedError(f"can't read the time '{spec}'")


def parse_day(spec: str, today: date) -> date:
    """`-2d`, `+6d` or `today`, for out-of-office dates."""
    if spec == "today":
        return today
    if m := re.fullmatch(r"([-+])(\d+)d", spec.strip()):
        return today + timedelta(days=int(m[2]) * (1 if m[1] == "+" else -1))
    raise SeedError(f"can't read the day '{spec}'")


def plan_times(scenario: dict, now: datetime) -> None:
    """Gives every message a `_at`. Unmarked messages follow the previous one by a minute."""
    for conversation in scenario["conversations"]:
        previous = None
        for message in conversation["messages"]:
            if "at" in message:
                at = parse_at(message["at"], previous, now)
            elif previous is not None:
                at = previous + timedelta(minutes=1)
            else:
                raise SeedError(f"the first message in '{conversation['key']}' needs an 'at'")
            if previous is not None and at < previous:
                raise SeedError(f"'{conversation['key']}': '{message.get('at')}' is earlier than the message before it")
            if at > now:
                warn(f"'{conversation['key']}': a message lands in the future ({at:%H:%M}); "
                     "use relative times like '-10m' for today's messages")
            message["_at"] = at
            previous = at


def utc(at: datetime) -> str:
    return at.astimezone(timezone.utc).strftime("'%Y-%m-%d %H:%M:%S'")


# --- HTTP ---------------------------------------------------------------------------------

class Server:
    def __init__(self, base: str, passwords: dict[str, str]):
        self.base = base.rstrip("/")
        self.passwords = passwords
        # One cookie jar per person: Talk ties a call to the session that joined the room.
        # Kept on disk, so --keep-call can check in for the sessions the seed left in a call.
        COOKIES.mkdir(exist_ok=True)
        self.jars = {user: http.cookiejar.LWPCookieJar(COOKIES / f"{user}.txt") for user in passwords}
        self.openers = {user: urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
                        for user, jar in self.jars.items()}

    def load_cookies(self, user: str) -> None:
        if Path(self.jars[user].filename).exists():
            self.jars[user].load(ignore_discard=True)

    def save_cookies(self, user: str) -> None:
        self.jars[user].save(ignore_discard=True)

    def request(self, user: str, method: str, path: str, *, json_body=None, data: bytes | None = None,
                headers: dict | None = None, query: dict | None = None) -> tuple[int, bytes]:
        url = self.base + path + (("?" + urlencode(query, doseq=True)) if query else "")
        token = base64.b64encode(f"{user}:{self.passwords[user]}".encode()).decode()
        all_headers = {"Authorization": f"Basic {token}", "OCS-APIRequest": "true",
                       "Accept": "application/json", **(headers or {})}
        if json_body is not None:
            data = json.dumps(json_body).encode()
            all_headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, method=method, headers=all_headers)
        try:
            with self.openers[user].open(request, timeout=60) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()
        except (urllib.error.URLError, OSError) as error:
            raise SeedError(f"can't reach {self.base}: {getattr(error, 'reason', error)}") from None

    def ocs(self, user: str, method: str, path: str, body=None, query=None, allow=()):
        status, raw = self.request(user, method, path, json_body=body, query=query)
        if status in allow:
            return None
        if not 200 <= status < 300:
            try:
                ocs = json.loads(raw)["ocs"]
                detail = ocs["meta"].get("message") or (ocs.get("data") or {}).get("error") or ocs["meta"].get("status")
            except (ValueError, KeyError, TypeError, AttributeError):
                detail = raw[:200].decode(errors="replace")
            raise SeedError(f"{method} {path} as {user} → {status}: {detail}")
        return json.loads(raw)["ocs"]["data"] if raw else None


def soft(what: str, action) -> None:
    """For the extras an older server may not have: warn, and carry on."""
    try:
        action()
    except SeedError as error:
        warn(f"{what}: {error}")


class Database:
    """The Postgres in compose.yaml, for what no API will do: moving time."""

    def __init__(self, prefix: str):
        self.prefix = prefix

    def run(self, sql: str) -> None:
        subprocess.run(["docker", "compose", "exec", "-T", "db", "psql", "-q", "-v", "ON_ERROR_STOP=1",
                        "-U", "nextcloud", "-d", "nextcloud"],
                       cwd=HERE, input=sql, text=True, check=True, stdout=subprocess.DEVNULL)


# --- Media --------------------------------------------------------------------------------

def fetch_media() -> None:
    """Downloads the stock photos listed in media.json that aren't in media/ yet."""
    manifest = json.loads((HERE / "media.json").read_text())
    missing = {name: url for name, url in manifest.items() if not name.startswith("_") and not (MEDIA / name).exists()}
    if not missing:
        return
    print(f"Downloading {len(missing)} stock photos")
    for name, url in missing.items():
        target = MEDIA / name
        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "kvidr-screenshot-seed"})
            with urllib.request.urlopen(request, timeout=60) as response:
                target.write_bytes(response.read())
        except (urllib.error.URLError, TimeoutError) as error:
            warn(f"couldn't download {name} ({error}); a placeholder will stand in")


def placeholder_png(name: str, width: int = 960, height: int = 640) -> bytes:
    """A soft two-colour gradient with a 'sun', seeded by the file name, for a missing photo."""
    digest = hashlib.sha256(name.encode()).digest()

    def colour(offset: int) -> tuple[int, int, int]:
        hue = digest[offset] / 255
        return tuple(int(255 * (0.55 + 0.35 * math.cos(2 * math.pi * (hue + shift)))) for shift in (0, 1 / 3, 2 / 3))

    top, bottom = colour(0), colour(1)
    cx, cy, radius = width * (0.25 + digest[2] / 512), height * 0.4, height * 0.18
    rows = bytearray()
    for y in range(height):
        t = y / (height - 1)
        base = [round(a + (b - a) * t) for a, b in zip(top, bottom)]
        rows.append(0)
        row = bytearray(bytes(base) * width)
        dy = (y - cy) ** 2
        if dy < radius ** 2:
            half = math.sqrt(radius ** 2 - dy)
            for x in range(max(0, int(cx - half)), min(width, int(cx + half) + 1)):
                row[3 * x:3 * x + 3] = bytes(min(255, c + 60) for c in base)
        rows += row

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b""))


def placeholder_pdf(title: str) -> bytes:
    """A one-page PDF with the title on it — enough for a file message with the right icon."""
    text = title.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
    stream = f"BT /F1 28 Tf 72 720 Td ({text}) Tj ET".encode()
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>",
               b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
               b"/Resources << /Font << /F1 5 0 R >> >> >>",
               b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    out, offsets = bytearray(b"%PDF-1.4\n"), []
    for number, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    out += b"".join(b"%010d 00000 n \n" % offset for offset in offsets)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
    return bytes(out)


def media_file(name: str) -> tuple[str, bytes]:
    """The file from media/, or a stand-in so the layout is still right."""
    source = MEDIA / name
    if source.exists():
        return name, source.read_bytes()
    if name.lower().endswith(".pdf"):
        return name, placeholder_pdf(Path(name).stem)
    return str(Path(name).with_suffix(".png")), placeholder_png(name)


def voice_recording(text: str) -> tuple[str, bytes]:
    """Spoken by macOS's `say`, so kvidr's transcription has real words to find.

    Elsewhere, a synthetic murmur: the waveform looks like speech, which is all a screenshot
    taken on another machine needs.
    """
    if shutil.which("say") and shutil.which("afconvert"):
        with tempfile.TemporaryDirectory() as folder:
            aiff, m4a = Path(folder) / "voice.aiff", Path(folder) / "voice.m4a"
            subprocess.run(["say", "-o", str(aiff), text], check=True)
            subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", str(aiff), str(m4a)], check=True)
            return ".m4a", m4a.read_bytes()
    return ".wav", murmur_wav(len(text.split()) * 0.33)


def murmur_wav(seconds: float, rate: int = 16000) -> bytes:
    samples = bytearray()
    for i in range(int(seconds * rate)):
        t = i / rate
        syllable = max(0.0, math.sin(2 * math.pi * 3.1 * t)) ** 0.6 * (0.25 if (t % 2.3) > 2.0 else 1.0)
        pitch = 140 + 25 * math.sin(2 * math.pi * 0.4 * t)
        voice = sum(math.sin(2 * math.pi * pitch * k * t) / k for k in (1, 2, 3, 4))
        samples += struct.pack("<h", int(9000 * syllable * voice / 2.1))
    header = struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", 36 + len(samples), b"WAVE", b"fmt ", 16, 1, 1,
                         rate, rate * 2, 2, 16, b"data", len(samples))
    return header + bytes(samples)


# --- Users --------------------------------------------------------------------------------

def ensure_user(server: Server, admin: str, user_id: str, profile: dict, password: str) -> None:
    status, _ = server.request(admin, "GET", f"/ocs/v2.php/cloud/users/{quote(user_id)}")
    if status == 404:
        server.ocs(admin, "POST", "/ocs/v2.php/cloud/users",
                   {"userid": user_id, "password": password, "displayName": profile["name"]})
    else:
        server.ocs(admin, "PUT", f"/ocs/v2.php/cloud/users/{quote(user_id)}",
                   {"key": "displayname", "value": profile["name"]})
        server.ocs(admin, "PUT", f"/ocs/v2.php/cloud/users/{quote(user_id)}",
                   {"key": "password", "value": password})

    avatar = next((p for p in (MEDIA / "avatars").glob(f"{user_id}.*")
                   if p.suffix.lower() in (".jpg", ".jpeg", ".png")), None)
    if avatar:
        soft(f"avatar for {user_id}", lambda: upload_avatar(server, user_id, avatar))


def upload_avatar(server: Server, user_id: str, path: Path) -> None:
    boundary = uuid.uuid4().hex
    mime = "image/png" if path.suffix.lower() == ".png" else "image/jpeg"
    body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"files[]\"; filename=\"{path.name}\"\r\n"
            f"Content-Type: {mime}\r\n\r\n").encode() + path.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
    status, raw = server.request(user_id, "POST", "/index.php/avatar/", data=body,
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    if status != 200 or b"success" not in raw:
        raise SeedError(f"{status} {raw[:200].decode(errors='replace')} (avatars must be square)")


def set_absence(server: Server, users: dict, user_id: str, absence: dict, today: date) -> None:
    replacement = absence.get("replacement")
    body = {"firstDay": parse_day(absence["from"], today).isoformat(),
            "lastDay": parse_day(absence["until"], today).isoformat(),
            "status": absence.get("status", ""), "message": absence.get("message", "")}
    if replacement:
        body |= {"replacementUserId": replacement, "replacementUserDisplayName": users[replacement]["name"]}
    server.ocs(user_id, "POST", f"/ocs/v2.php/apps/dav/api/v1/outOfOffice/{quote(user_id)}", body)


def set_status(server: Server, user_id: str, profile: dict) -> None:
    base = "/ocs/v2.php/apps/user_status/api/v1/user_status"
    status = profile.get("status", "online")
    server.ocs(user_id, "PUT", f"{base}/status", {"statusType": "invisible" if status == "offline" else status})
    if profile.get("statusMessage"):
        server.ocs(user_id, "PUT", f"{base}/message/custom",
                   {"statusIcon": profile.get("statusIcon", ""), "message": profile["statusMessage"], "clearAt": None})
    else:
        server.ocs(user_id, "DELETE", f"{base}/message")


def wipe(server: Server, users: list[str]) -> None:
    for user in users:
        rooms = server.ocs(user, "GET", f"{TALK}/v4/room", allow=(401, 404)) or []
        for room in rooms:
            status, _ = server.request(user, "DELETE", f"{TALK}/v4/room/{room['token']}")
            if status >= 400:
                server.request(user, "DELETE", f"{TALK}/v4/room/{room['token']}/participants/self")


# --- Conversations ------------------------------------------------------------------------

def reference_id() -> str:
    return hashlib.sha256(uuid.uuid4().bytes).hexdigest()


def recent(server: Server, user: str, token: str, limit: int = 20) -> list[dict]:
    return server.ocs(user, "GET", f"{TALK}/v1/chat/{token}",
                      query={"lookIntoFuture": 0, "limit": limit, "setReadMarker": 0})


def find_recent(server: Server, user: str, token: str, test) -> int:
    for message in recent(server, user, token):  # newest first
        if test(message):
            return message["id"]
    raise SeedError(f"couldn't find the message just posted in {token}")


def conversation_owner(me: str, conversation: dict) -> str:
    return conversation.get("owner", me)


def create_conversation(server: Server, me: str, users: list[str], conversation: dict) -> str:
    kind = conversation["type"]
    if kind == "note-to-self":
        return server.ocs(me, "GET", f"{TALK}/v4/room/note-to-self")["token"]

    if kind == "one-to-one":
        owner = conversation_owner(me, conversation)
        other = conversation["with"] if owner == me else me
        room = server.ocs(owner, "POST", f"{TALK}/v4/room", {"roomType": 1, "invite": other})
        # Talk adds the other person lazily, when the creator first posts. Them asking for
        # the same one-to-one from their side adds them now, so either of them can go first.
        server.ocs(other, "POST", f"{TALK}/v4/room", {"roomType": 1, "invite": owner})
        return room["token"]

    owner = conversation["owner"]
    room_type = {"group": 2, "public": 3}[kind]
    room = server.ocs(owner, "POST", f"{TALK}/v4/room", {"roomType": room_type, "roomName": conversation["name"]})
    token = room["token"]
    members = conversation.get("members", [])
    for member in users if members == "everyone" else members:
        if member != owner:
            server.ocs(owner, "POST", f"{TALK}/v4/room/{token}/participants",
                       {"newParticipant": member, "source": "users"})
    if conversation.get("description"):
        soft("description", lambda: server.ocs(owner, "PUT", f"{TALK}/v4/room/{token}/description",
                                               {"description": conversation["description"]}))
    if conversation.get("emoji"):
        soft("emoji avatar", lambda: server.ocs(owner, "POST", f"{TALK}/v1/room/{token}/avatar/emoji",
                                                {"emoji": conversation["emoji"], "color": conversation.get("color")}))
    return token


def join_call(server: Server, token: str, user: str, silent: bool) -> None:
    # The first authenticated request swaps the session cookie; settle it before joining,
    # or the call is joined from a session the server has already forgotten.
    server.ocs(user, "GET", f"{TALK}/v4/room/{token}")
    server.ocs(user, "POST", f"{TALK}/v4/room/{token}/participants/active", {})
    server.ocs(user, "POST", f"{TALK}/v4/call/{token}", {"flags": 3, "silent": silent})


def joins_and_leaves(server: Server, user: str, token: str, after: int) -> list[int]:
    """"Joined the call" and "left the call": noise Talk's own apps fold away, which kvidr shows."""
    return [m["id"] for m in recent(server, user, token, 50)
            if m["id"] > after and m.get("systemMessage") in ("call_joined", "call_left")]


def share_file(server: Server, token: str, sender: str, name: str, content: bytes, meta: dict) -> int:
    path = f"/Talk/{name}"
    status, raw = server.request(sender, "PUT", f"/remote.php/dav/files/{quote(sender)}{quote(path)}",
                                 data=content, headers={"X-NC-WebDAV-Auto-Mkcol": "1"})
    if status not in (201, 204):
        raise SeedError(f"upload of {name} as {sender} → {status}: {raw[:200].decode(errors='replace')}")
    reference = reference_id()
    server.ocs(sender, "POST", "/ocs/v2.php/apps/files_sharing/api/v1/shares",
               {"shareType": 10, "shareWith": token, "path": path, "referenceId": reference,
                "talkMetaData": json.dumps(meta)})
    return find_recent(server, sender, token, lambda m: m.get("referenceId") == reference)


class Seeder:
    def __init__(self, server: Server, me: str, users: dict, database: Database | None):
        self.server, self.me, self.users, self.database = server, me, users, database

    def post(self, token: str, message: dict, ids: dict[str, int], times: dict[int, datetime],
             hidden: set[int]) -> int:
        server, sender = self.server, message.get("from")
        reply_to = ids[message["reply_to"]] if "reply_to" in message else None
        thread_id = ids[message["in_thread"]] if "in_thread" in message else None

        if "call" in message:
            return self.past_call(token, message["call"], message["_at"], times, hidden)

        if "file" in message or "voice" in message:
            if "voice" in message:
                extension, content = voice_recording(message["voice"])
                name = f"Voice message {message['_at']:%Y-%m-%d %H-%M-%S}{extension}"
                meta = {"messageType": "voice-message"}
            else:
                name, content = media_file(message["file"])
                meta = {"messageType": "comment", "caption": message.get("caption", "")}
            if reply_to:
                meta["replyTo"] = reply_to
            if thread_id:
                meta["threadId"] = thread_id
            return share_file(server, token, sender, name, content, meta)

        if "poll" in message:
            poll = message["poll"]
            created = server.ocs(sender, "POST", f"{TALK}/v1/poll/{token}",
                                 {"question": poll["question"], "options": poll["options"],
                                  "resultMode": poll.get("resultMode", 0), "maxVotes": poll.get("maxVotes", 1)})
            message_id = find_recent(server, sender, token,
                                     lambda m: m.get("messageParameters", {}).get("object", {}).get("id") == str(created["id"]))
            for voter, option_ids in poll.get("votes", {}).items():
                server.ocs(voter, "POST", f"{TALK}/v1/poll/{token}/{created['id']}", {"optionIds": option_ids})
            return message_id

        if "location" in message:
            place = message["location"]
            geo = f"geo:{place['latitude']},{place['longitude']}"
            meta = {"type": "geo-location", "id": geo, "name": place["name"],
                    "latitude": str(place["latitude"]), "longitude": str(place["longitude"])}
            return server.ocs(sender, "POST", f"{TALK}/v1/chat/{token}/share",
                              {"objectType": "geo-location", "objectId": geo, "metaData": json.dumps(meta),
                               "referenceId": reference_id()})["id"]

        body = {"message": message["text"], "referenceId": reference_id()}
        if reply_to:
            body["replyTo"] = reply_to
        if thread_id:
            body["threadId"] = thread_id
        if message.get("thread"):
            body["threadTitle"] = message["thread"]
        return server.ocs(sender, "POST", f"{TALK}/v1/chat/{token}", body)["id"]

    def past_call(self, token: str, call: dict, ended: datetime, times: dict[int, datetime],
                  hidden: set[int]) -> int:
        """A call that has already happened, so the transcript says who was in it and for how long."""
        server, people, minutes = self.server, call["with"], call.get("minutes", 5)
        for person in people:
            join_call(server, token, person, silent=False)
        started_id = find_recent(server, people[0], token, lambda m: m.get("systemMessage") == "call_started")
        times[started_id] = ended - timedelta(minutes=minutes)
        if self.database:
            # Talk measures the duration from here to the real now, whatever the story says.
            since = datetime.now().astimezone() - timedelta(minutes=minutes)
            self.database.run(f"UPDATE {self.database.prefix}talk_rooms SET active_since = {utc(since)} "
                              f"WHERE token = '{token}';")
        else:
            warn("without backdating, the call lasts only as long as the script took")
        for person in people:
            server.ocs(person, "DELETE", f"{TALK}/v4/call/{token}", {"all": False})
        hidden.update(joins_and_leaves(server, people[0], token, after=started_id))
        return find_recent(server, people[0], token, lambda m: m.get("systemMessage") == "call_ended")

    def seed(self, conversation: dict) -> dict:
        server, me = self.server, self.me
        token = create_conversation(server, me, list(self.users), conversation)
        owner = conversation_owner(me, conversation) if conversation["type"] != "note-to-self" else me
        ids: dict[str, int] = {}
        times: dict[int, datetime] = {}
        hidden: set[int] = set()
        posted: list[tuple[int, dict]] = []
        for index, message in enumerate(conversation["messages"]):
            message_id = self.post(token, message, ids, times, hidden)
            ids[message.get("key", f"#{index}")] = message_id
            times[message_id] = message["_at"]
            posted.append((message_id, message))
            for emoji, people in message.get("reactions", {}).items():
                for person in people:
                    server.ocs(person, "POST", f"{TALK}/v1/reaction/{token}/{message_id}", {"reaction": emoji})
            if message.get("edit"):
                server.ocs(message["from"], "PUT", f"{TALK}/v1/chat/{token}/{message_id}", {"message": message["edit"]})
            if message.get("pin"):
                soft("pin", lambda: server.ocs(owner, "POST", f"{TALK}/v1/chat/{token}/{message_id}/pin", {}))

        if conversation.get("favorite"):
            server.ocs(me, "POST", f"{TALK}/v4/room/{token}/favorite")
        return {"token": token, "posted": posted, "times": times, "hidden": hidden, "owner": owner}

    def finish(self, conversation: dict, result: dict, now: datetime) -> None:
        """What "me" does afterwards, and what would have stopped the messages going in."""
        server, me, token = self.server, self.me, result["token"]
        set_read_marker(server, me, conversation, result)
        for message_id, message in result["posted"]:
            if "remind" in message:
                at = parse_at(message["remind"], None, now)
                soft("reminder", lambda: server.ocs(me, "POST", f"{TALK}/v1/chat/{token}/{message_id}/reminder",
                                                    {"timestamp": int(at.timestamp())}))
        for scheduled in conversation.get("scheduled", []):
            at = parse_at(scheduled["at"], None, now)
            soft("scheduled message", lambda: server.ocs(me, "POST", f"{TALK}/v1/chat/{token}/schedule",
                                                         {"message": scheduled["text"], "sendAt": int(at.timestamp())}))
        if conversation.get("archived"):
            soft("archive", lambda: server.ocs(me, "POST", f"{TALK}/v4/room/{token}/archive"))
        if conversation.get("readOnly"):
            soft("read-only", lambda: server.ocs(result["owner"], "PUT", f"{TALK}/v4/room/{token}/read-only", {"state": 1}))
            # "Olivia locked the conversation" would otherwise be its last word, and its preview.
            result["hidden"].update(m["id"] for m in recent(server, me, token, 5) if m.get("systemMessage") == "read_only")


def set_read_marker(server: Server, me: str, conversation: dict, seeded: dict) -> None:
    unread = conversation.get("unread", 0)
    posted = seeded["posted"]
    if unread <= 0:
        last = max(m["id"] for m in recent(server, me, seeded["token"], 200))
    elif unread >= len(posted):
        last = min(m["id"] for m in recent(server, me, seeded["token"], 200)) - 1
    else:
        last = posted[-unread - 1][0]
    server.ocs(me, "POST", f"{TALK}/v1/chat/{seeded['token']}/read", {"lastReadMessage": last})


# --- Backdating ---------------------------------------------------------------------------

def backdate_sql(server: Server, me: str, seeded: list[tuple[dict, dict]], prefix: str) -> str:
    lines = ["BEGIN;"]
    for conversation, result in seeded:
        planned = result["times"]
        first = min(planned.values())
        current = first - timedelta(minutes=1)  # "You created the conversation" and friends
        threads: dict[int, datetime] = {}
        if result["hidden"]:
            lines.append(f"DELETE FROM {prefix}comments WHERE id IN ({', '.join(map(str, result['hidden']))});")
        for message in sorted(recent(server, me, result["token"], 200), key=lambda m: m["id"]):
            if message["id"] in result["hidden"]:
                continue
            current = planned.get(message["id"], current)
            lines.append(f"UPDATE {prefix}comments SET creation_timestamp = {utc(current)} WHERE id = {message['id']};")
            if message.get("isThread") and message.get("threadId"):
                threads[message["threadId"]] = current
        for message_id, at in planned.items():
            lines.append(f"UPDATE {prefix}comments SET creation_timestamp = {utc(at + timedelta(minutes=1))} "
                         f"WHERE parent_id = {message_id} AND verb = 'reaction';")
        for thread_id, at in threads.items():
            lines.append(f"UPDATE {prefix}talk_threads SET last_activity = {utc(at)} WHERE id = {thread_id};")
        last_id = max(message_id for message_id, _ in result["posted"])
        lines.append(f"UPDATE {prefix}talk_rooms SET last_activity = {utc(max(planned.values()))}, "
                     f"last_message = {last_id} WHERE token = '{result['token']}';")
    lines.append("COMMIT;")
    return "\n".join(lines) + "\n"


# --- Live calls ---------------------------------------------------------------------------

def start_live_calls(server: Server, calls: dict[str, list[str]], silent: bool) -> None:
    for token, people in calls.items():
        for person in people:
            join_call(server, token, person, silent=silent)
            server.save_cookies(person)


def keep_calls(server: Server, calls: dict[str, list[str]]) -> None:
    """Checks in for everyone in the live calls, as a real client does every few seconds.

    Talk drops anyone who hasn't checked in for 100 seconds as soon as someone looks at the
    participant list, which kvidr's inspector does, and the call ends with them.
    """
    for people in calls.values():
        for person in people:
            server.load_cookies(person)
    print("Keeping the call going while you take screenshots. Ctrl-C to stop.")
    try:
        while True:
            for token, people in calls.items():
                for person in people:
                    status, _ = server.request(person, "GET", f"/ocs/v2.php/apps/spreed/api/v3/signaling/{token}")
                    if status == 404:  # their session is gone: back in, quietly
                        join_call(server, token, person, silent=True)
                        server.save_cookies(person)
            time.sleep(10)
    except KeyboardInterrupt:
        print("\nStopped. The call ends by itself once Talk notices nobody is checking in.")


# --- Main ---------------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--server", default="http://localhost:8080")
    parser.add_argument("--admin", default="admin")
    parser.add_argument("--admin-password", default="kvidr-screenshots-admin")
    parser.add_argument("--scenario", default=str(HERE / "scenario.json"))
    parser.add_argument("--wipe", action="store_true", help="delete the users' conversations first")
    parser.add_argument("--keep-call", action="store_true",
                        help="don't seed; keep the last seed's live call going until Ctrl-C")
    parser.add_argument("--no-backdate", action="store_true",
                        help="leave timestamps alone (for a server that isn't the one in compose.yaml)")
    parser.add_argument("--db-prefix", default="oc_")
    args = parser.parse_args()

    scenario = json.loads(Path(args.scenario).read_text())
    me, users, password = scenario["me"], scenario["users"], scenario["password"]
    server = Server(args.server, {args.admin: args.admin_password, **{u: password for u in users}})

    if args.keep_call:
        if not STATE.exists():
            raise SeedError("nothing seeded yet — run seed.py first")
        keep_calls(server, json.loads(STATE.read_text())["calls"])
        return 0

    now = datetime.now().astimezone()
    plan_times(scenario, now)
    database = None if args.no_backdate else Database(args.db_prefix)
    seeder = Seeder(server, me, users, database)

    fetch_media()

    print(f"Users on {server.base}")
    for user_id, profile in users.items():
        ensure_user(server, args.admin, user_id, profile, password)
        print(f"  {user_id} — {profile['name']}")
    for user_id, profile in users.items():
        if profile.get("absence"):
            soft(f"out-of-office for {user_id}",
                 lambda: set_absence(server, users, user_id, profile["absence"], now.date()))

    if args.wipe:
        print("Removing their existing conversations")
        wipe(server, list(users))

    # Created oldest-first, so the sidebar is already in order before any backdating.
    conversations = sorted(scenario["conversations"], key=lambda c: c["messages"][-1]["_at"])
    seeded = []
    print("Conversations")
    for conversation in conversations:
        result = seeder.seed(conversation)
        seeded.append((conversation, result))
        name = conversation.get("name") or conversation.get("with") or conversation["type"]
        print(f"  {name}: {len(result['posted'])} messages")

    for conversation, result in seeded:
        seeder.finish(conversation, result, now)

    # Last, because posting as someone can nudge their status.
    for user_id, profile in users.items():
        soft(f"status for {user_id}", lambda: set_status(server, user_id, profile))

    if database:
        print("Backdating")
        sql = backdate_sql(server, me, seeded, args.db_prefix)
        (HERE / "backdate.sql").write_text(sql)
        database.run(sql)
        subprocess.run(["docker", "compose", "restart", "app"], cwd=HERE, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)  # drops what Talk cached in APCu
        wait_until_up(server, me)

    calls = {result["token"]: conversation["liveCall"] for conversation, result in seeded if conversation.get("liveCall")}
    if calls:
        print("Starting the live call")
        # Not silent, so the transcript says "started a call" rather than "started a silent
        # call"; the ringing that causes is cleared for "me" below.
        start_live_calls(server, calls, silent=False)
        server.request(me, "DELETE", "/ocs/v2.php/apps/notifications/api/v2/notifications")
        if database:
            # Starting a call counts as activity; put the conversation back where the story
            # has it, with its last message as the preview rather than "joined the call".
            sql = []
            for conversation, result in seeded:
                if result["token"] in calls:
                    last_id, _ = result["posted"][-1]
                    hidden = joins_and_leaves(server, me, result["token"], after=last_id)
                    if hidden:
                        sql.append(f"DELETE FROM {args.db_prefix}comments WHERE id IN ({', '.join(map(str, hidden))});")
                    sql.append(f"UPDATE {args.db_prefix}talk_rooms SET last_activity = {utc(max(result['times'].values()))}, "
                               f"last_message = {last_id} WHERE token = '{result['token']}';")
            database.run("\n".join(sql) + "\n")
    STATE.write_text(json.dumps({"calls": calls}))

    print(f"\nDone. In kvidr, sign in to {server.base} as '{me}' with the password '{password}'.")
    if server.base.startswith("http://"):
        print('Plain HTTP needs Settings → Advanced → "Allow insecure local servers" turned on first.')
    if calls:
        print("The call needs someone checking in: `python3 seed.py --keep-call` (setup.sh starts it for you).")
    return 0


def wait_until_up(server: Server, user: str) -> None:
    for _ in range(60):
        try:
            if server.request(user, "GET", "/status.php")[0] == 200:
                return
        except SeedError:
            pass
        time.sleep(1)
    raise SeedError("Nextcloud didn't come back after the restart")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SeedError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
    except subprocess.CalledProcessError as error:
        print(f"error: {' '.join(map(str, error.cmd))} failed", file=sys.stderr)
        sys.exit(1)
