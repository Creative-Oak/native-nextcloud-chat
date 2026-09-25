#!/usr/bin/env python3
"""Fill a Nextcloud Talk server with the conversations in scenario.json.

Made for the throwaway server in compose.yaml (see README.md), where it can also backdate
every message, so screenshots show "Yesterday" and "09:14" rather than a transcript that was
all written a few seconds ago. Standard library only; nothing to install.

    python3 seed.py                     # seed http://localhost:8080 and backdate
    python3 seed.py --no-backdate       # any server; timestamps stay "just now"
    python3 seed.py --wipe              # first delete every conversation the users are in
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import re
import struct
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
import zlib
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote, urlencode

HERE = Path(__file__).resolve().parent
TALK = "/ocs/v2.php/apps/spreed/api"


class SeedError(Exception):
    pass


def warn(text: str) -> None:
    print(f"  ! {text}", file=sys.stderr)


# --- Timestamps ---------------------------------------------------------------------------

def parse_at(spec: str, previous: datetime | None, now: datetime) -> datetime:
    """`-40m`, `-2h`, `+5m`, `today 09:14`, `yesterday 17:30`, `-3d 12:05` — local time."""
    spec = spec.strip()
    if m := re.fullmatch(r"-(\d+)([mh])", spec):
        amount = int(m[1])
        return now - (timedelta(minutes=amount) if m[2] == "m" else timedelta(hours=amount))
    if m := re.fullmatch(r"\+(\d+)m", spec):
        if previous is None:
            raise SeedError(f"'{spec}' needs an earlier message to count from")
        return previous + timedelta(minutes=int(m[1]))
    if m := re.fullmatch(r"(today|yesterday|-(\d+)d)\s+(\d{1,2}):(\d{2})", spec):
        days = 0 if m[1] == "today" else 1 if m[1] == "yesterday" else int(m[2])
        day = now.date() - timedelta(days=days)
        return datetime(day.year, day.month, day.day, int(m[3]), int(m[4])).astimezone()
    raise SeedError(f"can't read the time '{spec}'")


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


# --- HTTP ---------------------------------------------------------------------------------

class Server:
    def __init__(self, base: str, passwords: dict[str, str]):
        self.base = base.rstrip("/")
        self.passwords = passwords

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
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()
        except urllib.error.URLError as error:
            raise SeedError(f"can't reach {self.base}: {error.reason}") from None

    def ocs(self, user: str, method: str, path: str, body=None, query=None, allow=()):
        status, raw = self.request(user, method, path, json_body=body, query=query)
        if status in allow:
            return None
        if not 200 <= status < 300:
            try:
                meta = json.loads(raw)["ocs"]["meta"]
                detail = meta.get("message") or meta.get("status")
            except (ValueError, KeyError, TypeError):
                detail = raw[:200].decode(errors="replace")
            raise SeedError(f"{method} {path} as {user} → {status}: {detail}")
        return json.loads(raw)["ocs"]["data"] if raw else None


def soft(what: str, action) -> None:
    """For the cosmetic extras an older Talk may not have: warn, and carry on."""
    try:
        action()
    except SeedError as error:
        warn(f"{what}: {error}")


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

    avatar = next((p for p in (HERE / "media" / "avatars").glob(f"{user_id}.*")
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


def set_status(server: Server, user_id: str, profile: dict) -> None:
    base = "/ocs/v2.php/apps/user_status/api/v1/user_status"
    status = {"offline": "invisible"}.get(profile.get("status", "online"), profile.get("status", "online"))
    server.ocs(user_id, "PUT", f"{base}/status", {"statusType": status})
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


# --- Placeholder images -------------------------------------------------------------------

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


# --- Conversations ------------------------------------------------------------------------

def reference_id() -> str:
    return hashlib.sha256(uuid.uuid4().bytes).hexdigest()


def latest_message_id(server: Server, user: str, token: str, reference: str | None = None) -> int:
    messages = server.ocs(user, "GET", f"{TALK}/v1/chat/{token}",
                          query={"lookIntoFuture": 0, "limit": 10, "setReadMarker": 0})
    for message in messages:
        if reference and message.get("referenceId") == reference:
            return message["id"]
    own = [m["id"] for m in messages if m.get("actorId") == user and m.get("systemMessage", "") == ""]
    if not own:
        raise SeedError(f"couldn't find the message {user} just posted in {token}")
    return max(own)


def create_conversation(server: Server, me: str, conversation: dict) -> str:
    if conversation["type"] == "one-to-one":
        owner = conversation.get("owner", me)
        other = conversation["with"] if owner == me else me
        room = server.ocs(owner, "POST", f"{TALK}/v4/room", {"roomType": 1, "invite": other})
        # Talk adds the other person lazily, when the creator first posts. Them asking for
        # the same one-to-one from their side adds them now, so either of them can go first.
        server.ocs(other, "POST", f"{TALK}/v4/room", {"roomType": 1, "invite": owner})
        return room["token"]

    owner = conversation["owner"]
    room = server.ocs(owner, "POST", f"{TALK}/v4/room", {"roomType": 2, "roomName": conversation["name"]})
    token = room["token"]
    for member in conversation.get("members", []):
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


def post(server: Server, token: str, message: dict, ids: dict[str, int]) -> int:
    sender = message["from"]
    reply_to = ids[message["reply_to"]] if "reply_to" in message else None

    if "file" in message:
        name = message["file"]
        source = HERE / "media" / name
        content = source.read_bytes() if source.exists() else placeholder_png(name)
        if not source.exists() and not name.lower().endswith(".png"):
            name += ".png"
        status, raw = server.request(sender, "PUT", f"/remote.php/dav/files/{quote(sender)}/Talk/{quote(name)}",
                                     data=content, headers={"X-NC-WebDAV-Auto-Mkcol": "1"})
        if status not in (201, 204):
            raise SeedError(f"upload of {name} as {sender} → {status}: {raw[:200].decode(errors='replace')}")
        reference = reference_id()
        meta = {"messageType": "comment", "caption": message.get("caption", "")}
        if reply_to:
            meta["replyTo"] = reply_to
        server.ocs(sender, "POST", "/ocs/v2.php/apps/files_sharing/api/v1/shares",
                   {"shareType": 10, "shareWith": token, "path": f"/Talk/{name}",
                    "referenceId": reference, "talkMetaData": json.dumps(meta)})
        return latest_message_id(server, sender, token, reference)

    if "poll" in message:
        poll = message["poll"]
        created = server.ocs(sender, "POST", f"{TALK}/v1/poll/{token}",
                             {"question": poll["question"], "options": poll["options"],
                              "resultMode": poll.get("resultMode", 0), "maxVotes": poll.get("maxVotes", 1)})
        message_id = latest_message_id(server, sender, token)
        for voter, option_ids in poll.get("votes", {}).items():
            server.ocs(voter, "POST", f"{TALK}/v1/poll/{token}/{created['id']}", {"optionIds": option_ids})
        return message_id

    body = {"message": message["text"], "referenceId": reference_id()}
    if reply_to:
        body["replyTo"] = reply_to
    return server.ocs(sender, "POST", f"{TALK}/v1/chat/{token}", body)["id"]


def seed_conversation(server: Server, me: str, conversation: dict) -> dict:
    token = create_conversation(server, me, conversation)
    ids: dict[str, int] = {}
    posted: list[tuple[int, dict]] = []
    for index, message in enumerate(conversation["messages"]):
        message_id = post(server, token, message, ids)
        ids[message.get("key", f"#{index}")] = message_id
        posted.append((message_id, message))
        for emoji, people in message.get("reactions", {}).items():
            for person in people:
                server.ocs(person, "POST", f"{TALK}/v1/reaction/{token}/{message_id}", {"reaction": emoji})

    if conversation.get("favorite"):
        server.ocs(me, "POST", f"{TALK}/v4/room/{token}/favorite")
    return {"token": token, "posted": posted}


def history(server: Server, me: str, token: str) -> list[dict]:
    return server.ocs(me, "GET", f"{TALK}/v1/chat/{token}",
                      query={"lookIntoFuture": 0, "limit": 200, "setReadMarker": 0})


def set_read_marker(server: Server, me: str, conversation: dict, seeded: dict) -> None:
    unread = conversation.get("unread", 0)
    posted = seeded["posted"]
    if unread <= 0:
        last = max(m["id"] for m in history(server, me, seeded["token"]))
    elif unread >= len(posted):
        last = min(m["id"] for m in history(server, me, seeded["token"])) - 1
    else:
        last = posted[-unread - 1][0]
    server.ocs(me, "POST", f"{TALK}/v1/chat/{seeded['token']}/read", {"lastReadMessage": last})


# --- Backdating ---------------------------------------------------------------------------

def backdate_sql(server: Server, me: str, seeded: list[tuple[dict, dict]], prefix: str) -> str:
    def stamp(at: datetime) -> str:
        return at.astimezone(timezone.utc).strftime("'%Y-%m-%d %H:%M:%S'")

    lines = ["BEGIN;"]
    for conversation, result in seeded:
        planned = {message_id: message["_at"] for message_id, message in result["posted"]}
        first = min(planned.values())
        current = first - timedelta(minutes=1)  # "You created the conversation" and friends
        for message in sorted(history(server, me, result["token"]), key=lambda m: m["id"]):
            current = planned.get(message["id"], current)
            lines.append(f"UPDATE {prefix}comments SET creation_timestamp = {stamp(current)} WHERE id = {message['id']};")
        for message_id, at in planned.items():
            lines.append(f"UPDATE {prefix}comments SET creation_timestamp = {stamp(at + timedelta(minutes=1))} "
                         f"WHERE parent_id = {message_id} AND verb = 'reaction';")
        lines.append(f"UPDATE {prefix}talk_rooms SET last_activity = {stamp(max(planned.values()))} "
                     f"WHERE token = '{result['token']}';")
    lines.append("COMMIT;")
    return "\n".join(lines) + "\n"


def compose(*args: str, stdin: str | None = None) -> None:
    subprocess.run(["docker", "compose", *args], cwd=HERE, input=stdin, text=True, check=True,
                   stdout=subprocess.DEVNULL)


# --- Main ---------------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--server", default="http://localhost:8080")
    parser.add_argument("--admin", default="admin")
    parser.add_argument("--admin-password", default="kvidr-screenshots-admin")
    parser.add_argument("--scenario", default=str(HERE / "scenario.json"))
    parser.add_argument("--wipe", action="store_true", help="delete the users' conversations first")
    parser.add_argument("--no-backdate", action="store_true",
                        help="leave timestamps alone (for a server that isn't the one in compose.yaml)")
    parser.add_argument("--db-prefix", default="oc_")
    args = parser.parse_args()

    scenario = json.loads(Path(args.scenario).read_text())
    me, users, password = scenario["me"], scenario["users"], scenario["password"]
    now = datetime.now().astimezone()
    plan_times(scenario, now)

    server = Server(args.server, {args.admin: args.admin_password, **{u: password for u in users}})

    print(f"Users on {server.base}")
    for user_id, profile in users.items():
        ensure_user(server, args.admin, user_id, profile, password)
        print(f"  {user_id} — {profile['name']}")

    if args.wipe:
        print("Removing their existing conversations")
        wipe(server, list(users))

    # Created oldest-first, so the sidebar is already in order before any backdating.
    conversations = sorted(scenario["conversations"], key=lambda c: c["messages"][-1]["_at"])
    seeded = []
    print("Conversations")
    for conversation in conversations:
        result = seed_conversation(server, me, conversation)
        seeded.append((conversation, result))
        print(f"  {conversation.get('name') or conversation['with']}: {len(result['posted'])} messages")

    for conversation, result in seeded:
        set_read_marker(server, me, conversation, result)
        if conversation.get("archived"):
            soft("archive", lambda: server.ocs(me, "POST", f"{TALK}/v4/room/{result['token']}/archive"))

    # Last, because posting as someone can nudge their status.
    for user_id, profile in users.items():
        soft(f"status for {user_id}", lambda: set_status(server, user_id, profile))

    if not args.no_backdate:
        print("Backdating")
        sql = backdate_sql(server, me, seeded, args.db_prefix)
        (HERE / "backdate.sql").write_text(sql)
        compose("exec", "-T", "db", "psql", "-q", "-v", "ON_ERROR_STOP=1", "-U", "nextcloud", "-d", "nextcloud",
                stdin=sql)
        compose("restart", "app")  # drops anything Talk cached in APCu

    print(f"\nDone. In kvidr, sign in to {server.base} as '{me}' with the password '{password}'.")
    if server.base.startswith("http://"):
        print('Plain HTTP needs Settings → Advanced → "Allow insecure local servers" turned on first.')
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SeedError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
    except subprocess.CalledProcessError as error:
        print(f"error: {' '.join(error.cmd)} failed", file=sys.stderr)
        sys.exit(1)
