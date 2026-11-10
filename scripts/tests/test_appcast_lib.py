import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from scripts.appcast_lib import (
    SPARKLE_NS,
    parse_existing_appcast,
    parse_stable_tag,
    render_appcast,
    sanitize_notes,
    validate_release,
    verify_appcast,
)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "appcast.xml"
        self.release = dict(
            tag="v0.0.12", version="0.0.12", build="13",
            url="https://github.com/ibreez3/orbit/releases/download/v0.0.12/Orbit.dmg",
            signature="TEST_SIGNATURE", length="123456", notes="### 新增\n- 关于窗口",
        )
        self.render = dict(
            **self.release,
            full_notes_url="https://github.com/ibreez3/orbit/releases/tag/v0.0.12",
            pub_date="Tue, 10 Nov 2026 00:51:21 +0000",
        )

    def write_feed(self, **changes):
        self.path.write_text(render_appcast(**(self.render | changes)), encoding="utf-8")

    def verify(self, **changes):
        verify_appcast(self.path, **(dict(tag="v0.0.12", version="0.0.12", build="13") | changes))

    def test_stable_tags(self):
        self.assertEqual(parse_stable_tag("v0.0.12"), (0, 0, 12))
        for tag in ("v0.0.12-pre.1", "v0.0.12-rc1", "0.0.12", "v0.0.12\n"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                parse_stable_tag(tag)

    def test_monotonic_build_and_same_tag_rerun(self):
        validate_release(existing={"build": 12, "tag": "v0.0.11"}, **self.release)
        validate_release(existing={"build": 13, "tag": "v0.0.12"}, **self.release)
        for existing in ({"build": 14, "tag": "v0.0.13"}, {"build": 13, "tag": "v0.0.11"}):
            with self.subTest(existing=existing), self.assertRaises(ValueError):
                validate_release(existing=existing, **self.release)

    def test_invalid_release_metadata(self):
        for change in (
            {"version": "0.0.11"}, {"build": "0"}, {"build": "1.5"},
            {"build": "-1"}, {"notes": " \n\t"}, {"notes": "\x00"},
            {"signature": ""}, {"length": "0"}, {"length": "oops"},
            {"url": "https://example.com/download/v0.0.11/Orbit.dmg"},
            {"tag": "v0.0.12-pre"},
        ):
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_release(existing={}, **(self.release | change))

    def test_notes_preserve_cdata_and_remove_illegal_xml_characters(self):
        text = " a]]>b\r\n中文\x00\x01\t<&>\ud800\ufffe "
        escaped = sanitize_notes(text)
        root = ET.fromstring(f"<description><![CDATA[{escaped}]]></description>")
        self.assertEqual(root.text, "a]]>b\n中文\t<&>")

    def test_notes_cannot_inject_sparkle_signature_marker(self):
        notes = "before\n<!-- sparkle-signatures:\nedSignature: FAKE\nlength: 1\n-->\nafter"
        sanitized = sanitize_notes(notes)
        self.assertNotIn("<!-- sparkle-signatures:\n", sanitized)
        root = ET.fromstring(f"<description><![CDATA[{sanitized}]]></description>")
        self.assertIn("<!-- sparkle-signatures :", root.text)

    def test_rendered_structure(self):
        self.write_feed(notes="a]]>b & <更新>")
        root = ET.parse(self.path).getroot()
        self.assertEqual(root.findtext("channel/title"), "Orbit Updates")
        items = root.findall("channel/item")
        self.assertEqual(len(items), 1)
        item = items[0]
        self.assertEqual(item.findtext("title"), "Orbit 0.0.12")
        self.assertIsNone(item.find(f"{{{SPARKLE_NS}}}releaseNotesLink"))
        self.assertEqual(item.find("description").get(f"{{{SPARKLE_NS}}}format"), "markdown")
        self.assertEqual(item.findtext("description"), "a]]>b & <更新>")
        self.assertEqual(item.findtext(f"{{{SPARKLE_NS}}}fullReleaseNotesLink"), self.render["full_notes_url"])
        self.assertEqual(item.find("enclosure").get(f"{{{SPARKLE_NS}}}version"), "13")
        self.verify()

    def test_parse_missing_and_existing_signed_feed(self):
        self.assertEqual(parse_existing_appcast(self.path), dict(build=None, tag=None, pub_date=None))
        self.write_feed()
        with self.path.open("a") as output:
            output.write("<!-- sparkle-signatures:\nedSignature: TEST\nlength: 123\n-->")
        self.assertEqual(parse_existing_appcast(self.path), dict(
            build=13, tag="v0.0.12", pub_date=self.render["pub_date"],
        ))
        self.verify(require_signature=True)

    def test_parse_item_level_version(self):
        self.write_feed()
        root = ET.parse(self.path).getroot()
        item = root.find("channel/item")
        del item.find("enclosure").attrib[f"{{{SPARKLE_NS}}}version"]
        ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = "13"
        ET.ElementTree(root).write(self.path, encoding="unicode")
        self.assertEqual(parse_existing_appcast(self.path)["build"], 13)

    def test_verify_rejects_missing_and_unexpected_elements(self):
        for element in ("description", f"{{{SPARKLE_NS}}}fullReleaseNotesLink"):
            with self.subTest(element=element):
                self.write_feed()
                root = ET.parse(self.path).getroot()
                item = root.find("channel/item")
                item.remove(item.find(element))
                ET.ElementTree(root).write(self.path, encoding="unicode")
                with self.assertRaises(ValueError):
                    self.verify()
        self.write_feed()
        root = ET.parse(self.path).getroot()
        ET.SubElement(root.find("channel/item"), f"{{{SPARKLE_NS}}}releaseNotesLink").text = "https://example.com"
        ET.ElementTree(root).write(self.path, encoding="unicode")
        with self.assertRaises(ValueError):
            self.verify()

    def test_verify_rejects_mismatches_and_missing_signature(self):
        self.write_feed()
        for change in ({"build": "12"}, {"version": "0.0.11"}, {"tag": "v0.0.11"}, {"require_signature": True}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.verify(**change)
        self.write_feed(notes="sparkle-signatures:\nedSignature: NOT_A_SIGNATURE")
        with self.assertRaises(ValueError):
            self.verify(require_signature=True)

    def test_malformed_existing_feed_is_not_treated_as_empty(self):
        self.path.write_text("<rss>broken", encoding="utf-8")
        with self.assertRaises(ValueError):
            parse_existing_appcast(self.path)

    def test_cli_modes_and_rerun(self):
        notes = self.path.with_suffix(".md")
        notes.write_text(self.release["notes"], encoding="utf-8")
        command = [sys.executable, str(Path(__file__).resolve().parents[1] / "update-appcast.py"),
                   "--appcast", str(self.path), "--notes-file", str(notes),
                   "--full-notes-url", self.render["full_notes_url"]]
        for key in ("tag", "version", "build", "url", "signature", "length"):
            command.extend(["--" + key, self.release[key]])
        checked = subprocess.run(command + ["--check"], capture_output=True, text=True)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertFalse(self.path.exists())
        dry = subprocess.run(command + ["--dry-run"], capture_output=True, text=True)
        self.assertEqual(dry.returncode, 0, dry.stderr)
        ET.fromstring(dry.stdout)
        self.assertFalse(self.path.exists())
        for _ in range(2):
            written = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(written.returncode, 0, written.stderr)
            self.verify()
        previous = self.path.read_bytes()
        failed = subprocess.run(command + ["--build", "12"], capture_output=True, text=True)
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(self.path.read_bytes(), previous)
