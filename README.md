# Vista

A knowledge browsing, reading, and editing interface over an
[Ark](../ark) server. Two things, done simply:

- **Briefs** — read the PDFs an agent produces, grouped into one or more
  *briefings* (Policy Briefs, Personal Briefs, …), sortable by date or name.
- **Notes** — capture, browse, and edit markdown notes in the agent's
  workspace, so an agent can pick them up later.

No AI in Vista itself. It is a direct interface onto files an agent owns.

## Why there is a server

Ark's workspace filesystem API would almost be enough on its own, but three
things make a small server in the middle necessary:

1. **Ark has no per-user identity.** One `auth_secret` grants read/write to
   every agent workspace on the server. Vista holds that token, encrypted at
   rest, and never sends it to a client. Vista users authenticate against
   Vista.
2. **Ark sends no CORS headers**, so a browser can't call it directly.
3. **Briefs and notes are conventions over a directory tree.** Shaping them
   in one place means the web and iOS clients see an identical model.

```
iOS / web  ──►  Vista (accounts, sessions)  ──►  Ark  ──►  agent workspace
                 holds the Ark token                        briefs/, notes/
```

## Everything runs in Docker

Nothing is installed on the host.

```bash
cp .env.example .env
docker compose run --rm --no-deps vista python -m vista secret   # paste into .env
docker compose up vista web
```

- API: <http://127.0.0.1:8800> (docs at `/api/docs`)
- Web: <http://127.0.0.1:5173>

Set `VISTA_API_PORT` / `VISTA_WEB_PORT` in `.env` if those ports are taken.

### Reaching Vista from another device

Both services publish on loopback by default. To use Vista from a phone or
tablet — over Tailscale, say — set the interface to publish on:

```bash
VISTA_BIND=0.0.0.0        # every interface
VISTA_BIND=100.x.y.z      # or one address, e.g. this machine's Tailscale IP
```

`0.0.0.0` also exposes Vista to whatever local network the machine is on, not
only to the VPN; binding to the Tailscale address alone avoids that.

Then add the origins you actually load the web client from to
`VISTA_CORS_ORIGINS`, and the hostnames to `VITE_ALLOWED_HOSTS` (Vite's dev
server answers unknown `Host` headers with a 403):

```bash
VISTA_CORS_ORIGINS=http://localhost:5173,http://my-host.tailnet.ts.net:5173
VITE_ALLOWED_HOSTS=localhost,127.0.0.1,web,my-host.tailnet.ts.net
```

Leave `VITE_API_BASE` blank and the web client derives the API address from
whatever host served the page, so one build works over loopback and over
Tailscale without rebuilding. The iOS app asks for the server address at
sign-in, so it needs nothing here.

> `VISTA_SECRET_KEY` signs sessions **and** derives the key encrypting stored
> Ark tokens. Changing it logs everyone out and makes saved Ark tokens
> unreadable — they have to be re-entered. Back it up.

## Provisioning an account

There is no self-service signup: an account grants access to an Ark token
that can read and write a whole agent workspace, so accounts are created
deliberately.

```bash
docker compose exec vista python -m vista users add you@example.com
```

That is the only required CLI step. Sign in and the app opens on **Settings**,
where you configure the rest:

- **Ark server** — URL, agent, and auth token, with a *Test connection* button
  that checks the credentials before you commit to them. The token is stored
  encrypted and is never sent back to the browser; the field shows only
  whether one exists.
- **Notes folder** — where notes are read and written.
- **Brief locations** — add, rename, re-point, reorder, and remove briefings.
  Each becomes its own screen in the sidebar.

Paths are relative to the agent's workspace root, and *Browse…* opens a picker
over the live workspace so you don't have to type (or mistype) them. Removing a
brief location only unconfigures it — no files are deleted.

The same settings are still available from the CLI, which is handy for
scripted setup:

```bash
C="docker compose exec vista python -m vista"

$C connect you@example.com \
    --url http://ark:7777 --token <ark auth_secret> \
    --agent scribe --notes-dir notes
$C briefings add you@example.com --name "Policy Briefs" --path briefs/ai_policy/output
$C users list
```

## How briefs are read

A brief location is a directory; briefs are found **nested beneath** it
(depth-limited, `VISTA_MAX_BRIEF_DEPTH`). One brief usually exists as several
files, which Vista collapses into a single entry:

```
AI_Policy_Brief-2026-06-15.pdf             the brief
AI_Policy_Brief-2026-06-15.md              the markdown it was rendered from
AI_Policy_Brief-2026-06-15.annotated.pdf   Apple Markup saved back by Vista
```

**Dates come from the filename**, not the file's mtime — copying or checking
out a brief tree rewrites mtimes, but the name survives. These are all
recognised, with mtime as the fallback (flagged with `~` in the UI):

```
Personal_Family_Brief-2026-06-01    daily_brief_2026-06-03
2026-06-09-daily-brief              notes_20260612
```

When every brief in a briefing shares a title (the usual case for a daily
series), the list leads with the date instead of repeating the title.

### Markup is non-destructive

Marking up a brief on iPad writes `<name>.annotated.pdf` **beside** the
original. The source brief is never modified, so a sync bug cannot destroy
it. Vista opens the marked-up copy by default, offers "Show original", and
`DELETE /api/briefings/{id}/annotation` discards the markup.

## Appearance

Both clients offer **System / Light / Dark**, defaulting to System — which
doesn't pick a side, it declines to override, so Vista follows the device
including its automatic evening switch.

The choice is stored per device (`localStorage` on the web, `UserDefaults` on
iOS), not on the account: a laptop in light and a phone in dark is a normal way
to work, and appearance belongs to the thing you're reading on rather than to
who you are.

## Notes

A flat directory of `.md` / `.txt` files. A note is a file, its name is its
identity, its title is the filename stem. No database, no index, no
Vista-side metadata — a note Vista writes is immediately a file the agent can
read, and a file the agent writes is immediately a note. Name collisions
suffix as `note.md`, `note-2.md`, matching Ark's own upload convention.

## Layout

```
server/           FastAPI app — accounts, Ark proxying, brief/note shaping
  vista/ark.py      client for Ark's workspace filesystem API
  vista/briefs.py   discovery, variant collapsing, date extraction
  vista/notes.py    flat-directory note operations
  vista/security.py scrypt passwords, JWT sessions, Fernet-encrypted Ark tokens
  vista/cli.py      account provisioning
web/              React + TypeScript client (Vite)
ios/              SwiftUI app for iPhone and iPad
```

## Tests

The suite runs against a **real Ark server** in a container, not a mock, so
the assumptions Vista makes about Ark are actually verified — millisecond
mtimes in listings, refused path traversal, and Range/`206` responses on
downloads (without which a PDF viewer can't page into a large brief).

```bash
docker compose -f docker-compose.test.yml run --rm tests
docker compose -f docker-compose.test.yml down -v
```

Ark is built from a sibling checkout of the `ark` repo; point `ARK_REPO`
elsewhere if yours lives somewhere else.

## Status

- [x] Vista server — accounts, Ark connection, briefs, notes, annotations
- [x] Web client — briefs, PDF reader, notes with autosave, settings
- [x] iOS app (iPhone + iPad) with Apple Markup on briefs — see [ios/README.md](ios/README.md)

## Known gaps

- Both clients download a whole PDF before displaying it rather than using the
  API's Range support: the browser would need the session token in a URL to do
  otherwise, and PDFKit wants a file on disk anyway. Range still works and is
  tested — it just isn't on the critical path today. In the browser this shows
  up as a blob id instead of a filename in the PDF viewer's title bar.
- Ark's `PUT` is a whole-file write with no compare-and-swap, so two clients
  editing one note last-write-wins.
- Changing a password is still CLI-only (`vista users passwd`); the settings
  screen covers configuration, not credentials.
