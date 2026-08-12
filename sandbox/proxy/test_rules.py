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


class TestWildcard(unittest.TestCase):
    """`*` is the shipped default, matching the hosted environment's open
    egress. Everything must match it, including hosts no other rule covers."""

    def test_star_matches_anything(self):
        for host in ("github.com", "pastebin.com", "a.b.c.example", "localhost"):
            with self.subTest(host=host):
                self.assertEqual(match_rule(host, ["*"]), "*")

    def test_star_survives_parsing(self):
        import tempfile

        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as fh:
            fh.write("# open\n*\n.github.com\n")
            path = fh.name
        rules = parse_rules(path)
        self.assertEqual(rules[0], "*", "must not be mangled into '.'")
        self.assertEqual(match_rule("anything.example", rules), "*")

    def test_star_does_not_leak_into_glob_stripping(self):
        # `*.foo.com` loses its star during parsing; a bare `*` must not.
        import tempfile

        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as fh:
            fh.write("*.foo.com\n")
            path = fh.name
        rules = parse_rules(path)
        self.assertEqual(rules, [".foo.com"])
        self.assertEqual(match_rule("x.foo.com", rules), ".foo.com")
        self.assertIsNone(match_rule("bar.com", rules), "must not become a wildcard")


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

    def test_healthcheck_probe_stays_local_under_open_policy(self):
        # With `*` the probe would otherwise be forwarded upstream every few
        # seconds, and a broken forwarder would mark the container unhealthy.
        import tempfile

        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as fh:
            fh.write("*\n")
            path = fh.name
        sandbox_proxy.ALLOWLIST_PATH = path
        addon = sandbox_proxy.SandboxEgress()
        addon.refresh(force=True)

        flow = FakeDnsFlow(sandbox_proxy.HEALTHCHECK_NAME)
        addon.dns_request(flow)
        self.assertIsNotNone(flow.response, "must be answered locally, not forwarded")
        self.assertEqual(addon.dns_allowed_count, 0)

    def test_open_policy_forwards_everything_else(self):
        import tempfile

        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as fh:
            fh.write("*\n")
            path = fh.name
        sandbox_proxy.ALLOWLIST_PATH = path
        addon = sandbox_proxy.SandboxEgress()
        addon.refresh(force=True)

        flow = FakeDnsFlow("pastebin.com")
        addon.dns_request(flow)
        self.assertIsNone(flow.response, "open policy must not intercept")
        self.assertEqual(addon.dns_allowed_count, 1)

    def test_mixed_query_is_refused_if_any_name_is_unlisted(self):
        flow = FakeDnsFlow("api.github.com", "exfil.attacker.example")
        self.addon.dns_request(flow)
        self.assertIsNotNone(flow.response)


class FakeProxyMode:
    pass


class TransparentMode(FakeProxyMode):
    pass


class RegularMode(FakeProxyMode):
    pass


class FakeClientConn:
    def __init__(self, mode):
        self.proxy_mode = mode


class FakeHttpFlow:
    def __init__(self, mode=None):
        self.response = None
        if mode is not None:
            self.client_conn = FakeClientConn(mode)


class TestTransparentDetection(unittest.TestCase):
    """A transparently captured :80 request is ordinary traffic; only an
    explicit HTTP_PROXY client should get 405. Confusing the two breaks plain
    HTTP interception entirely."""

    def test_transparent_flow_is_detected(self):
        self.assertTrue(sandbox_proxy.is_transparent(FakeHttpFlow(TransparentMode())))

    def test_regular_flow_is_not_transparent(self):
        self.assertFalse(sandbox_proxy.is_transparent(FakeHttpFlow(RegularMode())))

    def test_missing_attribute_is_not_transparent(self):
        # Fail safe: if the API moves, fall back to treating flows as explicit
        # rather than silently waiving the rule for everything.
        self.assertFalse(sandbox_proxy.is_transparent(FakeHttpFlow()))


if __name__ == "__main__":
    unittest.main(verbosity=2)
