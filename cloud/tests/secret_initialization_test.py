"""Check first-start secrets, restart stability and existing-installation imports."""
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "docker/init-secrets.sh"
SECRET_NAMES = ("POSTGRES_PASSWORD", "JWT_SECRET", "CLIENT_KEY_ENCRYPTION_SECRET")


class SecretInitializationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="aijiance-secrets-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.secrets = self.root / "secrets"
        self.database = self.root / "postgres"
        self.database.mkdir()

    def initialize(self, **overrides):
        environment = {key: value for key, value in os.environ.items() if key not in SECRET_NAMES}
        environment.update(SECRET_DIR=str(self.secrets), POSTGRES_DATA_DIR=str(self.database), **overrides)
        return subprocess.run(["sh", str(SCRIPT)], env=environment, capture_output=True, text=True)

    def values(self):
        return {name: (self.secrets / name.lower()).read_text() for name in SECRET_NAMES}

    def test_first_start_and_restarts_keep_independent_private_secrets(self):
        self.assertEqual(self.initialize().returncode, 0)
        original = self.values()
        self.assertEqual(len(set(original.values())), 3)
        for name, value in original.items():
            self.assertRegex(value, r"^[0-9a-f]{64}$")
            self.assertEqual((self.secrets / name.lower()).stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.secrets.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.initialize().returncode, 0)
        self.assertEqual(self.values(), original)

    def test_concurrent_first_starts_share_the_persisted_values(self):
        with ThreadPoolExecutor(max_workers=4) as executor:
            results = list(executor.map(lambda _: self.initialize(), range(4)))
        self.assertTrue(all(result.returncode == 0 for result in results))
        for value in self.values().values():
            self.assertRegex(value, r"^[0-9a-f]{64}$")

    def test_existing_database_and_legacy_encryption_keep_original_credentials(self):
        (self.database / "PG_VERSION").write_text("16")
        password = "a password with ' \\ : @ / % $"
        jwt = "previous-installation-jwt-secret"
        result = self.initialize(POSTGRES_PASSWORD=password, JWT_SECRET=jwt)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.values(), dict(POSTGRES_PASSWORD=password, JWT_SECRET=jwt, CLIENT_KEY_ENCRYPTION_SECRET=jwt))
        self.assertNotIn(password, result.stdout + result.stderr)
        self.assertNotIn(jwt, result.stdout + result.stderr)
        self.assertEqual(self.initialize().returncode, 0)
        self.assertEqual(self.values()["POSTGRES_PASSWORD"], password)
        self.assertEqual(self.values()["CLIENT_KEY_ENCRYPTION_SECRET"], jwt)

    def test_explicit_encryption_key_is_preserved(self):
        supplied = dict(zip(SECRET_NAMES, ("existing-database-password", "existing-jwt", "existing-encryption-key")))
        self.assertEqual(self.initialize(**supplied).returncode, 0)
        self.assertEqual(self.values(), supplied)
        self.assertEqual(self.initialize().returncode, 0)
        self.assertEqual(self.values(), supplied)

    def test_existing_database_without_password_is_left_untouched(self):
        version = self.database / "PG_VERSION"
        version.write_text("16")
        result = self.initialize()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("恢复 POSTGRES_PASSWORD", result.stderr)
        self.assertEqual(version.read_text(), "16")
        self.assertFalse((self.secrets / "postgres_password").exists())

    def test_corrupt_persisted_secret_is_not_replaced(self):
        self.assertEqual(self.initialize().returncode, 0)
        key = self.secrets / "jwt_secret"
        key.write_text("")
        result = self.initialize()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(key.read_text(), "")

    def test_existing_database_without_original_signing_key_is_left_untouched(self):
        (self.database / "PG_VERSION").write_text("16")
        result = self.initialize(POSTGRES_PASSWORD="existing-password")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("恢复 JWT_SECRET", result.stderr)
        self.assertFalse((self.secrets / "jwt_secret").exists())


if __name__ == "__main__":
    unittest.main()
