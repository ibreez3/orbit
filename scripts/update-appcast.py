import argparse
import os
import sys
import tempfile
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path

from appcast_lib import parse_existing_appcast, render_appcast, validate_release, verify_appcast


def main():
    parser = argparse.ArgumentParser(description="Generate and validate Orbit's stable appcast")
    parser.add_argument("--appcast", default="docs/appcast.xml")
    for name in ("tag", "version", "build", "url", "signature", "length", "notes-file", "full-notes-url"):
        parser.add_argument("--" + name, required=name in ("tag", "version", "build"))
    parser.add_argument("--minimum-system-version", default="13.0")
    parser.add_argument("--allow-empty-notes", action="store_true")
    parser.add_argument("--allow-preview", action="store_true")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--check", action="store_true")
    modes.add_argument("--dry-run", action="store_true")
    modes.add_argument("--verify", nargs="?", const=True, metavar="APPCAST")
    parser.add_argument("--require-signature", action="store_true")
    args = parser.parse_args()
    try:
        if args.verify:
            path = args.appcast if args.verify is True else args.verify
            verify_appcast(path, tag=args.tag, version=args.version, build=args.build,
                           require_signature=args.require_signature,
                           allow_preview=args.allow_preview)
            return
        if args.require_signature:
            parser.error("--require-signature requires --verify")
        for name in ("url", "signature", "length", "notes_file", "full_notes_url"):
            if getattr(args, name) is None:
                parser.error(f"--{name.replace('_', '-')} is required when generating an appcast")
        path = Path(args.appcast)
        existing = parse_existing_appcast(path)
        notes = Path(args.notes_file).read_text(encoding="utf-8")
        release = dict(tag=args.tag, version=args.version, build=args.build,
                       url=args.url, signature=args.signature, length=args.length, notes=notes)
        validate_release(existing=existing, allow_empty_notes=args.allow_empty_notes,
                         allow_preview=args.allow_preview, **release)
        pub_date = existing.get("pub_date") if existing.get("tag") == args.tag else None
        xml = render_appcast(
            **release, full_notes_url=args.full_notes_url,
            pub_date=pub_date or format_datetime(datetime.now(timezone.utc)),
            minimum_system_version=args.minimum_system_version,
            allow_preview=args.allow_preview,
        )
        if args.check:
            return
        if args.dry_run:
            print(xml, end="")
            return
        temporary_path = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                             prefix=f".{path.name}.", delete=False) as output:
                temporary_path = Path(output.name)
                output.write(xml)
            os.chmod(temporary_path, 0o644)
            os.replace(temporary_path, path)
        finally:
            if temporary_path is not None:
                temporary_path.unlink(missing_ok=True)
    except (ValueError, OSError) as error:
        parser.exit(1, f"appcast: {error}\n")


if __name__ == "__main__":
    main()
