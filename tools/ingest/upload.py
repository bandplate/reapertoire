#!/usr/bin/env python3
"""Pushes a rendered session to a bandplate-compatible ingest API.

Reads the manifest a render produced and walks the contract's three phases:
declare the event, declare each take and receive presigned upload URLs, PUT the
bytes, commit. Needs no DAW -- the manifest already holds every fact the API
asks for.

Everything is idempotent by design, because rehearsals get re-rendered, uploads
die halfway and laptops sleep. The session UUID and the region GUIDs are the
client references; re-posting either returns the existing row rather than
creating a second one. An asset whose hash and size already match is skipped
without re-uploading, which is what lets a run that failed on take nine resume
without pushing the first eight again.

Standard library only: urllib, hashlib, json. Nothing here should need
installing to work.

    upload.py --manifest .../manifest.json --api https://example/api/ingest/v1
    upload.py --manifest ... --dry-run
    upload.py --manifest ... --no-publish

The API base URL and the token both come from the `ingest` block of
`config/settings.json`, which is gitignored, so neither has to be retyped per
run. REAPERTOIRE_TOKEN overrides the stored token and `--api` overrides the
stored URL, which is what a CI run or a push at somebody else's server wants.
"""

import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

# Presigned PUT URLs live an hour. A slow uplink pushing a whole session will
# outlive that, so a 403 mid-upload is normal operation rather than an error:
# re-declare the take, take the fresh URLs, carry on.
EXPIRY_STATUS = 403

# Identifies the client on every request. urllib otherwise announces itself as
# `Python-urllib/3.x`, which a CDN's bot protection blocks outright -- a bare
# 403 carrying an HTML page and "error code: 1010", nothing to do with the
# token or the API. Naming the tool is what any HTTP client should do anyway.
USER_AGENT = "reapertoire (+https://github.com/bandplate/reapertoire)"

# Server-side faults only. The contract is explicit that the ingest surface has
# no rate limiting in v1 and never returns 429 -- "don't build retry-on-429
# handling around a code that doesn't exist yet" -- so a 429 from anywhere is
# something other than the ingest API answering, and retrying it is wrong.
RETRY_STATUSES = (500, 502, 503, 504)
MAX_ATTEMPTS = 4

# How many times a take's presigned URLs may be re-issued before the run gives
# up on it. Each round buys another hour, so this covers a genuinely slow push
# without letting a server that keeps returning dead URLs spin forever.
MAX_URL_REFRESHES = 3

# The vocabularies the server validates against. Checked here so a manifest is
# rejected whole, before anything has been declared, rather than one 422 at a
# time after the event exists.
EVENT_KINDS = ("rehearsal", "concert", "session")
AUDIO_FORMATS = ("opus", "mp3", "flac", "wav")
TIERS = ("lossy", "lossless")
HEX_SHA256 = re.compile(r"^[0-9a-f]{64}$", re.IGNORECASE)


class IngestError(Exception):
    """An error the operator needs to see, with the API's own words."""


def human_bytes(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024.0


class Progress:
    """A one-line upload bar, redrawn in place.

    Silent unless the output is a terminal: piped into a file or a log, a
    carriage return every few hundred kilobytes produces an unreadable mess,
    and the per-take lines already say what happened. Silent in a dry run too,
    where nothing is sent.

    Counts bytes actually PUT, not bytes declared -- an asset the server
    already has is skipped, and counting it would show a session "uploading"
    at a speed no uplink has.
    """

    BAR_WIDTH = 24

    def __init__(self, total_bytes, total_takes, stream=None, mode="auto"):
        # How wide the last line was, so clearing wipes exactly that and no
        # more -- padding every line to a fixed width wraps on a narrow window.
        self._width = 0
        self.total = max(0, total_bytes)
        self.total_takes = total_takes
        self.done = 0
        self.take = 0
        self.label = ""
        self.stream = stream if stream is not None else sys.stderr
        # "auto" is right for a log file and wrong for a terminal emulator
        # that does not report itself as one -- an editor's output pane, a CI
        # runner, anything wrapping the process. Hence the override.
        if mode == "never":
            self.enabled = False
        elif mode == "always":
            self.enabled = bool(total_bytes)
        else:
            self.enabled = bool(total_bytes) and self.stream.isatty()
        self.started = time.monotonic()

    def take_started(self, index, name):
        # Recorded, not drawn. A run that sends nothing -- every asset already
        # on the server, which is the common case on a re-run -- would
        # otherwise flash an empty bar per take and clear it again, which is
        # noise saying "0%" about work that is not happening.
        self.take, self.label = index, name

    def advance(self, n):
        self.done += n
        self.draw()

    @property
    def drawn(self):
        return self._width > 0

    def draw(self):
        if not self.enabled:
            return
        fraction = min(1.0, self.done / self.total) if self.total else 0.0
        filled = int(fraction * self.BAR_WIDTH)
        elapsed = time.monotonic() - self.started
        rate = f"{human_bytes(self.done / elapsed)}/s" if elapsed > 1 and self.done else "--"
        line = (f"\r[{'#' * filled}{'.' * (self.BAR_WIDTH - filled)}] {fraction * 100:3.0f}% "
                f"{human_bytes(self.done)}/{human_bytes(self.total)} "
                f"{rate}  take {self.take}/{self.total_takes} {self.label}")
        # Padded to overwrite a longer previous line, since \r only returns the
        # cursor and leaves whatever was already there.
        line = line[:120]
        self.stream.write(line.ljust(self._width))
        self.stream.flush()
        self._width = max(0, len(line) - 1)

    def done_with_all(self):
        """Wipes the bar so the next log line starts on a clean row."""
        if self.enabled and self.drawn:
            self.stream.write("\r" + " " * self._width + "\r")
            self.stream.flush()
            self._width = 0


class Client:
    def __init__(self, base_url, token, timeout=120):
        self.base = base_url.rstrip("/")
        self.token = token
        self.timeout = timeout

    # ---------------------------------------------------------------- request

    def _request(self, method, path, body=None, headers=None):
        url = path if path.startswith("http") else f"{self.base}{path}"
        data = None
        merged = {"Authorization": f"Bearer {self.token}", "User-Agent": USER_AGENT}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            merged["Content-Type"] = "application/json"
        merged.update(headers or {})

        request = urllib.request.Request(url, data=data, headers=merged, method=method)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read()
                return response.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                payload = json.loads(raw) if raw else {}
            except json.JSONDecodeError:
                # Not the API answering: the ingest surface always speaks JSON,
                # so an unparseable body means something in front of it -- a
                # CDN, a proxy, a captive portal -- replied instead.
                text = raw[:400].decode("utf-8", "replace")
                snippet = " ".join(re.sub(r"<[^>]+>", " ", text).split())[:200]
                payload = {"error": {
                    "code": "not_the_api",
                    "message": f"something in front of the API answered, not the API itself: {snippet}",
                }}
            return error.status, payload
        except urllib.error.URLError as error:
            raise IngestError(f"cannot reach {url}: {error.reason}") from error

    def _json(self, method, path, body=None):
        """A request whose failure is the operator's problem, not a retry."""
        for attempt in range(1, MAX_ATTEMPTS + 1):
            status, payload = self._request(method, path, body)
            if 200 <= status < 300:
                return payload
            if status in RETRY_STATUSES and attempt < MAX_ATTEMPTS:
                # Exponential, so a server that is down rather than briefly
                # busy is not hammered while it comes back.
                time.sleep(min(2 ** attempt, 30))
                continue
            raise IngestError(_describe(status, payload))
        raise IngestError(f"{method} {path} still failing after {MAX_ATTEMPTS} attempts")

    # ------------------------------------------------------------- operations

    def instruments(self):
        """The live vocabulary: {canonical slug: [its aliases]}.

        An alias is another name for the instrument, accepted wherever the
        canonical slug is. Checking against canonical slugs alone refused
        names the server would have taken.

        Entries are read leniently -- a bare slug string is accepted too, and
        so is an entry with no `aliases`, which is every server from before
        the field existed.
        """
        payload = self._json("GET", "/instruments")
        entries = payload if isinstance(payload, list) else payload.get("instruments", [])
        vocabulary = {}
        for entry in entries:
            if isinstance(entry, str):
                vocabulary[entry] = []
            elif entry.get("slug"):
                vocabulary[entry["slug"]] = [a for a in entry.get("aliases") or [] if a]
        return vocabulary

    def declare_event(self, event):
        return self._json("POST", "/events", event)

    def declare_take(self, take):
        return self._json("POST", "/takes", take)

    def refresh_uploads(self, take_id):
        return self._json("GET", f"/takes/{take_id}/uploads")

    def commit(self, take_id, publish=True):
        return self._json("POST", f"/takes/{take_id}/commit", {"publish": publish})

    def put_bytes(self, url, headers, path, on_progress=None):
        """Uploads one file. Returns True, or False when the URL has expired.

        Streamed from disk rather than read into memory: a lossless master is
        the size the contract's own "Size" section anticipates growing to, and
        a progress bar that only moves between files says nothing during the
        one file that takes a minute.
        """
        # Checked again here, not just in `verify_assets`. That runs once
        # before anything is declared, and a session pushing gigabytes stays
        # open for a long time afterwards -- long enough for a re-render to
        # clear a take's folder, or for the whole directory to be moved or
        # deleted, while the run is still going. Letting the open() below
        # raise gives a traceback out of pathlib and says nothing useful.
        try:
            size = Path(path).stat().st_size
        except OSError as error:
            raise IngestError(
                f"{path} vanished while the session was uploading: {error.strerror}.\n"
                "Something changed the files underneath the run -- a re-render, or the\n"
                "folder being moved. Re-run once it has settled; takes already sent are\n"
                "skipped rather than sent twice."
            ) from error
        # The presigned headers go up exactly as issued; the agent is added
        # alongside them, never over one. It is not among the headers the
        # signature covers, so it cannot invalidate the URL.
        merged = {"User-Agent": USER_AGENT}
        merged.update(headers or {})
        # Explicit, because urllib falls back to chunked transfer-encoding for
        # a body it cannot measure -- which a presigned S3 PUT rejects.
        merged["Content-Length"] = str(size)

        try:
            handle = open(path, "rb")
        except OSError as error:
            raise IngestError(
                f"{path} vanished while the session was uploading: {error.strerror}"
            ) from error
        body = _ReportingReader(handle, on_progress) if on_progress else handle
        request = urllib.request.Request(url, data=body, headers=merged, method="PUT")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return 200 <= response.status < 300
        except urllib.error.HTTPError as error:
            if error.status == EXPIRY_STATUS:
                return False
            raise IngestError(f"upload of {Path(path).name} failed: HTTP {error.status}")
        except urllib.error.URLError as error:
            raise IngestError(f"upload of {Path(path).name} failed: {error.reason}") from error
        finally:
            handle.close()


class _ReportingReader:
    """A read-only file wrapper that reports how much has gone up.

    urllib asks for the body in blocks, so counting reads counts what has been
    handed to the socket. That is not the same as what the far end has
    acknowledged -- the last few blocks may still be in flight -- but for a bar
    measured in hundreds of megabytes the difference is invisible, and the
    alternative is no feedback at all.
    """

    def __init__(self, handle, on_progress):
        self._handle = handle
        self._on_progress = on_progress

    def read(self, size=-1):
        block = self._handle.read(size)
        if block:
            self._on_progress(len(block))
        return block

    def __getattr__(self, name):
        return getattr(self._handle, name)


def _describe(status, payload):
    error = (payload or {}).get("error") or {}
    code = error.get("code", "unknown")
    message = error.get("message", "")
    extra = ""
    # The contract's 409s and 422s carry structured context alongside the
    # error, and it is the part that says what to do about them.
    for key in ("missing", "candidates", "validSlugs"):
        if key in (payload or {}):
            extra = f" ({key}: {json.dumps(payload[key])[:200]})"
            break
    return f"HTTP {status} {code}: {message}{extra}"


# ------------------------------------------------------------------- manifest


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def held_at(event):
    """The session start as an aware datetime, or None if it cannot be one.

    The contract wants ISO-8601 *with a numeric offset* -- "the offset is how
    it knows what you meant" -- so a naive timestamp is as useless as a
    missing one and is rejected the same way. Python before 3.11 will not
    parse a trailing `Z`, which is a perfectly ordinary thing for a manifest
    to carry, so it is normalised rather than refused.
    """
    held = event.get("heldAt")
    if not held:
        return None
    try:
        started = datetime.fromisoformat(str(held).replace("Z", "+00:00"))
    except ValueError:
        return None
    return started if started.utcoffset() is not None else None


def recorded_at(event, take):
    """Wall-clock time of a take, from the session's start plus its offset.

    Take positions are absolute project seconds, which say nothing about when
    something happened; the session's heldAt anchors them.
    """
    started = held_at(event)
    if started is None:
        return None
    offset = (take.get("start") or 0) - (event.get("rangeStart") or 0)
    if offset < 0:
        offset = 0
    return (started + timedelta(seconds=offset)).isoformat()


def _asset_problems(asset, where):
    """One asset against the server's discriminated union of asset shapes."""
    problems = []
    kind = asset.get("kind")
    tier = asset.get("tier", "lossy")
    fmt = asset.get("format")

    if kind not in ("master", "stem", "peaks"):
        return [f"{where}: kind {kind!r} is none of master, stem, peaks"]
    if tier not in TIERS:
        problems.append(f"{where}: tier {tier!r} is neither lossy nor lossless")

    if kind == "peaks":
        if fmt != "json":
            problems.append(f"{where}: peaks must be json, not {fmt!r}")
        # Optional on peaks -- absent means the master -- but a blank string is
        # not the same as absent, and the server rejects it.
        if asset.get("instrument") is not None and not str(asset["instrument"]).strip():
            problems.append(f"{where}: names a blank instrument; omit it for the master")
    else:
        if fmt not in AUDIO_FORMATS:
            problems.append(
                f"{where}: format {fmt!r} is not one of " + ", ".join(AUDIO_FORMATS))
        if kind == "stem" and not str(asset.get("instrument") or "").strip():
            problems.append(f"{where}: a stem must name the instrument it isolates")

    size = asset.get("bytes")
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        problems.append(f"{where}: bytes must be a positive whole number, not {size!r}")

    digest = asset.get("sha256")
    # Optional, but a malformed one is a manifest bug rather than something to
    # quietly drop: the hash is the strongest retry signal the server has, and
    # a wrong one silently costs a re-upload of every take on every resume.
    if digest is not None and not HEX_SHA256.match(str(digest)):
        problems.append(f"{where}: sha256 {digest!r} is not a 64-character hex digest")
    return problems


def contract_problems(event, takes):
    """Everything the ingest schemas require that a manifest can lack.

    The server enforces all of this, but only once the event is declared and
    the takes are going in one at a time, and it names one failing field per
    response. A manifest that cannot be ingested should say so whole, before
    anything on the server has moved -- the same reason `verify_assets` runs
    up front.
    """
    problems = []

    if event.get("kind") not in EVENT_KINDS:
        problems.append(
            f"the session kind is {event.get('kind')!r}, not one of "
            + ", ".join(EVENT_KINDS))
    if held_at(event) is None:
        problems.append(
            f"the session date {event.get('heldAt')!r} is not an ISO-8601 "
            "timestamp with a UTC offset")

    for index, take in enumerate(takes, 1):
        where = f"take {index}"
        if not take.get("clientRef"):
            problems.append(f"{where} has no region GUID to identify it by")
        # The server requires a title: a take nobody named cannot be ingested,
        # and creating a stub song called nothing is worse than stopping.
        if not (take.get("song") or "").strip():
            problems.append(f"{where} has no song")
        if recorded_at(event, take) is None:
            problems.append(f"{where} has no time it was recorded at")
        # A slug the server will not accept, and one the vocabulary check
        # cannot report: it collects slugs into a set and drops falsy ones, so
        # a blank sails through every guard and 422s mid-run, after earlier
        # takes are already declared and published.
        for slug in take.get("instruments", []):
            if not str(slug or "").strip():
                problems.append(
                    f"{where} lists a blank instrument, which the server rejects "
                    f"(its instruments: {take.get('instruments')})")
                break

        assets = take.get("assets") or []
        if not assets:
            problems.append(f"{where} rendered no files")
        for asset in assets:
            problems.extend(_asset_problems(asset, f"{where} {asset.get('kind')}"))

    return problems


def verify_assets(take, base_dir):
    """Checks each asset is on disk and unchanged since the manifest was written.

    A manifest can outlive its files -- a folder gets moved, a render is
    interrupted, a disk fills. Declaring an asset and then failing to upload it
    leaves a take stuck in `uploading` on the server, so the check happens
    before anything is declared.
    """
    problems = []
    for asset in take.get("assets", []):
        path = Path(asset.get("path", ""))
        if not path.is_absolute():
            path = base_dir / path
        if not path.exists():
            problems.append(f"{asset.get('kind')}: missing {path}")
            continue
        size = path.stat().st_size
        if asset.get("bytes") and size != asset["bytes"]:
            problems.append(
                f"{asset.get('kind')}: {path.name} is {size} bytes, manifest says {asset['bytes']}"
            )
        asset["_resolved"] = str(path)
    return problems


def build_take_payload(event, take):
    assets = []
    for asset in take.get("assets", []):
        entry = {
            "kind": asset["kind"],
            "tier": asset.get("tier", "lossy"),
            "format": asset.get("format"),
            "bytes": asset.get("bytes"),
            "sha256": asset.get("sha256"),
        }
        for optional in ("instrument", "durationMs", "sampleRate", "channels"):
            if asset.get(optional) is not None:
                entry[optional] = asset[optional]
        assets.append(entry)

    return {
        "clientRef": take["clientRef"],
        "eventClientRef": event["clientRef"],
        "song": {
            # A reference to the SONG, not to this take of it. Sending the
            # region GUID here made contract §6's first resolution case
            # unreachable: a GUID belongs to one take and can never match on a
            # later ingest, so every take fell through to the title match and
            # left another dead alias behind it -- two takes of one tune
            # produced two aliases on the first real push. Derived from the
            # title because the songs list carries no stable id of its own;
            # the server normalises aliases, so case and diacritics do not
            # split one song into two.
            "externalRef": "reaper:song:" + (take.get("song") or "").strip(),
            "title": take.get("song"),
            "createIfMissing": True,
        },
        "recordedAt": recorded_at(event, take),
        "durationMs": take.get("durationMs"),
        # Nullable but min-length-1 where present, so a blank label has to go
        # as null rather than as "".
        "label": (take.get("label") or "").strip() or None,
        "instruments": take.get("instruments", []),
        "assets": assets,
    }


# --------------------------------------------------------------------- upload


def upload_session(manifest_path, client, publish=True, dry_run=False, log=print,
                   progress_mode="auto", update_metadata=False):
    manifest = json.loads(Path(manifest_path).read_text())
    base_dir = Path(manifest_path).parent
    event = manifest["event"]
    takes = manifest.get("takes", [])

    if not event.get("clientRef"):
        raise IngestError("the manifest has no session identifier")

    # Unknown slugs are rejected with 422 by design, so the vocabulary is
    # checked once up front rather than discovered take by take.
    problems = contract_problems(event, takes)
    if problems:
        raise IngestError("the manifest cannot be ingested as it stands:\n  "
                          + "\n  ".join(problems))

    # None means "not asked" (a dry run contacts nothing); an empty SET means
    # the server genuinely has no vocabulary yet, which is a hard stop rather
    # than nothing to check -- testing the set's truthiness skipped the guard
    # entirely against a blank server and let every take earn its own 422.
    vocabulary = None if dry_run else client.instruments()
    if vocabulary is not None:
        accepted = set(vocabulary).union(*vocabulary.values())
        # The server validates every slug an asset names, not just the take's
        # own instrument list -- a stem's, and a peaks asset's, which says
        # which source that waveform describes. Checking only the list let an
        # unknown one through to be rejected a take at a time.
        used = {
            i
            for take in takes
            for i in list(take.get("instruments", []))
            + [a.get("instrument") for a in take.get("assets", [])
               if a.get("kind") in ("stem", "peaks")]
            if i
        }
        unknown = sorted(used - accepted)
        if unknown and not vocabulary:
            raise IngestError(
                "the server has no instrument vocabulary yet, so none of these "
                "slugs can be accepted: " + ", ".join(unknown)
                + "\nAn admin has to add them first -- ingest cannot create "
                "instruments, by design."
            )
        if unknown:
            raise IngestError(
                "these instrument slugs are not in the server's vocabulary: "
                + ", ".join(unknown)
                + "\nEdit the track mapping in config/settings.json to use: "
                + ", ".join(
                    f"{slug} (also: {', '.join(sorted(aliases))})" if aliases else slug
                    for slug, aliases in sorted(vocabulary.items())
                )
            )

    problems = []
    for take in takes:
        problems.extend(verify_assets(take, base_dir))
    if problems:
        raise IngestError("the manifest does not match what is on disk:\n  " + "\n  ".join(problems))

    if dry_run:
        log(f"Would declare event {event['clientRef']} ({event.get('label')})")
        for take in takes:
            names = ", ".join(a["kind"] for a in take.get("assets", []))
            log(f"  {take.get('song')} - {take.get('label')}: {names}")
        return {"takes": len(takes), "uploaded": 0, "skipped": 0, "dryRun": True}

    result = client.declare_event(
        {
            "clientRef": event["clientRef"],
            # Off unless asked: a re-post is a lookup, and a run over an old
            # session must not quietly revert something corrected in the
            # library. On, the whole record applies -- a field cleared here is
            # cleared there.
            "updateMetadata": update_metadata,
            "kind": event.get("kind", "rehearsal"),
            "heldAt": event.get("heldAt"),
            "venue": event.get("venue"),
            # The manifest calls it `label`; the contract calls it `title`.
            # Without the fallback the name of every session was dropped on
            # the floor, since nothing upstream ever writes `title`.
            "title": event.get("title") or event.get("label"),
            "notes": event.get("notes"),
        }
    )
    if result.get("created"):
        state = "created"
    elif result.get("updated"):
        state = "already known, metadata updated"
    else:
        state = "already known"
    log(f"Event {state}: {result.get('eventId')}")

    # Sized from what the server has not got yet is impossible to know before
    # declaring, so the bar is sized from the whole session and skipped assets
    # simply never advance it. A resumed run therefore finishes short of 100%,
    # which is honest: that is how much was actually sent.
    progress = Progress(
        sum(a.get("bytes") or 0 for t in takes for a in t.get("assets", [])),
        len(takes), mode=progress_mode)

    uploaded = skipped = 0
    for index, take in enumerate(takes, 1):
        progress.take_started(index, f"{take.get('song')} - {take.get('label')}")
        payload = build_take_payload(event, take)
        declared = client.declare_take(payload)
        take_id = declared["takeId"]

        by_path = {}
        for asset in take.get("assets", []):
            key = (asset["kind"], asset.get("instrument"))
            by_path[key] = (asset["_resolved"], asset.get("bytes") or 0)

        pending = declared.get("uploads", [])
        # URLs live an hour, and a take with a dozen stems on a domestic uplink
        # can outlive more than one of them. The old fixed pair of rounds meant
        # a third expiry silently left files unsent, surfacing only as
        # `assets_incomplete` at commit; the cap is now high enough that a slow
        # push finishes and low enough that a server handing back dead URLs
        # stops rather than spinning.
        for refreshes in range(MAX_URL_REFRESHES + 1):
            still_pending = []
            for slot in pending:
                if slot.get("status") == "ready" or not slot.get("url"):
                    skipped += 1
                    continue
                path, declared_bytes = by_path.get(
                    (slot.get("kind"), slot.get("instrument")), (None, 0))
                if not path:
                    raise IngestError(
                        f"the server asked for an asset the manifest does not have: "
                        f"{slot.get('kind')} {slot.get('instrument') or ''}"
                    )
                # Where the bar cannot draw, a line per file is the right
                # granularity: it is the only sign of life a log gets, and a
                # session of several hundred files stays readable.
                if not progress.enabled:
                    # The manifest's own figure, not a fresh stat: stat-ing a
                    # file that has just vanished raises the exact error
                    # `put_bytes` exists to report in readable words.
                    log(f"    sending {Path(path).name} ({human_bytes(declared_bytes)})")
                if client.put_bytes(slot["url"], slot.get("headers"), path,
                                    on_progress=progress.advance):
                    uploaded += 1
                else:
                    still_pending.append(slot)

            if not still_pending:
                break
            if refreshes == MAX_URL_REFRESHES:
                raise IngestError(
                    f"{len(still_pending)} uploads for {take.get('song')} - "
                    f"{take.get('label')} still expiring after "
                    f"{MAX_URL_REFRESHES} refreshes; giving up rather than looping"
                )
            # Expired presigned URLs. Documented as normal operation on a slow
            # uplink, not an error path.
            progress.done_with_all()
            log(f"  refreshing {len(still_pending)} expired upload URLs")
            pending = client.refresh_uploads(take_id).get("uploads", [])

        committed = client.commit(take_id, publish)
        # The bar is cleared before each line so the two never interleave on
        # one row.
        progress.done_with_all()
        log(f"  {take.get('song')} - {take.get('label')}: {committed.get('state')}")

    progress.done_with_all()
    return {"takes": len(takes), "uploaded": uploaded, "skipped": skipped}


DEFAULT_CONFIG = Path(__file__).resolve().parents[2] / "config" / "settings.json"


def load_settings(path):
    """The `ingest` block of the bridge's settings, or an empty one.

    A missing or unreadable settings file is not an error here: every value it
    holds has a command-line or environment equivalent, and saying so when one
    is actually missing beats refusing to start over a file the operator may
    deliberately not have.
    """
    try:
        settings = json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    block = settings.get("ingest")
    return block if isinstance(block, dict) else {}


def warn_if_readable(path, log=lambda m: print(m, file=sys.stderr)):
    """Says so when a file holding a token is readable by anyone else.

    Storing the token beats retyping it, but a 644 settings file hands it to
    every process running as any user on the machine. Advisory only -- the
    file is the operator's to chmod, and refusing to run over it would be
    worse than saying so.
    """
    try:
        mode = os.stat(path).st_mode
    except OSError:
        return
    if mode & 0o077:
        log(f"warning: {path} holds a token and is readable by other users.\n"
            f"         chmod 600 {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--api", help="base URL, e.g. https://host/api/ingest/v1 "
                                      "(default: ingest.api in the settings file)")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG),
                        help="settings file holding the ingest block "
                             f"(default: {DEFAULT_CONFIG})")
    parser.add_argument("--no-publish", action="store_true",
                        help="leave takes unpublished for review")
    parser.add_argument("--dry-run", action="store_true",
                        help="check the manifest and files, contact nothing")
    parser.add_argument("--update-metadata", action="store_true",
                        help="correct the library's kind, title, date, venue and notes "
                             "for this session from the manifest, rather than leaving "
                             "whatever was sent first")
    parser.add_argument("--progress", choices=("auto", "always", "never"), default="auto",
                        help="the upload bar: auto draws it only to a terminal, "
                             "always forces it on where one is not detected")
    args = parser.parse_args()

    settings = load_settings(args.config)

    api = args.api or settings.get("api") or ""
    if not api:
        print("No ingest API URL.\n"
              f"Set ingest.api in {args.config}, or pass --api.", file=sys.stderr)
        return 2

    # The environment wins so a one-off push at a different server, or a CI
    # run with no settings file at all, needs no edit to a checked-out file.
    token = os.environ.get("REAPERTOIRE_TOKEN") or settings.get("token") or ""
    if token and settings.get("token") and not os.environ.get("REAPERTOIRE_TOKEN"):
        warn_if_readable(args.config)
    if not token and not args.dry_run:
        print("No ingest token.\n"
              "Issue one in the bandplate admin UI (/admin/tokens, scope "
              "ingest:write), then either\n"
              f'  set "token" in the ingest block of {args.config}\n'
              "  or export REAPERTOIRE_TOKEN=bpk_...", file=sys.stderr)
        return 2

    try:
        summary = upload_session(
            args.manifest, Client(api, token),
            publish=not args.no_publish, dry_run=args.dry_run,
            progress_mode=args.progress, update_metadata=args.update_metadata,
        )
    except IngestError as error:
        print(str(error), file=sys.stderr)
        return 1

    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
