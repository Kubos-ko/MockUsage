"""Privacy audit regression tests with synthetic fixtures only."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

AUDIT = pathlib.Path(__file__).resolve().parents[1] / "scripts/audit-public.py"


class PublicAuditTests(unittest.TestCase):
    def test_bundle_rejects_home_paths_without_printing_values(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = pathlib.Path(directory) / "Demo.app"
            bundle.mkdir()
            private_path = "/" + "Users/fictional-builder/source.swift"
            (bundle / "binary").write_bytes(private_path.encode())
            result = subprocess.run([sys.executable, str(AUDIT), "--bundle", str(bundle)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("personal-home-path", result.stdout)
            self.assertNotIn(private_path, result.stdout)

    def test_private_terms_are_read_from_local_file(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = pathlib.Path(directory) / "Demo.app"
            bundle.mkdir()
            (bundle / "binary").write_text("Fictional Private Workspace")
            terms = pathlib.Path(directory) / "terms.txt"
            terms.write_text("fictional private workspace\n")
            result = subprocess.run([sys.executable, str(AUDIT), "--bundle", str(bundle), "--private-terms", str(terms)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("private-term", result.stdout)
            self.assertNotIn("Fictional Private Workspace", result.stdout)

    def test_clean_example_addresses_are_allowed(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = pathlib.Path(directory) / "Demo.app"
            bundle.mkdir()
            (bundle / "fixture").write_text("user@example.test")
            result = subprocess.run([sys.executable, str(AUDIT), "--bundle", str(bundle)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)

    def test_history_allows_only_exact_public_bot_identities(self):
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                return subprocess.run(["git", "-C", directory, *args], check=True, capture_output=True)
            git("init")
            git("config", "user.name", "GitHub")
            git("config", "user.email", "noreply" + "@github.com")
            git("commit", "--allow-empty", "-m", "Synthetic bot commit")
            command = [sys.executable, str(AUDIT), "--history"]
            result = subprocess.run(command, cwd=directory, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout)
            git("config", "user.email", "fictional-user" + "@users.noreply.github.com")
            git("commit", "--allow-empty", "-m", "Synthetic user commit")
            result = subprocess.run(command, cwd=directory, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("non-example-email", result.stdout)


if __name__ == "__main__":
    unittest.main()
