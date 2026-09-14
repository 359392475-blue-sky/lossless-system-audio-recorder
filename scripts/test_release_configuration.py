import importlib.util
from pathlib import Path
import base64
import unittest

spec = importlib.util.spec_from_file_location("configure_release", Path(__file__).with_name("configure-release.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleaseConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.env = {
            "LOSSLESS_RECORDER_UPDATE_FEED_URL": "https://updates.lowpower.me/recorder/appcast.xml",
            "LOSSLESS_RECORDER_POLICY_URL": "https://updates.lowpower.me/recorder/v1/policy",
            "LOSSLESS_RECORDER_UPDATE_PUBLIC_KEY": base64.b64encode(bytes(range(32))).decode(),
            "LOSSLESS_RECORDER_POLICY_PUBLIC_KEY": base64.b64encode(bytes(range(1, 33))).decode(),
        }

    def test_every_field_required(self):
        for name in self.env:
            with self.subTest(name=name), self.assertRaises(ValueError):
                module.configuration({k: v for k, v in self.env.items() if k != name})

    def test_insecure_or_placeholder_urls_rejected(self):
        for url in ["http://updates.lowpower.me/p", "https://example.invalid/p", "https://localhost/p",
                    "https://example.com/p", "https://user:password@lowpower.me/p", "https://lowpower.me/p?bypass=1"]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                module.configuration(dict(self.env, LOSSLESS_RECORDER_POLICY_URL=url))

    def test_invalid_keys_rejected(self):
        for value in ["placeholder", "", base64.b64encode(bytes(32)).decode()]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                module.configuration(dict(self.env, LOSSLESS_RECORDER_POLICY_PUBLIC_KEY=value))

    def test_complete_configuration_enforces_signatures(self):
        actual = module.configuration(self.env)
        self.assertTrue(actual["SURequireSignedFeed"])
        self.assertTrue(actual["SUVerifyUpdateBeforeExtraction"])
        self.assertEqual(actual["RecorderPolicyURL"], self.env["LOSSLESS_RECORDER_POLICY_URL"])
        self.assertFalse(actual["SUAutomaticallyUpdate"])


if __name__ == "__main__":
    unittest.main()
