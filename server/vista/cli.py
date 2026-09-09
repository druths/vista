"""Administrative CLI.

Vista has no self-service signup — accounts are provisioned here, because
creating one means handing out access to an Ark bearer token that can read
and write an entire agent workspace.

    python -m vista secret
    python -m vista users add derek@example.com
    python -m vista connect derek@example.com --url http://ark:7777 \
        --token <ark auth_secret> --agent scribe --notes-dir notes
    python -m vista briefings add derek@example.com \
        --name "Policy Briefs" --path briefs/ai_policy/output
    python -m vista serve
"""

from __future__ import annotations

import argparse
import getpass
import secrets
import sys

from . import config, db, security


def _fail(message: str) -> int:
    print(f"error: {message}", file=sys.stderr)
    return 1


def _prompt_password() -> str:
    first = getpass.getpass("Password: ")
    if not first:
        raise SystemExit("error: password cannot be empty")
    if first != getpass.getpass("Confirm: "):
        raise SystemExit("error: passwords did not match")
    return first


def _user_or_fail(conn, email: str):
    row = db.get_user_by_email(conn, email)
    if row is None:
        raise SystemExit(f"error: no such user: {email}")
    return row


# --- commands --------------------------------------------------------------


def cmd_secret(_: argparse.Namespace) -> int:
    print(secrets.token_hex(32))
    return 0


def cmd_init(_: argparse.Namespace) -> int:
    db.init()
    print(f"initialized {config.DB_PATH}")
    return 0


def cmd_users_add(args: argparse.Namespace) -> int:
    password = args.password or _prompt_password()
    with db.session() as conn:
        db.init(conn)
        if db.get_user_by_email(conn, args.email):
            return _fail(f"user already exists: {args.email}")
        user_id = db.create_user(
            conn,
            email=args.email,
            password_hash=security.hash_password(password),
            display_name=args.name or "",
        )
    print(f"created user {args.email} (id {user_id})")
    print("next: python -m vista connect", args.email, "--url ... --token ... --agent ...")
    return 0


def cmd_users_list(_: argparse.Namespace) -> int:
    with db.session() as conn:
        db.init(conn)
        rows = db.list_users(conn)
        if not rows:
            print("no users yet — create one with: python -m vista users add <email>")
            return 0
        for row in rows:
            briefings = db.list_briefings(conn, int(row["id"]))
            connected = "connected" if row["ark_base_url"] else "NOT CONNECTED"
            target = (
                f"{row['ark_base_url']} agent={row['ark_agent']}"
                if row["ark_base_url"]
                else "-"
            )
            print(f"[{row['id']}] {row['email']}  {connected}  {target}")
            print(f"      notes: {row['notes_dir'] or 'notes'}   briefings: {len(briefings)}")
            for b in briefings:
                print(f"        ({b['id']}) {b['name']} -> {b['path']}")
    return 0


def cmd_users_passwd(args: argparse.Namespace) -> int:
    password = args.password or _prompt_password()
    with db.session() as conn:
        row = _user_or_fail(conn, args.email)
        db.set_password(conn, int(row["id"]), security.hash_password(password))
    print(f"password updated for {args.email}")
    return 0


def cmd_users_rm(args: argparse.Namespace) -> int:
    with db.session() as conn:
        row = _user_or_fail(conn, args.email)
        db.delete_user(conn, int(row["id"]))
    print(f"deleted {args.email}")
    return 0


def cmd_connect(args: argparse.Namespace) -> int:
    token = args.token or getpass.getpass("Ark auth_secret: ")
    if not token:
        return _fail("an Ark token is required")
    with db.session() as conn:
        row = _user_or_fail(conn, args.email)
        db.set_ark_connection(
            conn,
            int(row["id"]),
            base_url=args.url,
            token_enc=security.encrypt_secret(token),
            agent=args.agent,
            notes_dir=args.notes_dir,
        )
    print(f"{args.email} -> {args.url.rstrip('/')} agent={args.agent} notes={args.notes_dir}")
    print("the Ark token is encrypted at rest with VISTA_SECRET_KEY")
    return 0


def cmd_briefings_add(args: argparse.Namespace) -> int:
    with db.session() as conn:
        row = _user_or_fail(conn, args.email)
        bid = db.add_briefing(conn, int(row["id"]), name=args.name, path=args.path)
    print(f"added briefing ({bid}) {args.name!r} -> {args.path}")
    return 0


def cmd_briefings_rm(args: argparse.Namespace) -> int:
    with db.session() as conn:
        row = _user_or_fail(conn, args.email)
        if not db.remove_briefing(conn, int(row["id"]), args.briefing_id):
            return _fail(f"no briefing {args.briefing_id} for {args.email}")
    print(f"removed briefing {args.briefing_id}")
    return 0


def cmd_serve(args: argparse.Namespace) -> int:
    try:
        config.require_secret_key()
    except config.ConfigError as exc:
        return _fail(str(exc))
    import uvicorn

    db.init()
    uvicorn.run("vista.app:app", host=args.host, port=args.port, reload=args.reload)
    return 0


# --- parser ----------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="vista", description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("secret", help="generate a value for VISTA_SECRET_KEY").set_defaults(
        func=cmd_secret
    )
    sub.add_parser("init", help="create the Vista database").set_defaults(func=cmd_init)

    users = sub.add_parser("users", help="manage accounts").add_subparsers(
        dest="subcommand", required=True
    )
    add = users.add_parser("add", help="create an account")
    add.add_argument("email")
    add.add_argument("--name", default="", help="display name")
    add.add_argument("--password", help="skip the interactive prompt (avoid in shared shells)")
    add.set_defaults(func=cmd_users_add)

    users.add_parser("list", help="list accounts and their configuration").set_defaults(
        func=cmd_users_list
    )

    passwd = users.add_parser("passwd", help="change a password")
    passwd.add_argument("email")
    passwd.add_argument("--password")
    passwd.set_defaults(func=cmd_users_passwd)

    rm = users.add_parser("rm", help="delete an account")
    rm.add_argument("email")
    rm.set_defaults(func=cmd_users_rm)

    connect = sub.add_parser("connect", help="point an account at an Ark server")
    connect.add_argument("email")
    connect.add_argument("--url", required=True, help="Ark base URL, e.g. http://ark:7777")
    connect.add_argument("--token", help="Ark auth_secret (prompted if omitted)")
    connect.add_argument("--agent", required=True, help="Ark agent name, e.g. scribe")
    connect.add_argument("--notes-dir", default="notes", help="workspace-relative notes directory")
    connect.set_defaults(func=cmd_connect)

    briefings = sub.add_parser("briefings", help="manage brief locations").add_subparsers(
        dest="subcommand", required=True
    )
    badd = briefings.add_parser("add", help="add a brief location")
    badd.add_argument("email")
    badd.add_argument("--name", required=True, help='display name, e.g. "Policy Briefs"')
    badd.add_argument("--path", required=True, help="workspace-relative directory")
    badd.set_defaults(func=cmd_briefings_add)

    brm = briefings.add_parser("rm", help="remove a brief location")
    brm.add_argument("email")
    brm.add_argument("briefing_id", type=int)
    brm.set_defaults(func=cmd_briefings_rm)

    serve = sub.add_parser("serve", help="run the API server")
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8800)
    serve.add_argument("--reload", action="store_true")
    serve.set_defaults(func=cmd_serve)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)
