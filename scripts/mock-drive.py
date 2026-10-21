#!/usr/bin/env python3
"""A stand-in for Google's sign-in and the parts of the Drive API TheExplorer uses, for tests
and scripted UI runs. Nothing leaves this machine.

    python3 scripts/mock-drive.py 5056

Then point a debug build at it with EXPLORER_DRIVE_ENDPOINT=http://127.0.0.1:5056 (see
DEVELOPMENT.md). The sign-in page redirects straight back as if you'd approved it.
"""

import json
import os
import re
import struct
import sys
import threading
import uuid
import zlib
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse

FOLDER = "application/vnd.google-apps.folder"
GOOGLE = "application/vnd.google-apps."
lock = threading.Lock()
files = {}
drives = {"team-drive": {"id": "team-drive", "name": "Team", "createdTime": "2025-02-01T09:00:00.000Z"}}
sessions = {}
tokens = {"issued": 0}
# Sharing emails Drive would have sent, for tests to check (GET /mock/sent).
sent = []
ME = {"id": "perm-me", "type": "user", "role": "owner", "emailAddress": "test@example.com", "displayName": "Test User"}


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def add(id, name, mime, parents, content=b"", **extra):
    files[id] = {
        "id": id, "name": name, "mimeType": mime, "parents": parents, "content": content,
        "modifiedTime": extra.pop("modified", "2026-10-01T10:00:00.000Z"), "createdTime": "2026-01-15T08:30:00.000Z",
        "trashed": False, "starred": extra.pop("starred", False), "shared": extra.pop("shared", False),
        "permissions": extra.pop("permissions", [dict(ME)]), **extra,
    }


def tiny_pdf(text):
    """A one-page PDF with a line of text, so previews have something real to show."""
    stream = f"BT /F1 24 Tf 72 720 Td ({text}) Tj ET".encode()
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = b"%PDF-1.4\n"
    offsets = []
    for number, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    out += b"".join(b"%010d 00000 n \n" % offset for offset in offsets)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
    return out


def png(width, height, seed):
    """A gradient PNG standing in for one of Drive's thumbnails."""
    rows = b""
    for y in range(height):
        rows += b"\x00" + bytes(
            v for x in range(width) for v in ((x * 255 // width + seed) % 256, (y * 255 // height) % 256, (seed * 3) % 256))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


THUMBNAILED = ("image/", "video/", "application/pdf", GOOGLE + "document", GOOGLE + "spreadsheet", GOOGLE + "presentation")


def seed():
    add("root-id", "My Drive", FOLDER, [])
    add("projects", "Projects", FOLDER, ["root-id"], starred=True)
    add("y2026", "2026", FOLDER, ["projects"])
    add("photos", "Photos", FOLDER, ["root-id"])
    add("notes", "notes.txt", "text/plain", ["root-id"], b"Remember the milk.\n", modified="2026-10-10T12:00:00.000Z")
    add("readme", "README.md", "text/markdown", ["projects"], b"# Projects\n\nEverything for **2026**.\n")
    add("data", "data.csv", "text/csv", ["y2026"], b"name,amount\nAda,12\nGrace,30\n")
    add("report", "Report Q3.pdf", "application/pdf", ["projects"], tiny_pdf("Q3 report"))
    add("budget", "Budget", GOOGLE + "spreadsheet", ["root-id"])
    add("plan", "Launch plan", GOOGLE + "document", ["projects"])
    add("survey", "Survey", GOOGLE + "form", ["projects"])
    add("beach", "beach.png", "image/png", ["photos"], png(64, 48, 7))
    add("long", "server.log", "text/plain", ["root-id"], b"".join(b"line %d: all good\n" % i for i in range(5000)))
    add("shortcut", "Projects shortcut", "application/vnd.google-apps.shortcut", ["root-id"],
        shortcutDetails={"targetId": "projects", "targetMimeType": FOLDER})
    # Shared with you from someone else's Drive: its folder isn't visible.
    add("invite", "Wedding invite.pdf", "application/pdf", ["hidden-folder"], tiny_pdf("You're invited"), shared=True,
        permissions=[{"id": "perm-someone", "type": "user", "role": "owner", "emailAddress": "someone@example.org", "displayName": "Someone Else"},
                     {"id": "perm-me", "type": "user", "role": "reader", "emailAddress": "test@example.com", "displayName": "Test User"}])
    files["projects"]["permissions"].append(
        {"id": "perm-ada", "type": "user", "role": "writer", "emailAddress": "ada@example.com", "displayName": "Ada Lovelace"})
    files["report"]["permissions"].append({"id": "anyoneWithLink", "type": "anyone", "role": "reader"})
    add("team-root", "Team", FOLDER, [], driveId="team-drive")
    files["team-root"]["id"] = "team-drive"
    files["team-drive"] = files.pop("team-root")
    # In a shared drive, access comes from the drive's members.
    add("roadmap", "Roadmap.txt", "text/plain", ["team-drive"], b"Q4: ship it\n", driveId="team-drive",
        permissions=[{"id": "perm-me", "type": "user", "role": "organizer", "emailAddress": "test@example.com", "displayName": "Test User",
                      "permissionDetails": [{"permissionType": "member", "role": "organizer", "inherited": True, "inheritedFrom": "team-drive"}]},
                     {"id": "perm-grace", "type": "user", "role": "writer", "emailAddress": "grace@example.com", "displayName": "Grace Hopper",
                      "permissionDetails": [{"permissionType": "member", "role": "writer", "inherited": True, "inheritedFrom": "team-drive"}]}])


def can_share(f):
    return any(p["emailAddress" if "emailAddress" in p else "id"] == ME["emailAddress"] and p["role"] in ("owner", "organizer", "fileOrganizer", "writer")
               for p in f["permissions"])


def public(f, fresh=True):
    out = {k: v for k, v in f.items() if k not in ("content", "trashed", "starred", "shared", "permissions")}
    if not f["mimeType"].startswith(GOOGLE):
        out["size"] = str(len(f["content"]))
    kind = "folders" if f["mimeType"] == FOLDER else "file/d"
    out["webViewLink"] = f"https://drive.google.com/{kind}/{f['id']}/view"
    out["owners"] = [{"displayName": "Someone Else" if f["shared"] else "Test User"}]
    out["capabilities"] = {"canAddChildren": f["mimeType"] == FOLDER, "canRename": True, "canTrash": True, "canShare": can_share(f)}
    if f["mimeType"].startswith(THUMBNAILED):
        # With MOCK_EXPIRE_THUMBS set, links from listings have expired, like Google's do after
        # a few hours; asking for the file alone gives a working one.
        stale = not fresh and os.environ.get("MOCK_EXPIRE_THUMBS")
        out["thumbnailLink"] = f"{HOST}/{'expired' if stale else 'thumb'}/{f['id']}=s220"
    return out


def sort_key(f):
    return (f["mimeType"] != FOLDER, f["name"].lower())


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, status, body=b"", content_type="application/json", headers=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def error(self, status, reason, message):
        self.send(status, {"error": {"code": status, "message": message, "errors": [{"reason": reason, "message": message}]}})

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def authorized(self):
        if self.headers.get("Authorization", "").startswith("Bearer access-"):
            return True
        self.error(401, "authError", "Invalid Credentials")
        return False

    def route(self, method):
        url = urlparse(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        path = url.path

        if path == "/o/oauth2/v2/auth":
            target = query["redirect_uri"] + "?" + urlencode({"code": "test-code", "state": query.get("state", ""), "scope": query.get("scope", "")})
            return self.send(302, b"", headers={"Location": target})
        if path == "/token" and method == "POST":
            form = {k: v[0] for k, v in parse_qs(self.body().decode()).items()}
            if form.get("client_secret") != "test-secret":
                return self.send(401, {"error": "invalid_client", "error_description": "The OAuth client was not found."})
            with lock:
                tokens["issued"] += 1
                access = f"access-{tokens['issued']}"
            reply = {"access_token": access, "expires_in": 3599, "token_type": "Bearer"}
            if form.get("grant_type") == "authorization_code":
                if form.get("code") != "test-code" or not form.get("code_verifier"):
                    return self.send(400, {"error": "invalid_grant"})
                reply["refresh_token"] = "refresh-test"
            elif form.get("refresh_token") == "revoked":
                return self.send(400, {"error": "invalid_grant", "error_description": "Token has been expired or revoked."})
            return self.send(200, reply)
        if path == "/revoke":
            return self.send(200, {})

        if not self.authorized():
            return
        if path.startswith("/expired/"):
            return self.error(403, "forbidden", "The thumbnail link has expired.")
        if m := re.fullmatch(r"/thumb/([^=]+)=s(\d+)", path):
            if m[1] not in files:
                return self.error(404, "notFound", "No thumbnail")
            side = min(int(m[2]), 480)
            return self.send(200, png(side, side * 3 // 4, sum(map(ord, m[1]))), "image/png")
        with lock:
            return self.drive(method, path, query)

    def drive(self, method, path, query):
        if path == "/drive/v3/about":
            return self.send(200, {"user": {"displayName": "Test User", "emailAddress": "test@example.com"},
                                   "storageQuota": {"limit": str(15 * 1024**3), "usage": str(3 * 1024**3 + 512 * 1024**2)}})
        if path == "/drive/v3/drives":
            return self.send(200, {"drives": list(drives.values())})
        if m := re.fullmatch(r"/drive/v3/drives/([^/]+)", path):
            drive = drives.get(m[1])
            return self.send(200, drive) if drive else self.error(404, "notFound", "Shared drive not found")

        if path == "/drive/v3/files" and method == "GET":
            return self.list(query)
        if path == "/drive/v3/files" and method == "POST":
            meta = json.loads(self.body() or b"{}")
            id = "new-" + uuid.uuid4().hex[:8]
            add(id, meta["name"], meta.get("mimeType", "application/octet-stream"), meta.get("parents", ["root-id"]), modified=now())
            return self.send(200, public(files[id]))
        if path == "/upload/drive/v3/files" and query.get("uploadType") == "resumable":
            meta = json.loads(self.body() or b"{}")
            session = uuid.uuid4().hex
            sessions[session] = (meta, self.headers.get("X-Upload-Content-Type", "application/octet-stream"))
            host = self.headers.get("Host")
            return self.send(200, b"", headers={"Location": f"http://{host}/upload/session/{session}"})
        if m := re.fullmatch(r"/upload/session/([^/]+)", path):
            meta, mime = sessions.pop(m[1])
            id = "up-" + uuid.uuid4().hex[:8]
            add(id, meta["name"], mime, meta.get("parents", ["root-id"]), self.body(), modified=now())
            return self.send(200, public(files[id]))

        if path == "/mock/sent":
            return self.send(200, sent)
        if m := re.fullmatch(r"/drive/v3/files/([^/]+)/permissions(?:/([^/]+))?", path):
            return self.permissions(method, m[1], m[2], query)

        m = re.fullmatch(r"/drive/v3/files/([^/]+)(/export|/copy)?", path)
        if not m:
            return self.error(404, "notFound", "No such endpoint " + path)
        id = "root-id" if m[1] == "root" else m[1]
        f = files.get(id)
        if not f or f["trashed"] or id == "hidden-folder":
            return self.error(404, "notFound", f"File not found: {m[1]}.")
        if m[2] == "/export":
            mime = query.get("mimeType", "")
            if not f["mimeType"].startswith(GOOGLE) or f["mimeType"].endswith("form"):
                return self.error(403, "fileNotExportable", "Export only supports Docs Editors files.")
            content = tiny_pdf(f["name"]) if mime == "application/pdf" else f"{f['name']} as {mime}\n".encode()
            return self.send(200, content, mime)
        if m[2] == "/copy":
            meta = json.loads(self.body() or b"{}")
            copy = "copy-" + uuid.uuid4().hex[:8]
            add(copy, meta.get("name", f["name"]), f["mimeType"], meta.get("parents", f["parents"]), f["content"], modified=now())
            return self.send(200, public(files[copy]))
        if method == "PATCH":
            change = json.loads(self.body() or b"{}")
            if "name" in change:
                f["name"] = change["name"]
            if change.get("trashed"):
                f["trashed"] = True
            if "addParents" in query:
                removed = query.get("removeParents", "").split(",")
                f["parents"] = [p for p in f["parents"] if p not in removed] + [query["addParents"]]
            f["modifiedTime"] = now()
            return self.send(200, public(f))
        if query.get("alt") == "media":
            if f["mimeType"].startswith(GOOGLE):
                return self.error(403, "fileNotDownloadable", "Only files with binary content can be downloaded. Use Export with Docs Editors files.")
            content = f["content"]
            if r := re.fullmatch(r"bytes=(\d+)-(\d+)", self.headers.get("Range", "")):
                part = content[int(r[1]):int(r[2]) + 1]
                return self.send(206, part, f["mimeType"], {"Content-Range": f"bytes {r[1]}-{int(r[1]) + len(part) - 1}/{len(content)}"})
            return self.send(200, content, f["mimeType"])
        return self.send(200, public(f))

    def permissions(self, method, id, permission_id, query):
        f = files.get(id)
        if not f or f["trashed"]:
            return self.error(404, "notFound", f"File not found: {id}.")
        perms = f["permissions"]
        if method == "GET" and not permission_id:
            return self.send(200, {"permissions": perms})
        if not can_share(f):
            return self.error(403, "insufficientFilePermissions", "The user does not have sufficient permissions for this file.")
        if method == "POST":
            new = json.loads(self.body() or b"{}")
            kind, role = new.get("type"), new.get("role")
            if role not in ("reader", "commenter", "writer", "fileOrganizer", "organizer", "owner") or kind not in ("user", "group", "domain", "anyone"):
                return self.error(400, "invalid", "Invalid permission.")
            if kind in ("user", "group"):
                email = new.get("emailAddress", "")
                if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", email):
                    return self.error(400, "invalid", f"Invalid email address: {email}")
                if email.endswith("@nogoogle.example") and query.get("sendNotificationEmail") == "false":
                    return self.error(400, "invalidSharingRequest", f"Bad Request. User message: \"You are trying to invite {email}. Since there is no Google account associated with this email address, you must check the 'Notify people' box to invite this recipient.\"")
                existing = next((p for p in perms if p.get("emailAddress", "").lower() == email.lower()), None)
                if existing:
                    existing["role"] = role
                    return self.send(200, existing)
                p = {"id": "perm-" + uuid.uuid4().hex[:8], "type": kind, "role": role, "emailAddress": email,
                     "displayName": email.split("@")[0].title()}
                if query.get("sendNotificationEmail", "true") == "true":
                    sent.append({"file": id, "to": email, "role": role, "message": query.get("emailMessage", "")})
            elif kind == "anyone":
                if f.get("driveId") and id == f.get("driveId"):
                    return self.error(403, "cannotShareTeamDriveTopFolderWithAnyoneOrDomains", "Cannot share a shared drive with anyone.")
                p = {"id": "anyoneWithLink", "type": "anyone", "role": role}
                perms[:] = [q for q in perms if q["type"] != "anyone"]
            else:
                p = {"id": "domain-" + new.get("domain", ""), "type": "domain", "role": role, "domain": new.get("domain", "")}
            perms.append(p)
            return self.send(200, p)
        p = next((q for q in perms if q["id"] == permission_id), None)
        if not p:
            return self.error(404, "notFound", f"Permission not found: {permission_id}.")
        if any(d.get("inherited") for d in p.get("permissionDetails", [])):
            return self.error(403, "cannotModifyInheritedTeamDrivePermission", "Cannot modify an inherited permission.")
        if p["role"] == "owner":
            return self.error(403, "forbidden", "The owner of a file can't be changed or removed.")
        if method == "PATCH":
            p["role"] = json.loads(self.body() or b"{}").get("role", p["role"])
            return self.send(200, p)
        if method == "DELETE":
            perms.remove(p)
            return self.send(204)
        return self.error(405, "invalid", "Method not allowed")

    def list(self, query):
        q = query.get("q", "")
        live = [f for f in files.values() if not f["trashed"] and f["id"] != "root-id"]
        if m := re.match(r"'((?:[^'\\]|\\.)*)' in parents", q):
            parent = "root-id" if m[1] == "root" else m[1]
            found = [f for f in live if parent in f["parents"]]
        elif q.startswith("sharedWithMe"):
            found = [f for f in live if f["shared"]]
        elif q.startswith("starred"):
            found = [f for f in live if f["starred"]]
        elif m := re.search(r"name contains '((?:[^'\\]|\\.)*)'", q):
            text = m[1].replace("\\'", "'").replace("\\\\", "\\").lower()
            found = [f for f in live if text in f["name"].lower() or text.encode() in f["content"].lower()]
        else:
            return self.error(400, "invalid", "Invalid Value: " + q)
        if query.get("orderBy"):
            found.sort(key=sort_key)
        size = int(query.get("pageSize", 100))
        start = int(query.get("pageToken", 0))
        page = found[start:start + size]
        reply = {"files": [public(f, fresh=False) for f in page]}
        if start + size < len(found):
            reply["nextPageToken"] = str(start + size)
        return self.send(200, reply)

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PATCH(self):
        self.route("PATCH")

    def do_PUT(self):
        self.route("PUT")

    def do_DELETE(self):
        self.route("DELETE")


if __name__ == "__main__":
    seed()
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5056
    # MOCK_HOST: the address clients use, when they reach the mock through a proxy.
    HOST = os.environ.get("MOCK_HOST", f"http://127.0.0.1:{port}")
    print(f"mock Google Drive on http://127.0.0.1:{port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
