"""Verify retries never publish an incomplete or unverified native library."""
import hashlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

from bootstrap_duckdb import download_archive


class DownloadTests(unittest.TestCase):
    def test_transient_error_retries_then_commits_verified_file(self):
        payload = b"verified native library fixture"
        digest = hashlib.sha256(payload).hexdigest()
        failure = urllib.error.HTTPError("https://example.test/library", 503, "temporary", {}, None)
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "library.zip"
            with patch("urllib.request.urlopen", side_effect=[failure, io.BytesIO(payload)]) as request, patch("time.sleep"):
                download_archive("https://example.test/library", archive, digest)
            self.assertEqual(request.call_count, 2)
            self.assertEqual(archive.read_bytes(), payload)
            self.assertFalse(archive.with_suffix(".download").exists())

    def test_invalid_download_is_never_extracted_or_kept(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "library.zip"
            with patch("urllib.request.urlopen", side_effect=lambda *args, **kwargs: io.BytesIO(b"corrupted")), patch("time.sleep"):
                with self.assertRaises(SystemExit):
                    download_archive("https://example.test/library", archive, "0" * 64)
            self.assertFalse(archive.exists())
            self.assertFalse(archive.with_suffix(".download").exists())


if __name__ == "__main__":
    unittest.main()
