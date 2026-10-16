#!/usr/bin/env bash
# End-to-end test for paper-publish. Covers every row marked "yes" in paper-publish.failure-modes.md.
# A fake Zenodo and a fake Software Heritage run on localhost. No network, no real token.
# Ends by printing a transcript path and its sha256. The hash is the same on every run.
set -euo pipefail
cd "$(dirname "$0")"
TOOL=./paper-publish PY=$(command -v python3) T=$(mktemp -d) pass=0
mkdir "$T/out"; TR=$T/transcript.txt; LOG=$T/server.log; : > "$LOG"
fail() { echo "FAIL - $1 (files in $T)" >&2; exit 1; }
ok() { pass=$((pass + 1)); echo "ok $pass - $1" | tee -a "$TR"; }

cat > "$T/fake.py" <<'EOF'
import http.server, json, sys, time
LOG, ST = sys.argv[2], {}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj=None, raw=None, hdr=()):
        b = raw if raw is not None else (json.dumps(obj).encode() if obj is not None else b"")
        self.send_response(code)
        for k, v in hdr: self.send_header(k, v)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        tok, p, me = (self.headers.get("Authorization") or "")[7:], self.path, self.command
        open(LOG, "a").write("%.3f %s %s %d %s\n" % (time.time(), me, p, len(body), "auth" if tok else "noauth"))
        B = "http://127.0.0.1:%d" % self.server.server_port
        L = B.replace("127.0.0.1", "localhost") if "OTHER" in tok else B  # a link on another host
        dep = lambda i: {"id": i, "conceptrecid": "110", "links": {"bucket": L + "/api/files/bkt%d" % i, "html": B + "/deposit/%d" % i},
                         "files": [{"id": "f1", "links": {"self": B + "/api/deposit/depositions/222/files/f1"}}] * (i == 222)}
        if p in ("/ok", "/missing"): return self.send(200 if p == "/ok" else 404, raw=b"x")
        if "/swh/" in p:
            u = p.split("/url/", 1)[1]
            if me == "POST":
                if "ratelimited" in u and not ST.get("rl"): ST["rl"] = 1; return self.send(429, {}, hdr=[("Retry-After", "1")])
                if "noid" in u: return self.send(201, {})
                if "rejected" in u: return self.send(200, {"id": 9, "save_request_status": "rejected"})
                ST[u] = 0; return self.send(201, {"id": 7, "save_request_status": "accepted", "save_task_status": "pending"})
            ST[u] += 1
            t = "running" if ("hangs" in u or ST[u] < 2) else ("failed" if "fails" in u else "succeeded")
            return self.send(200, [{"id": 7, "save_request_status": "accepted", "save_task_status": t, "snapshot_swhid": "swh:1:snp:" + "a" * 40}])
        if "ECHO403" in tok: return self.send(403, {"message": "Invalid token " + tok})
        if me == "POST" and p == "/api/deposit/depositions": return self.send(201, dep(111))
        if me == "PUT" and p.startswith("/api/files/"): return self.send(201, {"size": len(body)})
        if me == "PUT" and p.startswith("/api/deposit/depositions/"):
            if "FAIL500" in tok: return self.send(500, raw=b"<html>boom</html>")
            open(LOG + ".meta", "wb").write(body); return self.send(200, json.loads(body))
        if p.endswith("/actions/publish"): return self.send(202, {"doi": "10.5072/zenodo.111"})
        if p == "/api/records/301/versions/latest": return self.send(301, hdr=[("Location", "http://localhost:%d/api/records/110/versions/latest" % self.server.server_port)])
        if p == "/api/records/110/versions/latest": return self.send(200, {"id": 105})
        if p.endswith("/105/actions/newversion"): return self.send(201, {"id": 105, "links": {"latest_draft": B + "/api/deposit/depositions/222"}})
        if me == "GET" and p == "/api/deposit/depositions/222": return self.send(200, dep(222))
        self.send(204 if me == "DELETE" else 404)
    do_GET = do_POST = do_PUT = do_DELETE = do
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_port)); s.serve_forever()
EOF
$PY "$T/fake.py" "$T/port" "$LOG" & SRV=$!
trap 'rc=$?; kill $SRV 2>/dev/null; wait $SRV 2>/dev/null || :; [ $rc = 0 ] && rm -rf "$T"; true' EXIT
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
PORT=$(cat "$T/port") B=http://127.0.0.1:$(cat "$T/port")
export ZENODO_BASE=$B/api SWH_BASE=$B/swh/api/1 ZENODO_TOKEN=FAKETOKEN-ok

# fixtures: a real PDF (no xref table, poppler rebuilds it), a tarball, a meta file, a CITATION.cff
printf '%%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj\n4 0 obj<</Length 56>>stream\nBT /F1 14 Tf 72 700 Td (A Test Title For Benchmarks) Tj ET\nendstream endobj\n5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\ntrailer<</Size 6/Root 1 0 R>>\n%%%%EOF\n' > "$T/paper.pdf"
echo "fake tarball bytes" > "$T/paper.tar.gz"; printf 'title: "A Test Title For Benchmarks"\n' > "$T/CITATION.cff"
cat > "$T/meta.json" <<EOF
{"title": "A Test Title For Benchmarks", "license": "cc-by-4.0", "keywords": ["benchmark"], "subject_class": "cs.AI", "comments": "10 pages",
 "abstract": "A test abstract for the paper. It is long enough to pass the length check and links to $B/ok for the code.",
 "authors": [{"name": "Arab, Pooria", "affiliation": "Independent", "orcid": "0000-0002-1825-0097"}], "venues": ["arXiv", "Zenodo", "TMLR"],
 "code_url": "$B/ok", "data_concept_dois": ["10.5281/zenodo.110"]}
EOF
mm() { $PY -c 'import json,sys; m = json.load(open(sys.argv[1])); exec(sys.argv[3]); json.dump(m, open(sys.argv[2], "w"))' "$T/meta.json" "$T/$1" "$2"; }
# run NAME "what it does" CMD...  sets RC, saves the output, appends a normalised copy to the transcript
run() {
  local n=$1 d=$2; shift 2; : > "$LOG"
  set +e; "$@" > "$T/out/$n" 2>&1; RC=$?; set -e
  { echo "## $n: $d (exit $RC)"; sed -e "s#$T#\$T#g" -e "s#127.0.0.1:$PORT#HOST#g" -e "s#localhost:$PORT#HOST#g" "$T/out/$n"; } >> "$TR"
}
has() { grep -qF -- "$2" "$T/out/$1" || fail "$1 lacks: $2"; }
calls() { grep -c -- "$1" "$LOG" || true; }
quiet() { [ ! -s "$LOG" ] || fail "$1 sent a request"; }
Z="$TOOL zenodo-draft --pdf $T/paper.pdf --tarball $T/paper.tar.gz --meta $T/meta.json"

run r1 "no token" env -u ZENODO_TOKEN $Z; has r1 "ZENODO_TOKEN is not set"; quiet 1; [ $RC = 2 ] || fail 1; ok "missing token is refused (status 2) and sends nothing"
run r2 "token in argv" $Z --token FAKETOKEN-argv; has r2 "bad arguments"; quiet 2; [ $RC = 2 ] || fail 2; ok "a token in argv is refused and not repeated"
run r2b "abbreviated flags" $Z --pub --i-confirm-permanent; has r2b "bad arguments"; quiet 2b; [ $RC = 2 ] || fail 2b; ok "an abbreviated --publish cannot pass the gate"
run r1b "token with a trailing CR" env ZENODO_TOKEN=$'FAKETOKEN-bad\r' $Z; has r1b "ZENODO_TOKEN has a space"; quiet 1b; ! grep -q Traceback "$T/out/r1b" && [ $RC = 2 ] || fail 1b
run r1c "a base URL that makes urllib raise" env ZENODO_BASE='http://[::1' $Z; has r1c "unexpected problem"; ! grep -q Traceback "$T/out/r1c" && [ $RC = 1 ] || fail 1c; ok "a bad token is refused, and any other error ends without a traceback"
run r3 "upstream echoes the token in a 403" env ZENODO_TOKEN=FAKETOKEN-ECHO403 $Z; has r3 "Zenodo create draft failed: HTTP 403: Invalid token ***"; [ $RC = 1 ] || fail 3; ok "an echoed token becomes *** and a 4xx names the step and status"
run r3b "a link on another host" env ZENODO_TOKEN=FAKETOKEN-OTHER $Z; has r3b "is not on the ZENODO_BASE host"; [ $RC = 2 ] && [ "$(calls 'PUT /api/files')" = 0 ] || fail 3b; ok "a response link on another host gets no token and no upload"
run r4 "publish without confirmation" $Z --publish; has r4 "title: A Test Title For Benchmarks"; has r4 "paper.tar.gz ("; has r4 refused; quiet 4; [ $RC = 2 ] || fail 4; ok "--publish alone prints title and files, refuses, sends nothing"
run r5 "publish with both flags" $Z --publish --i-confirm-permanent; has r5 "PUBLISHED. doi: 10.5072/zenodo.111"; [ $RC = 0 ] && [ "$(calls actions/publish)" = 1 ] || fail 5; [ "$(grep -n 'PUT /api/deposit/depositions/111 ' "$LOG" | cut -d: -f1)" -lt "$(grep -n actions/publish "$LOG" | cut -d: -f1)" ] || fail "5 order"; ok "publish happens once, after the metadata"
run r6 "plain run with a community" $Z --community test-comm; has r6 "draft id: 111"; has r6 "preview: $B/deposit/111"; [ $RC = 0 ] && [ "$(calls actions/publish)" = 0 ] || fail 6
$PY - "$LOG.meta" "$B/ok" <<'EOF' || fail "6 metadata"
import json, sys
md = json.load(open(sys.argv[1]))["metadata"]
rel = {(r["identifier"], r["resource_type"]) for r in md["related_identifiers"]}
assert (md["upload_type"], md["publication_type"]) == ("publication", "preprint"), md
assert md["creators"][0]["orcid"] == "0000-0002-1825-0097" and md["communities"] == [{"identifier": "test-comm"}], md
assert {(sys.argv[2], "software"), ("10.5281/zenodo.110", "dataset")} <= rel, rel
EOF
ok "a plain run stops at a draft with the right metadata and never publishes"
run r8 "500 after the draft exists" env ZENODO_TOKEN=FAKETOKEN-FAIL500 $Z; has r8 "HTTP 500: <html>boom"; has r8 "Draft 111 exists and is NOT published"; [ $RC = 1 ] || fail 8; ok "a 5xx after the draft names the draft id"
$PY -c "open('$T/big.pdf','wb').truncate(51*1024**3)"
for f in none big; do run r9$f "unusable PDF $f" $TOOL zenodo-draft --pdf "$T/$f.pdf" --tarball "$T/paper.tar.gz" --meta "$T/meta.json"; has r9$f "missing or larger than the 50 GB"; quiet 9$f; [ $RC = 2 ] || fail 9$f; done
rm -f "$T/big.pdf"; ok "a missing or oversize file is refused (status 2) before any request"
run r10 "new version of concept 110" $Z --new-version-of 110; has r10 "draft id: 222"; [ $RC = 0 ] && [ "$(calls 'DELETE /api/deposit/depositions/222/files/f1')" = 1 ] || fail 10; [ "$(calls 'PUT /api/files/bkt222/')" = 2 ] && [ "$(calls 'POST /api/deposit/depositions ')" = 0 ] || fail "10 files"; ok "--new-version-of opens a new draft, removes the old file, uploads two new ones"
run r10b "a redirect to another host" $Z --new-version-of 301; [ $RC = 0 ] && grep -q "GET /api/records/301/versions/latest 0 auth" "$LOG" && grep -q "GET /api/records/110/versions/latest 0 noauth" "$LOG" || fail "10b token followed a redirect"; ok "a redirect to another host drops the Authorization header"
run r11 "server not reachable" env ZENODO_BASE=http://127.0.0.1:9/api $Z; has r11 "cannot reach 127.0.0.1:9: Connection refused"; ! grep -q Traceback "$T/out/r11" && [ $RC = 1 ] || fail 11; ok "an unreachable server gives a clear message"
mm nolic.json 'del m["license"]'; mm bt.json 'm["title"] = 5'; echo '{bad' > "$T/bad.json"
for pair in "nolic.json|lacks: license" "bad.json|cannot read" "bt.json|wrong type"; do f=${pair%%|*}
  run r12$f "bad meta $f" $TOOL zenodo-draft --pdf "$T/paper.pdf" --tarball "$T/paper.tar.gz" --meta "$T/$f"; has r12$f "${pair#*|}"; [ $RC = 2 ] || fail "12 $f"; done
ok "a bad, incomplete or wrongly typed meta.json is refused (status 2)"

S="$TOOL swh-save --interval 0.05 --timeout 1"
run s13 "rate limited once" $S https://github.com/x/ratelimited; t=($(grep POST "$LOG" | cut -d' ' -f1)); has s13 "ratelimited	succeeded	swh:1:snp:aaaaaaaa"; has s13 "waiting 1s"; [ $RC = 0 ] && [ ${#t[@]} = 2 ] || fail 13
$PY -c "import sys; sys.exit(0 if ${t[1]} - ${t[0]} >= 1 else 1)" || fail "waited less than Retry-After"; ok "a 429 waits for Retry-After and retries"
run s14 "failed, rejected, timeout, success" $S https://github.com/x/fails https://github.com/x/rejected https://github.com/x/hangs https://github.com/x/fine https://github.com/x/noid
has s14 "no usable request id"; has s14 "fails	failed"; has s14 "rejected	rejected"; has s14 "hangs	timeout (still running)"; has s14 "fine	succeeded"; [ $RC = 1 ] || fail 14; ok "each URL gets a status and the run ends with status 1"
run s15 "ftp URL" $S ftp://example.org/x; quiet 15; [ $RC = 2 ] || fail 15; run s15b "negative interval" $TOOL swh-save --interval -1 https://github.com/x/fine; quiet 15b; [ $RC = 2 ] || fail 15b; ok "a non-http URL is refused (status 2) before any request"

P="$TOOL packet"
mm unk.json 'm["venues"] = ["Nonexistent Journal of Nothing"]'; run k16 "unknown venue" $P "$T/unk.json" --out "$T/pk16"; has k16 "does not invent venues"; [ $RC = 2 ] && [ ! -e "$T/pk16" ] || fail 16; ok "an unknown or ambiguous venue is refused (status 2), lists the candidates and writes nothing"
mm ieee.json 'm["venues"] = ["IEEE"]'; run k16b "an ambiguous venue" $P "$T/ieee.json" --out "$T/pk16b"; has k16b "matches"; has k16b "IEEE Computer"; [ $RC = 2 ] && [ ! -e "$T/pk16b" ] || fail "16b"
mm two.json 'm["venues"] = ["TMLR", "DMLR"]'; run k17 "two peer-reviewed venues" $P "$T/two.json" --out "$T/pk17"; has k17 "dual submission"; [ $RC = 2 ] && [ ! -e "$T/pk17" ] || fail "17 refuse"
run k17b "two venues, allowed" $P "$T/two.json" --out "$T/pk17" --allow-second-review-venue; [ $RC = 0 ] && grep -q "WARNING: this packet has 2" "$T/pk17/CHECKLIST.md" || fail "17 allow"; ok "two review venues are refused, and the flag adds a warning to the checklist"
run k18 "arXiv, Zenodo, TMLR" $P "$T/meta.json" --out "$T/pk18"; [ $RC = 0 ] && [ "$(ls "$T/pk18" | tr '\n' ' ')" = "CHECKLIST.md arxiv.md tmlr.md zenodo.md " ] || fail "18 files"; grep -q "CAPTCHA" "$T/pk18/CHECKLIST.md" && grep -q "ONE peer-reviewed" "$T/pk18/CHECKLIST.md" || fail "18 checklist"
grep -q "Review mode: double-blind" "$T/pk18/tmlr.md" && grep -q "0000-0002-1825-0097" "$T/pk18/arxiv.md" || fail "18 review mode"; mm ex.json 'm["venues"] = ["arXiv (cs.AI, cs.CL, cs.LG)"]'; run k18b "an exact venue name" $P "$T/ex.json" --out "$T/pk18b"; [ $RC = 0 ] && [ -e "$T/pk18b/arxiv-cs-ai-cs-cl-cs-lg.md" ] || fail "18b"
ok "one file per venue with its review mode, plus a checklist of manual steps, and an exact full name works"

run c19 "good paper" $TOOL check "$T/meta.json" --pdf "$T/paper.pdf" --cff "$T/CITATION.cff"; has c19 "check passed"; [ $RC = 0 ] || fail "19 good"
mm title.json 'm["title"] = "Test"'; run c19b "title mismatch" $TOOL check "$T/title.json" --pdf "$T/paper.pdf" --cff "$T/CITATION.cff" --offline; has c19b "not the title block"; has c19b "top-level title in $T/CITATION.cff"; [ $RC = 1 ] || fail 19
printf 'title: "a test title for benchmarks"\n' > "$T/c2.cff"; printf 'cff-version: 1.2.0\nreferences:\n  - type: article\n    title: "A Test Title For Benchmarks"\n' > "$T/c3.cff"
for c in c2 c3; do run c19$c "CITATION.cff $c" $TOOL check "$T/meta.json" --cff "$T/$c.cff" --offline; has c19$c "top-level title"; [ $RC = 1 ] || fail "19 $c"; done
mm u.json 'm["code_url"] = "'$B'/missing"; m["data_url"] = "'$B'/missing2"'; run c19u "dead code and data URLs" $TOOL check "$T/u.json"; has c19u "missing "; has c19u "missing2"; [ $RC = 1 ] || fail "19 url"; ok "a title must equal the PDF title block and the top-level CITATION.cff title, and dead code and data URLs fail"
mm orc.json 'm["authors"][0]["orcid"] = "0000-0002-1825-0098"'; run c20 "bad ORCID checksum" $TOOL check "$T/orc.json" --offline; has c20 "bad ORCID"; [ $RC = 1 ] || fail "20 check"
mm orc2.json 'm["authors"][0]["orcid"] = "abc"'; run c20c "non-numeric ORCID" $TOOL check "$T/orc2.json" --offline; has c20c "bad ORCID"; ! grep -q Traceback "$T/out/c20c" || fail "20 traceback"
run c20b "bad ORCID in zenodo-draft" $TOOL zenodo-draft --pdf "$T/paper.pdf" --tarball "$T/paper.tar.gz" --meta "$T/orc.json"; has c20b "bad ORCID"; quiet 20; [ $RC = 2 ] || fail "20 draft"; ok "a bad ORCID, by checksum or by shape, fails both commands without a traceback"
mm multi.json 'm["abstract"] = "Short XXXX — see '$B'/missing"; del m["license"]'; run c21 "many problems at once" $TOOL check "$T/multi.json"; has c21 "abstract has"; has c21 "XXXX"; has c21 "em dash"; has c21 "does not return 200"; has c21 "needs a title and a license"; [ $RC = 1 ] || fail 21; ok "every problem is listed, not only the first"
run c22 "same paper, offline" $TOOL check "$T/multi.json" --offline; ! grep -q "does not return 200" "$T/out/c22" && quiet 22 && [ $RC = 1 ] || fail 22; ok "--offline sends no request"
run c23 "no pdftotext" env PATH="$T/none" "$PY" "$TOOL" check "$T/meta.json" --pdf "$T/paper.pdf" --offline; has c23 "pdftotext is not installed"; [ $RC = 2 ] || fail 23; ok "a missing pdftotext is refused (status 2)"

! grep -rqF FAKETOKEN "$T/out" "$TR" "$T"/pk* || fail "a token leaked into an output, packet or transcript"; ok "no output, packet or transcript holds the fake token"
OUT=$(mktemp "${TMPDIR:-/tmp}/paper-publish-transcript.XXXXXX"); cp "$TR" "$OUT"; echo "transcript: $OUT"; echo "sha256: $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
