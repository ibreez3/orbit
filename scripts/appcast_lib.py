import re
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import urlsplit
from xml.sax.saxutils import escape, quoteattr


STABLE_TAG_RE = re.compile(r"v(\d+)\.(\d+)\.(\d+)")
PREVIEW_TAG_RE = re.compile(r"v(\d+)\.(\d+)\.(\d+)(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?")
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def parse_stable_tag(tag: str) -> tuple[int, int, int]:
    match = STABLE_TAG_RE.fullmatch(tag)
    if not match:
        raise ValueError(f"Expected stable tag vX.Y.Z, got {tag!r}")
    return tuple(int(part) for part in match.groups())


def parse_release_tag(tag: str, allow_preview: bool = False) -> tuple[int, int, int]:
    pattern = PREVIEW_TAG_RE if allow_preview else STABLE_TAG_RE
    match = pattern.fullmatch(tag)
    if not match:
        expected = "vX.Y.Z or vX.Y.Z-suffix" if allow_preview else "vX.Y.Z"
        raise ValueError(f"Expected tag {expected}, got {tag!r}")
    return tuple(int(part) for part in match.groups()[:3])


def sanitize_notes(markdown: str) -> str:
    normalized = markdown.replace("\r\n", "\n").replace("\r", "\n")
    valid = "".join(char for char in normalized if (
        char in "\t\n" or "\x20" <= char <= "\ud7ff"
        or "\ue000" <= char <= "\ufffd" or "\U00010000" <= char <= "\U0010ffff"
    ))
    # sign_update 用这个精确标记截断旧签名块；出现在更新说明里会破坏签名后的 feed。
    valid = valid.replace("<!-- sparkle-signatures:\n", "<!-- sparkle-signatures :\n")
    return valid.strip().replace("]]>", "]]]]><![CDATA[>")


def _read_xml(path):
    text = Path(path).read_text(encoding="utf-8")
    end = text.rfind("</rss>")
    if end < 0:
        raise ValueError("Appcast is missing </rss>")
    try:
        root = ET.fromstring(text[:end + len("</rss>")])
    except ET.ParseError as error:
        raise ValueError(f"Invalid appcast XML: {error}") from error
    if root.tag != "rss" or root.find("channel") is None:
        raise ValueError("Appcast must contain rss/channel")
    return root, text[end + len("</rss>"):]


def _positive_integer(value, name):
    if not re.fullmatch(r"[0-9]+", str(value)) or int(value) <= 0:
        raise ValueError(f"{name} must be a positive integer")
    return int(value)


def _download_tag(url):
    match = re.search(r"/download/([^/]+)/[^/]+$", urlsplit(url).path)
    if not match:
        raise ValueError("Enclosure URL must contain /download/{tag}/{asset}")
    return match.group(1)


def parse_existing_appcast(path) -> dict:
    if not Path(path).exists():
        return dict(build=None, tag=None, pub_date=None)
    root, _ = _read_xml(path)
    releases = []
    for item in root.findall("channel/item"):
        enclosure = item.find("enclosure")
        if enclosure is None:
            raise ValueError("Existing appcast item is missing an enclosure")
        build = item.findtext(f"{{{SPARKLE_NS}}}version") or enclosure.get(f"{{{SPARKLE_NS}}}version")
        releases.append(dict(
            build=_positive_integer(build, "Existing build"),
            tag=_download_tag(enclosure.get("url", "")),
            pub_date=item.findtext("pubDate"),
        ))
    if not releases:
        raise ValueError("Existing appcast has no release items")
    return max(releases, key=lambda release: release["build"])


def validate_release(*, existing, tag, version, build, notes, url, signature, length,
                     allow_empty_notes=False, allow_preview=False) -> None:
    parse_release_tag(tag, allow_preview=allow_preview)
    if version != tag[1:]:
        raise ValueError("Version must match the stable tag")
    build_number = _positive_integer(build, "Build")
    _positive_integer(length, "Enclosure length")
    if not sanitize_notes(notes) and not allow_empty_notes:
        raise ValueError("Stable release notes must not be empty")
    if not signature.strip():
        raise ValueError("Enclosure signature must not be empty")
    if urlsplit(url).scheme != "https" or not urlsplit(url).netloc or _download_tag(url) != tag:
        raise ValueError("Enclosure URL must be HTTPS and match the release tag")
    previous = existing.get("build")
    if previous is not None:
        if build_number < previous:
            raise ValueError(f"Build {build_number} is older than published build {previous}")
        if build_number == previous and existing.get("tag") != tag:
            raise ValueError("Reusing a build number is only allowed for the same tag")


def render_appcast(*, tag, version, build, url, signature, length, notes,
                   full_notes_url, pub_date, minimum_system_version="13.0",
                   allow_preview=False) -> str:
    parse_release_tag(tag, allow_preview=allow_preview)
    if urlsplit(full_notes_url).scheme != "https" or not urlsplit(full_notes_url).netloc:
        raise ValueError("Full release notes URL must be HTTPS")
    attributes = dict(
        url=url,
        **{"sparkle:version": str(build), "sparkle:shortVersionString": version,
           "sparkle:minimumSystemVersion": minimum_system_version,
           "sparkle:edSignature": signature},
        length=str(length), type="application/x-apple-diskimage",
    )
    enclosure = " ".join(f"{name}={quoteattr(value)}" for name, value in attributes.items())
    return f'''<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="{SPARKLE_NS}" version="2.0">
  <channel>
    <title>Orbit Updates</title>
    <link>https://github.com/ibreez3/orbit/releases</link>
    <description>Orbit macOS stable updates</description>
    <language>zh-CN</language>
    <item>
      <title>Orbit {escape(version)}</title>
      <description sparkle:format="markdown"><![CDATA[{sanitize_notes(notes)}]]></description>
      <sparkle:fullReleaseNotesLink>{escape(full_notes_url)}</sparkle:fullReleaseNotesLink>
      <pubDate>{escape(pub_date)}</pubDate>
      <enclosure {enclosure} />
    </item>
  </channel>
</rss>
'''


def verify_appcast(path, *, tag, version, build, require_signature=False,
                   allow_preview=False) -> None:
    root, suffix = _read_xml(path)
    items = root.findall("channel/item")
    if len(items) != 1 or root.findtext("channel/title") != "Orbit Updates":
        raise ValueError("Appcast must have the Orbit Updates channel and exactly one item")
    item = items[0]
    if item.findtext("title") != f"Orbit {version}":
        raise ValueError("Item title does not match the version")
    description = item.find("description")
    if description is None or description.get(f"{{{SPARKLE_NS}}}format") != "markdown":
        raise ValueError("Appcast requires an embedded Markdown description")
    if item.find(f"{{{SPARKLE_NS}}}releaseNotesLink") is not None:
        raise ValueError("External releaseNotesLink is not allowed")
    full_link = item.findtext(f"{{{SPARKLE_NS}}}fullReleaseNotesLink", "")
    if urlsplit(full_link).scheme != "https" or not urlsplit(full_link).netloc:
        raise ValueError("Appcast requires a full release notes link")
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("Appcast requires an enclosure")
    if enclosure.get(f"{{{SPARKLE_NS}}}version") != str(build):
        raise ValueError("Enclosure build does not match")
    if enclosure.get(f"{{{SPARKLE_NS}}}shortVersionString") != version:
        raise ValueError("Enclosure version does not match")
    if not enclosure.get(f"{{{SPARKLE_NS}}}minimumSystemVersion") or not item.findtext("pubDate"):
        raise ValueError("Appcast requires minimum system version and publication date")
    validate_release(
        existing={}, tag=tag, version=version, build=build, notes=description.text or "",
        url=enclosure.get("url", ""), signature=enclosure.get(f"{{{SPARKLE_NS}}}edSignature", ""),
        length=enclosure.get("length", ""), allow_preview=allow_preview,
    )
    if require_signature and not re.search(
        r"<!--\s*sparkle-signatures:\s*edSignature:\s*\S+\s+length:\s*[0-9]+\s*-->", suffix
    ):
        raise ValueError("Appcast is missing the Sparkle signature block")
