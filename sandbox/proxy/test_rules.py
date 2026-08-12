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
    for name in ("http", "dns", "net", "net.dns", "net.dns.response_codes"):
        mod = types.ModuleType(f"mitmproxy.{name}")
        sys.modules[f"mitmproxy.{name}"] = mod
        setattr(stub, name.split(".")[-1], mod)
    sys.modules["mitmproxy"] = stub
    sys.modules["mitmproxy.net.dns.response_codes"].NXDOMAIN = 3

sys.path.insert(0, str(Path(__file__).parent))
import sandbox_proxy  # noqa: E402
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


class FakeQuestion:
    def __init__(self, name):
        self.name = name


class FakeRequest:
    def __init__(self, names):
        self.questions = [FakeQuestion(n) for n in names]
        self.failed_with = None

    def fail(self, code):
        self.failed_with = code
        return f"nxdomain:{code}"


class FakeDnsFlow:
    def __init__(self, *names):
        self.request = FakeRequest(names)
        self.response = None


class TestDnsFiltering(unittest.TestCase):
    """The resolver is the sandbox's only way to look anything up, so what it
    refuses is the exfiltration boundary."""

    def setUp(self):
        import tempfile

        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as fh:
            fh.write(".github.com\nexample.com\n")
            self.path = fh.name
        self._orig = sandbox_proxy.ALLOWLIST_PATH
        sandbox_proxy.ALLOWLIST_PATH = self.path
        self.addon = sandbox_proxy.SandboxEgress()
        self.addon.refresh(force=True)

    def tearDown(self):
        sandbox_proxy.ALLOWLIST_PATH = self._orig

    def test_allowlisted_name_is_forwarded(self):
        flow = FakeDnsFlow("api.github.com")
        self.addon.dns_request(flow)
        self.assertIsNone(flow.response, "should fall through to the upstream resolver")
        self.assertEqual(self.addon.dns_allowed_count, 1)

    def test_unlisted_name_is_refused_locally(self):
        flow = FakeDnsFlow("example.org")
        self.addon.dns_request(flow)
        self.assertIsNotNone(flow.response, "must never reach an upstream resolver")
        self.assertEqual(flow.request.failed_with, 3)  # NXDOMAIN
        self.assertEqual(self.addon.dns_denied_count, 1)

    def test_exfiltration_name_is_refused(self):
        flow = FakeDnsFlow("c2VjcmV0.exfil.attacker.example")
        self.addon.dns_request(flow)
        self.assertIsNotNone(flow.response)
        self.assertEqual(
            self.addon.denials[0]["reason"], "dns-not-in-allowlist"
        )

    def test_subdomain_of_exact_rule_is_refused(self):
        # `example.com` is an exact rule, so www.example.com is not covered.
        flow = FakeDnsFlow("www.example.com")
        self.addon.dns_request(flow)
        self.assertIsNotNone(flow.response)

    def test_healthcheck_probe_is_refused_but_not_recorded(self):
        flow = FakeDnsFlow(sandbox_proxy.HEALTHCHECK_NAME)
        self.addon.dns_request(flow)
        self.assertIsNotNone(flow.response, "healthcheck still expects NXDOMAIN")
        self.assertEqual(self.addon.dns_denied_count, 0)
        self.assertEqual(len(self.addon.denials), 0, "must not crowd the ring buffer")

    def test_mixed_query_is_refused_if_any_name_is_unlisted(self):
        flow = FakeDnsFlow("api.github.com", "exfil.attacker.example")
        self.addon.dns_request(flow)
        self.assertIsNotNone(flow.response)


if __name__ == "__main__":
    unittest.main(verbosity=2)
