import hashlib, json, os, sys, tempfile, unittest, urllib.error
from unittest import mock
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
import fetch_uniprot as fu


def _write(p, s):
    with open(p, "w") as fh: fh.write(s)


class FetchTests(unittest.TestCase):
    def test_no_network_without_optin(self):
        # no fixture, no ALLOW_NETWORK -> must refuse (never touch network)
        os.environ.pop("UNIPROT_FIXTURE_DIR", None); os.environ.pop("ALLOW_NETWORK", None)
        with self.assertRaises(fu.ContractError):
            fu.fetch_page("https://rest.uniprot.org/uniprotkb/search?x=1", "rest.uniprot.org", 0)

    def test_host_allowlist(self):
        os.environ.pop("UNIPROT_FIXTURE_DIR", None); os.environ["ALLOW_NETWORK"] = "1"
        try:
            with self.assertRaises(fu.ContractError):
                fu.fetch_page("https://evil.example.com/x", "rest.uniprot.org", 0)
        finally:
            os.environ.pop("ALLOW_NETWORK", None)

    def test_fixture_page_and_cursor_advance(self):
        with tempfile.TemporaryDirectory() as d:
            fx = os.path.join(d, "fx"); os.makedirs(fx)
            _write(os.path.join(fx, "page-0.fasta"), ">tr|A1|A1_X d\nMKT\n")
            _write(os.path.join(fx, "page-0.next"),
                   "https://rest.uniprot.org/uniprotkb/search?query=x&format=fasta&size=200&cursor=abc")
            _write(os.path.join(fx, "page-1.fasta"), ">tr|B2|B2_X d\nMMM\n")
            # page-1 has no .next -> query should roll over
            os.environ["UNIPROT_FIXTURE_DIR"] = fx
            cfg = os.path.join(d, "worker.json"); _write(cfg, json.dumps({"uniprotHost": "rest.uniprot.org", "fetchPageSize": 200, "fetchRateLimitSeconds": 0}))
            qr = os.path.join(d, "qr.json"); _write(qr, json.dumps({"schemaVersion": 1, "queries": [{"id": "q1", "uniprotQuery": "x"}, {"id": "q2", "uniprotQuery": "y"}]}))
            rot = os.path.join(d, "rotation.json"); _write(rot, json.dumps({}))
            inbox = os.path.join(d, "inbox"); os.makedirs(inbox)
            try:
                out1 = fu.main(["--config", cfg, "--query-rotation", qr, "--rotation", rot, "--inbox", inbox])
                self.assertEqual(out1, 0)
                with open(rot) as fh:
                    r = json.load(fh)
                self.assertEqual(r["queryIndex"], 0)          # still on q1 (has next)
                self.assertEqual(r["queryId"], "q1")
                with open(qr, "rb") as source:
                    expected_digest = "sha256:" + hashlib.sha256(source.read()).hexdigest()
                self.assertEqual(r["approvedQueryDigest"], expected_digest)
                self.assertTrue(r["nextCursor"].endswith("cursor=abc"))
                self.assertEqual(len(os.listdir(inbox)), 1)
                fu.main(["--config", cfg, "--query-rotation", qr, "--rotation", rot, "--inbox", inbox])
                with open(rot) as fh:
                    r = json.load(fh)
                self.assertEqual(r["queryIndex"], 1)          # page-1 had no next -> advanced to q2
                self.assertEqual(r["queryId"], "q2")
                self.assertIsNone(r["nextCursor"])
                # Both fetches must survive on disk even if they land in the same
                # wall-clock second: no filename collision, no silent overwrite.
                self.assertEqual(len(os.listdir(inbox)), 2)
                fasta_files = [f for f in os.listdir(inbox) if f.endswith(".fasta")]
                self.assertEqual(len(fasta_files), 2)
                contents = set()
                for fn in fasta_files:
                    with open(os.path.join(inbox, fn)) as fh:
                        contents.add(fh.read())
                self.assertEqual(contents, {">tr|A1|A1_X d\nMKT\n", ">tr|B2|B2_X d\nMMM\n"})
            finally:
                os.environ.pop("UNIPROT_FIXTURE_DIR", None)

    def test_unbound_legacy_cursor_is_discarded(self):
        with tempfile.TemporaryDirectory() as d:
            fx = os.path.join(d, "fx"); os.makedirs(fx)
            _write(os.path.join(fx, "page-0.fasta"), ">SAFE\nMKT\n")
            os.environ["UNIPROT_FIXTURE_DIR"] = fx
            cfg = os.path.join(d, "worker.json")
            _write(cfg, json.dumps({"uniprotHost": "rest.uniprot.org", "fetchPageSize": 20,
                                    "fetchRateLimitSeconds": 0}))
            qr = os.path.join(d, "qr.json")
            _write(qr, json.dumps({"schemaVersion": 1, "queries": [
                {"id": "approved", "uniprotQuery": "approved:true"}
            ]}))
            rot = os.path.join(d, "rotation.json")
            _write(rot, json.dumps({
                "queryIndex": 0,
                "nextCursor": "https://rest.uniprot.org/uniprotkb/search?query=old%3Atrue&format=fasta&size=20&cursor=old"
            }))
            inbox = os.path.join(d, "inbox"); os.makedirs(inbox)
            try:
                self.assertEqual(fu.main(["--config", cfg, "--query-rotation", qr,
                                          "--rotation", rot, "--inbox", inbox]), 0)
                with open(rot) as fh:
                    updated = json.load(fh)
                self.assertEqual(updated["queryId"], "approved")
                self.assertIsNone(updated["nextCursor"])
                fasta = next(name for name in os.listdir(inbox) if name.endswith(".fasta"))
                with open(os.path.join(inbox, fasta)) as fh:
                    self.assertIn(">SAFE", fh.read())
            finally:
                os.environ.pop("UNIPROT_FIXTURE_DIR", None)

    def test_same_host_wrong_query_cursor_is_contract_failure(self):
        with self.assertRaises(fu.ContractError):
            fu._validate_search_url(
                "https://rest.uniprot.org/uniprotkb/search?query=wrong&format=fasta&size=20&cursor=x",
                "rest.uniprot.org", "approved", 20,
            )

    def test_transport_failure_is_retryable_tempfail(self):
        url = "https://rest.uniprot.org/uniprotkb/search?query=x&format=fasta&size=1"
        os.environ["ALLOW_NETWORK"] = "1"
        try:
            with mock.patch.object(fu.urllib.request, "urlopen",
                                   side_effect=urllib.error.URLError("offline")), \
                 mock.patch.object(fu.time, "sleep"):
                with self.assertRaises(fu.TransientFetchError):
                    fu.fetch_page(url, "rest.uniprot.org", 1)
        finally:
            os.environ.pop("ALLOW_NETWORK", None)

    def test_nonretryable_http_error_is_contract_failure(self):
        url = "https://rest.uniprot.org/uniprotkb/search?query=x&format=fasta&size=1"
        os.environ["ALLOW_NETWORK"] = "1"
        error = urllib.error.HTTPError(url, 400, "bad request", {}, None)
        try:
            with mock.patch.object(fu.urllib.request, "urlopen", side_effect=error), \
                 mock.patch.object(fu.time, "sleep"):
                with self.assertRaises(fu.ContractError):
                    fu.fetch_page(url, "rest.uniprot.org", 1)
        finally:
            os.environ.pop("ALLOW_NETWORK", None)


if __name__ == "__main__":
    unittest.main()
