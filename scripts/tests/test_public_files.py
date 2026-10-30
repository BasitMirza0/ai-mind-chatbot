import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("guard", Path(__file__).resolve().parents[1] / "check_public_files.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class PublicationGuardTests(unittest.TestCase):
    def test_native_and_build_sources_are_in_publication_scan(self):
        for suffix in [".kt", ".kts", ".gradle", ".java", ".swift", ".plist", ".xcconfig", ".pbxproj"]:
            with self.subTest(suffix=suffix):
                self.assertIn(suffix, guard.TEXT_SUFFIXES)

    def test_private_configuration_paths(self):
        for path in ["backend/.env", "backend/.env.local", "keys/service-account.json",
                     "android/app/google-services.json", "android/key.properties",
                     "config/credentials.json", "android/upload.jks", "secrets/anything.json",
                     "design_refs/private_reference/reference_video.mp4", "artifacts/phase2a/preview.png"]:
            with self.subTest(path=path):
                self.assertTrue(guard.private_path(path))

    def test_sanitized_examples_are_allowed(self):
        self.assertFalse(guard.private_path("backend/.env.example"))
        self.assertFalse(guard.unsafe_content(b"GROQ_API_KEY=\n"))

    def test_provider_literals_are_detected_without_real_credentials(self):
        synthetic = b"gsk_" + b"synthetic_test_only_" * 3
        self.assertTrue(guard.unsafe_content(synthetic))

    def test_renamed_admin_credentials_are_detected(self):
        fake_account = b'{"type":"service_' + b'account"}'
        fake_key = b'{"private_' + b'key":"synthetic"}'

        self.assertTrue(guard.unsafe_content(fake_account))
        self.assertTrue(guard.unsafe_content(fake_key))

    def test_ordinary_json_and_source_are_allowed(self):
        self.assertFalse(guard.unsafe_content(b'{"status":"ok"}'))
        self.assertFalse(guard.unsafe_content(b"print('hello')"))


if __name__ == "__main__":
    unittest.main()
