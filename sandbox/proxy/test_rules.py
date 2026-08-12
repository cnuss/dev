"""Unit tests for allowlist matching — run with `python3 proxy/test_rules.py`.

Suffix matching is where allowlists leak (`.github.com` must not admit
`notgithub.com`), so it gets tested independently of the proxy runtime.
"""

import sys
import types
import unittest
from pathlib import Path

# The addon imports mitmproxy at module scope; stub it so these tests run
# anywhere, without the proxy image.
if "mitmproxy" not in sys.modules:
    stub = types.ModuleType("mitmproxy")
    stub.http = types.ModuleType("mitmproxy.http")
    sys.modules["mitmproxy"] = stub
    sys.modules["mitmproxy.http"] = stub.http

sys.path.insert(0, str(Path(__file__).parent))
from sandbox_proxy import match_rule, parse_rules  # noqa: E402


class TestMatchRule(unittest.TestCase):
    rules = [".github.com", "pypi.org", ".ubuntu.com"]

    def test_exact_rule_matches_only_itself(self):
        self.assertEqual(match_rule("pypi.org", self.rules), "pypi.org")
        self.assertIsNone(match_rule("files.pypi.org", self.rules))
        self.assertIsNone(match_rule("evilpypi.org", self.rules))

    def test_dot_rule_matches_domain_and_subdomains(self):
        self.assertEqual(match_rule("github.com", self.rules), ".github.com")
        self.assertEqual(match_rule("api.github.com", self.rules), ".github.com")
        self.assertEqual(match_rule("a.b.github.com", self.rules), ".github.com")

    def test_dot_rule_rejects_suffix_lookalikes(self):
        for host in ("notgithub.com", "github.com.evil.net", "xgithub.com"):
            with self.subTest(host=host):
                self.assertIsNone(match_rule(host, self.rules))

    def test_case_and_trailing_dot_are_normalised(self):
        self.assertIsNotNone(match_rule("API.GitHub.Com", self.rules))
        self.assertIsNotNone(match_rule("api.github.com.", self.rules))

    def test_empty_allowlist_denies_everything(self):
        self.assertIsNone(match_rule("github.com", []))


class TestParseRules(unittest.TestCase):
    def test_parses_comments_blanks_globs_and_case(self):
        import tempfile

        body = "\n".join(
            [
                "# a comment",
                "",
                "  Example.COM  # trailing comment",
                "*.github.com",
                ".ubuntu.com.",
            ]
        )
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as fh:
            fh.write(body)
            path = fh.name
        self.assertEqual(
            parse_rules(path), ["example.com", ".github.com", ".ubuntu.com"]
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
