#!/usr/bin/env bash
# End-to-end test for paper-publish. Covers every row marked "yes" in paper-publish.failure-modes.md.
# A fake Zenodo and a fake Software Heritage run on localhost. No network, no real token. Ends with a transcript path and its sha256.
set -euo pipefail; cd "$(dirname "$0")"
TOOL=./paper-publish PY=$(command -v python3) T=$(mktemp -d) pass=0
mkdir "$T/out"; TR=$T/transcript.txt; LOG=$T/server.log; : > "$LOG"
fail() { echo "FAIL - $1 (files in $T)" >&2; exit 1; }
ok() { pass=$((pass + 1)); echo "ok $pass - $1" | tee -a "$TR"; }

cat > "$T/fake.py" <<'EOF'
import http.server, json, re, sys, time
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
        L = B.replace("127.0.0.1", "localhost") if "OTHER" in tok else B.rsplit(":", 1)[0] + ":1" if "PORT" in tok else B  # a link on another host or port
        dep = lambda i: {"id": i, "conceptrecid": {"t": tok} if "OBJ" in tok else "110", "links": {"bucket": L + "/api/files/bkt%d" % i, "html": B + "/deposit/%d" % i + ("?t=" + tok if "ECHOOUT" in tok else "")},
                         "files": [{"id": "f1", "links": {"self": B + "/api/deposit/depositions/222/files/f1"}}] * (i == 222)}
        if p == "/headno": return self.send(405 if me == "HEAD" else 200, raw=b"x")  # a server that refuses HEAD
        if p in ("/ok", "/missing"): return self.send(200 if p == "/ok" else 404, raw=b"x")
        if "/swh/" in p:
            u = p.split("/url/", 1)[1]
            if me == "POST":
                if "ratelimited" in u and not ST.get("rl"): ST["rl"] = 1; return self.send(429, {}, hdr=[("Retry-After", "1")])
                if ("nanrl" in u or "infrl" in u) and not ST.get(u + "429"): ST[u + "429"] = 1; return self.send(429, {}, hdr=[("Retry-After", "nan" if "nanrl" in u else "inf")])
                if "noid" in u: return self.send(201, {})
                if "rejected" in u: return self.send(200, {"id": 9, "save_request_status": "rejected"})
                ST[u] = 0; return self.send(201, {"id": 7, "save_request_status": "accepted", "save_task_status": "pending"})
            ST[u] += 1
            t = "running" if ("hangs" in u or ST[u] < 2) else ("failed" if "fails" in u else "succeeded")
            return self.send(200, [{"id": 7, "save_request_status": "accepted", "save_task_status": t, "snapshot_swhid": "swh:1:snp:" + "a" * 40}])
        if re.search(r"-S\d+$", tok): return self.send(500, raw=("E" * int(tok.rsplit("S", 1)[1]) + " Bearer " + tok).encode())  # a token that straddles the 200 character cut
        if "ESC" in tok: return self.send(400, {"message": "bad", "errors": [{"field": "x", "message": tok}]})  # a token that JSON re-encodes
        if "NOLINKS" in tok and me == "POST": return self.send(201, {"id": 111})
        if "ECHO403" in tok: return self.send(403, {"message": "Invalid token " + tok})
        LK = {"UNI": lambda: ('["' + "".join("\\u%04x" % ord(c) for c in tok) + '"]').encode(), "SLASH": lambda: ('{"message": "bad %s"}' % tok.replace("/", "\\/")).encode(),
              "DQ": lambda: json.dumps({"message": "bad", "errors": [json.dumps({"m": tok})]}).encode(), "NSM": lambda: b'{"message": {"a": 1}}', "DEEP": lambda: b"[" * 100000}
        if re.search(r"-(UNI|SLASH|DQ|NSM|DEEP)", tok): return self.send(400, raw=LK[re.search(r"-(UNI|SLASH|DQ|NSM|DEEP)", tok).group(1)]())
        if "NOHTML" in tok and me == "POST" and p == "/api/deposit/depositions": d = dep(111); del d["links"]["html"]; return self.send(201, d)
        if "PUB500" in tok and p.endswith("/actions/publish"): return self.send(500, raw=b"boom")
        if "NV500" in tok and me == "GET" and p == "/api/deposit/depositions/222": return self.send(500, raw=b"boom")
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
    do_GET = do_HEAD = do_POST = do_PUT = do_DELETE = do
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H); open(sys.argv[1], "w").write(str(s.server_port)); s.serve_forever()
EOF
$PY "$T/fake.py" "$T/port" "$LOG" & SRV=$!
trap 'rc=$?; kill $SRV 2>/dev/null; wait $SRV 2>/dev/null || :; [ $rc = 0 ] && rm -rf "$T"; true' EXIT
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done; PORT=$(cat "$T/port") B=http://127.0.0.1:$(cat "$T/port")
export ZENODO_BASE=$B/api SWH_BASE=$B/swh/api/1 ZENODO_TOKEN=FAKETOKEN-ok

# fixtures: a PDF and a tarball (fake bytes), and a meta file
echo "fake pdf bytes" > "$T/paper.pdf"; echo "fake tarball bytes" > "$T/paper.tar.gz"
cat > "$T/meta.json" <<EOF
{"title": "A Test Title For Benchmarks", "license": "cc-by-4.0", "keywords": ["benchmark"], "subject_class": "cs.AI", "comments": "10 pages",
 "abstract": "A test abstract for the paper. It has one sentence about the paper and one about the data.",
 "authors": [{"name": "Arab, Pooria", "affiliation": "Independent", "orcid": "0000-0002-1825-0097"}], "venues": ["arXiv", "Zenodo", "TMLR"],
 "code_url": "https://github.com/o/r", "data_concept_dois": ["10.5281/zenodo.110"]}
EOF
mm() { $PY -c 'import json,sys; m = json.load(open(sys.argv[1])); exec(sys.argv[3]); json.dump(m, open(sys.argv[2], "w"))' "$T/meta.json" "$T/$1" "$2"; }
# run NAME "what it does" CMD...  sets RC, saves the output, appends a normalised copy to the transcript
run() {
  local n=$1 d=$2; shift 2; : > "$LOG"
  set +e; "$@" > "$T/out/$n" 2>&1; RC=$?; set -e
  { echo "## $n: $d (exit $RC)"; sed -e "s#$T#\$T#g" -e "s#127.0.0.1:$PORT#HOST#g" -e "s#localhost:$PORT#HOST#g" "$T/out/$n"; } >> "$TR"
}
has() { grep -qF -- "$2" "$T/out/$1" || fail "$1 lacks: $2"; }; calls() { grep -c -- "$1" "$LOG" || true; }; quiet() { [ ! -s "$LOG" ] || fail "$1 sent a request"; }
Z="$TOOL zenodo-draft --pdf $T/paper.pdf --tarball $T/paper.tar.gz --meta $T/meta.json"

run r1 "no token" env -u ZENODO_TOKEN $Z; has r1 "ZENODO_TOKEN is not set"; quiet 1; [ $RC = 2 ] || fail 1; ok "missing token is refused (status 2) and sends nothing"
run r2 "token in argv" $Z --token FAKETOKEN-argv; has r2 "bad arguments"; quiet 2; [ $RC = 2 ] || fail 2; ok "a token in argv is refused and not repeated"
run r2b "abbreviated flags" $Z --pub --i-confirm-permanent; has r2b "bad arguments"; quiet 2b; [ $RC = 2 ] || fail 2b; ok "an abbreviated --publish cannot pass the gate"
run r1b "token with a trailing CR" env ZENODO_TOKEN=$'FAKETOKEN-bad\r' $Z; has r1b "ZENODO_TOKEN has a space"; quiet 1b; ! grep -q Traceback "$T/out/r1b" && [ $RC = 2 ] || fail 1b
run r1c "a base URL that makes urllib raise" env ZENODO_BASE='http://[::1' $Z; has r1c "unexpected problem"; ! grep -q Traceback "$T/out/r1c" && [ $RC = 1 ] || fail 1c; ok "a bad token is refused, and any other error ends without a traceback"
run r3 "upstream echoes the token in a 403" env ZENODO_TOKEN=FAKETOKEN-ECHO403 $Z; has r3 "Zenodo create draft failed: HTTP 403: Invalid token ***"; [ $RC = 1 ] || fail 3; ok "an echoed token becomes *** and a 4xx names the step and status"
for w in OTHER PORT; do run r3b$w "a link on another $w" env ZENODO_TOKEN=FAKETOKEN-$w $Z; has r3b$w "is not on the ZENODO_BASE host"; [ $RC = 2 ] && [ "$(calls 'PUT /api/files')" = 0 ] || fail 3b$w; done
run r3c "plain http to another host" env ZENODO_BASE=http://sandbox.zenodo.org/api $Z; has r3c "must be https"; quiet 3c; [ $RC = 2 ] || fail 3c; ok "a response link on another host or port gets no token and no upload, and a plain http base to another host is refused"
for n in 183 186 190 191; do run rA$n "token straddles the cut at $n" env ZENODO_TOKEN=FAKETOKEN-S$n $Z; has rA$n "HTTP 500"; ! grep -q "FAKE\|Bearer [A-Za-z]" "$T/out/rA$n" && [ $RC = 1 ] || fail "A $n"; done; ok "a token split by the 200 character cut shows no prefix"
run r4 "publish without confirmation" $Z --publish; has r4 "title: A Test Title For Benchmarks"; has r4 "paper.tar.gz ("; has r4 refused; quiet 4; [ $RC = 2 ] || fail 4; ok "--publish alone prints title and files, refuses, sends nothing"
run r5 "publish with both flags" $Z --publish --i-confirm-permanent; has r5 "PUBLISHED. doi: 10.5072/zenodo.111"; [ $RC = 0 ] && [ "$(calls actions/publish)" = 1 ] || fail 5; [ "$(grep -n 'PUT /api/deposit/depositions/111 ' "$LOG" | cut -d: -f1)" -lt "$(grep -n actions/publish "$LOG" | cut -d: -f1)" ] || fail "5 order"; ok "publish happens once, after the metadata"
run r6 "plain run with a community" $Z --community test-comm; has r6 "draft id: 111"; has r6 "preview: $B/deposit/111"; [ $RC = 0 ] && [ "$(calls actions/publish)" = 0 ] || fail 6
$PY - "$LOG.meta" "https://github.com/o/r" <<'EOF' || fail "6 metadata"
import json, sys
md = json.load(open(sys.argv[1]))["metadata"]; rel = {(r["identifier"], r["resource_type"]) for r in md["related_identifiers"]}
assert (md["upload_type"], md["publication_type"]) == ("publication", "preprint") and md["communities"] == [{"identifier": "test-comm"}], md
assert md["creators"][0]["orcid"] == "0000-0002-1825-0097" and {(sys.argv[2], "software"), ("10.5281/zenodo.110", "dataset")} <= rel, rel
EOF
ok "a plain run stops at a draft with the right metadata and never publishes"
run r7b "stdout echoes the token" env ZENODO_TOKEN=FAKETOKEN-ECHOOUT $Z; has r7b "preview: $B/deposit/111?t=***"; [ $RC = 0 ] || fail 7b; ok "the printed preview URL is scrubbed too"
run r7c "a token with a quote and a backslash in a JSON error" env ZENODO_TOKEN='FAKETOKEN-ESC"q\z' $Z; has r7c "HTTP 400"; ! grep -q FAKE "$T/out/r7c" && [ $RC = 1 ] || fail 7c; ok "a token that a JSON message re-encodes is scrubbed too"
run r7d "a 201 with no links" env ZENODO_TOKEN=FAKETOKEN-NOLINKS $Z; has r7d "Draft 111 exists and is NOT published"; ! grep -q Traceback "$T/out/r7d" && [ $RC = 1 ] || fail 7d; ok "any error after the draft exists names the draft"
i=0; for tk in 'FAKETOKEN-UNI' 'FAKETOKEN-SLASH/x' 'FAKETOKEN-DQ"x' FAKETOKEN-NSM FAKETOKEN-DEEP; do i=$((i + 1)); run lk$i "a hostile error body, form $i" env ZENODO_TOKEN="$tk" $Z; has lk$i "HTTP 400"; ! grep -q "FAKE\|unexpected problem\|Traceback" "$T/out/lk$i" && [ $RC = 1 ] || fail "leak form $i"; done
run ob "an object concept id" env ZENODO_TOKEN=FAKETOKEN-OBJ $Z; has ob "concept id: {'t': '***'}"; [ $RC = 0 ] || fail ob; ok "a token is hidden when a body is not an object, is escaped, nests JSON, or is the concept id, and an odd message or a deep body still gives HTTP 400"
run d1 "new-version draft fetch fails" env ZENODO_TOKEN=FAKETOKEN-NV500 $Z --new-version-of 110; has d1 "Draft 222 exists and is NOT published"; [ $RC = 1 ] || fail d1
run d2 "a draft without html" env ZENODO_TOKEN=FAKETOKEN-NOHTML $Z; has d2 "Draft 111 exists and is NOT published"; [ $RC = 1 ] || fail d2
run d3 "the publish call fails" env ZENODO_TOKEN=FAKETOKEN-PUB500 $Z --publish --i-confirm-permanent; has d3 "Draft 111 exists. The publish call failed"; [ $RC = 1 ] || fail d3; ok "a draft that exists is named after a failed draft fetch, a missing html, and a failed publish call"
run r8 "500 after the draft exists" env ZENODO_TOKEN=FAKETOKEN-FAIL500 $Z; has r8 "HTTP 500: <html>boom"; has r8 "Draft 111 exists and is NOT published"; [ $RC = 1 ] || fail 8; ok "a 5xx after the draft names the draft id"
$PY -c "open('$T/big.pdf','wb').truncate(51*1024**3)"
for f in none big; do run r9$f "unusable PDF $f" $TOOL zenodo-draft --pdf "$T/$f.pdf" --tarball "$T/paper.tar.gz" --meta "$T/meta.json"; has r9$f "missing or larger than the 50 GB"; quiet 9$f; [ $RC = 2 ] || fail 9$f; done
rm -f "$T/big.pdf"; ok "a missing or oversize file is refused (status 2) before any request"
run r10 "new version of concept 110" $Z --new-version-of 110; has r10 "draft id: 222"; [ $RC = 0 ] && [ "$(calls 'DELETE /api/deposit/depositions/222/files/f1')" = 1 ] || fail 10; [ "$(calls 'PUT /api/files/bkt222/')" = 2 ] && [ "$(calls 'POST /api/deposit/depositions ')" = 0 ] || fail "10 files"; ok "--new-version-of opens a new draft, removes the old file, uploads two new ones"
run r10b "a redirect to another host" $Z --new-version-of 301; [ $RC = 0 ] && grep -q "GET /api/records/301/versions/latest 0 auth" "$LOG" && grep -q "GET /api/records/110/versions/latest 0 noauth" "$LOG" || fail "10b token followed a redirect"; ok "a redirect to another host drops the Authorization header"
run r11 "server not reachable" env ZENODO_BASE=http://127.0.0.1:9/api $Z; has r11 "cannot reach 127.0.0.1:9: Connection refused"; ! grep -q Traceback "$T/out/r11" && [ $RC = 1 ] || fail 11; ok "an unreachable server gives a clear message"
mm nolic.json 'del m["license"]'; mm bt.json 'm["title"] = 5'; mm dc.json 'm["data_concept_dois"] = "10.5281/zenodo.1"'; mm ri.json 'm["related_identifiers"] = None'; echo '[1]' > "$T/arr.json"; $PY -c 'print("[" * 100000)' > "$T/deep.json"; echo '{bad' > "$T/bad.json"
for pair in "nolic.json|lacks: license" "bad.json|cannot read" "bt.json|wrong type" "dc.json|wrong type" "ri.json|wrong type" "arr.json|the top level is not an object" "deep.json|recursion"; do f=${pair%%|*}
  run r12$f "bad meta $f" $TOOL zenodo-draft --pdf "$T/paper.pdf" --tarball "$T/paper.tar.gz" --meta "$T/$f"; has r12$f "${pair#*|}"; [ $RC = 2 ] || fail "12 $f"; done
mm bs.json 'm["venues"] = "TMLR"'; run r12p "venues as a string" $TOOL packet "$T/bs.json" --out "$T/pk12"; has r12p "wrong type"; [ $RC = 2 ] || fail 12p; ok "a bad, incomplete or wrongly typed meta.json is refused (status 2)"

S="$TOOL swh-save --interval 0.05 --timeout 1"
run s13 "rate limited once" $S https://github.com/x/ratelimited; t=($(grep POST "$LOG" | cut -d' ' -f1)); has s13 "ratelimited	succeeded	swh:1:snp:aaaaaaaa"; has s13 "waiting 1s"; [ $RC = 0 ] && [ ${#t[@]} = 2 ] || fail 13
$PY -c "import sys; sys.exit(0 if ${t[1]} - ${t[0]} >= 1 else 1)" || fail "waited less than Retry-After"; ok "a 429 waits for Retry-After and retries"
run s13b "Retry-After nan and inf" $S https://github.com/x/nanrl https://github.com/x/infrl; has s13b "nanrl	succeeded"; has s13b "infrl	succeeded"; has s13b "waiting 0s"; ! grep -q Traceback "$T/out/s13b" && [ $RC = 0 ] || fail "13b"; ok "a Retry-After of nan or inf waits 0 and does not raise"
run s14 "failed, rejected, timeout, success" $S https://github.com/x/fails https://github.com/x/rejected https://github.com/x/hangs https://github.com/x/fine https://github.com/x/noid
has s14 "no usable request id"; has s14 "fails	failed"; has s14 "rejected	rejected"; has s14 "hangs	timeout (still running)"; has s14 "fine	succeeded"; [ $RC = 1 ] || fail 14; ok "each URL gets a status and the run ends with status 1"
run s15 "ftp URL" $S ftp://example.org/x; quiet 15; [ $RC = 2 ] || fail 15; run s15b "negative interval" $TOOL swh-save --interval -1 https://github.com/x/fine; quiet 15b; [ $RC = 2 ] || fail 15b; ok "a non-http URL is refused (status 2) before any request"

P="$TOOL packet"
mm unk.json 'm["venues"] = ["Nonexistent Journal of Nothing"]'; run k16 "unknown venue" $P "$T/unk.json" --out "$T/pk16"; has k16 "does not invent venues"; [ $RC = 2 ] && [ ! -e "$T/pk16" ] || fail 16; ok "a shortlist name for a journal counts, a row that cannot be told is refused beside a peer-reviewed venue, and an unknown, ambiguous or repeated venue is refused (status 2) and writes nothing, and only a journal or conference counts as peer review, not a forum"
mm ieee.json 'm["venues"] = ["IEEE"]'; run k16b "an ambiguous venue" $P "$T/ieee.json" --out "$T/pk16b"; has k16b "matches"; has k16b "IEEE Computer"; [ $RC = 2 ] && [ ! -e "$T/pk16b" ] || fail "16b"
mm dup.json 'm["venues"] = ["arXiv", "arXiv (cs.AI, cs.CL, cs.LG)"]'; run k16c "the same venue under two names" $P "$T/dup.json" --out "$T/pk16c"; has k16c "listed twice"; [ $RC = 2 ] && [ ! -e "$T/pk16c" ] || fail "16c"
mm mix.json 'm["venues"] = ["arXiv", "NeurIPS 2026 Evaluations & Datasets", "Alignment Forum"]'; run k16e "one review venue, a preprint server and a forum" $P "$T/mix.json" --out "$T/pk16e"; [ $RC = 0 ] && grep -q "Alignment Forum: not peer review" "$T/pk16e/CHECKLIST.md" && grep -q "NeurIPS 2026 Evaluations & Datasets: peer-reviewed" "$T/pk16e/CHECKLIST.md" || fail "16e"
mm pci.json 'm["venues"] = ["TMLR", "Peer Community In (PCI)"]'; run k16d "Peer Community In counts as peer review" $P "$T/pci.json" --out "$T/pk16d"; has k16d "dual submission"; [ $RC = 2 ] || fail "16d"
mm ims.json 'm["venues"] = ["TMLR", "IEEE Intelligent Systems"]'; run k16f "TMLR and a peer-reviewed society magazine" $P "$T/ims.json" --out "$T/pk16f"; has k16f "dual submission"; [ $RC = 2 ] || fail 16f
mm isw.json 'm["venues"] = ["ICLR 2027", "IEEE Software"]'; run k16g "ICLR and a peer-reviewed society magazine" $P "$T/isw.json" --out "$T/pk16g"; has k16g "dual submission"; [ $RC = 2 ] || fail 16g
mm cl.json 'm["venues"] = ["TMLR", "Computational Linguistics (MIT Press for ACL)"]'; run k16h "TMLR and the shortlist row for a journal" $P "$T/cl.json" --out "$T/pk16h"; has k16h "dual submission"; [ $RC = 2 ] || fail 16h
printf '[{"name":"TMLR","kind":"listed","source_file":"a","section":"s","checked":"1","fields":{"type":"journal"}},{"name":"Mystery","kind":"listed","source_file":"a","section":"s","checked":"1","fields":{"need":"x"}},{"name":"Prep","kind":"listed","source_file":"a","section":"s","checked":"1","fields":{"type":"preprint"}}]' > "$T/pv.json"
mm my.json 'm["venues"] = ["TMLR", "Mystery"]'; mm my1.json 'm["venues"] = ["Prep", "Mystery"]'; export PAPER_VENUES=$T/pv.json
run k16i "a row that cannot be told, with a journal" $P "$T/my.json" --out "$T/pk16i"; has k16i "cannot tell if Mystery is peer reviewed"; [ $RC = 2 ] && [ ! -e "$T/pk16i" ] || fail 16i
run k16j "the same, allowed" $P "$T/my.json" --out "$T/pk16j" --allow-second-review-venue; [ $RC = 0 ] || fail 16j; run k16k "a row that cannot be told, alone with a preprint server" $P "$T/my1.json" --out "$T/pk16k"; grep -q "Mystery: peer review unknown" "$T/pk16k/CHECKLIST.md" && [ $RC = 0 ] || fail 16k; unset PAPER_VENUES
mm two.json 'm["venues"] = ["TMLR", "DMLR"]'; run k17 "two peer-reviewed venues" $P "$T/two.json" --out "$T/pk17"; has k17 "dual submission"; [ $RC = 2 ] && [ ! -e "$T/pk17" ] || fail "17 refuse"
run k17b "two venues, allowed" $P "$T/two.json" --out "$T/pk17" --allow-second-review-venue; [ $RC = 0 ] && grep -q "WARNING: this packet has 2" "$T/pk17/CHECKLIST.md" || fail "17 allow"; ok "two review venues are refused, and the flag adds a warning to the checklist"
run k18 "arXiv, Zenodo, TMLR" $P "$T/meta.json" --out "$T/pk18"; [ $RC = 0 ] && [ "$(ls "$T/pk18" | tr '\n' ' ')" = "CHECKLIST.md arxiv.md tmlr.md zenodo.md " ] || fail "18 files"; grep -q "CAPTCHA" "$T/pk18/CHECKLIST.md" && grep -q "ONE peer-reviewed" "$T/pk18/CHECKLIST.md" || fail "18 checklist"
grep -q "Review mode: double-blind" "$T/pk18/tmlr.md" && grep -q "0000-0002-1825-0097" "$T/pk18/arxiv.md" || fail "18 review mode"; mm ex.json 'm["venues"] = ["arXiv (cs.AI, cs.CL, cs.LG)"]'; run k18b "an exact venue name" $P "$T/ex.json" --out "$T/pk18b"; [ $RC = 0 ] && [ -e "$T/pk18b/arxiv-cs-ai-cs-cl-cs-lg.md" ] || fail "18b"
ok "one file per venue with its review mode, plus a checklist of manual steps, and an exact full name works"

mm orc.json 'm["authors"][0]["orcid"] = "0000-0002-1825-0098"'; mm orc2.json 'm["authors"][0]["orcid"] = "abc"'
for f in orc orc2; do run o$f "bad ORCID $f" $TOOL zenodo-draft --pdf "$T/paper.pdf" --tarball "$T/paper.tar.gz" --meta "$T/$f.json"; has o$f "bad ORCID"; quiet $f; ! grep -q Traceback "$T/out/o$f" && [ $RC = 2 ] || fail "orcid $f"; done
ok "a bad ORCID, by checksum or by shape, is refused (status 2) before any request and without a traceback"
# check needs an abstract of 100 characters or more and a code_url that answers, so it gets its own meta file
mm ck.json 'm["abstract"] = "A test abstract for the paper. It is long enough to pass the length check and links to '$B'/ok for the code."; m["code_url"] = "'$B'/ok"'; cp "$T/ck.json" "$T/meta.json"
# check: the title block comes from the text layout of real PDFs (a tectonic-built paper with a two-line title, a \thanks title, and the real paper when it is here), plus hand-made PDFs for sizes
mkpdf() { f=$1; shift; s="BT /F1 20 Tf 72 700 Td ($1) Tj ET"$'\n'; shift; y=660; for l in "$@"; do s+="BT /F1 10 Tf 72 $y Td ($l) Tj ET"$'\n'; y=$((y - 14)); done
  printf '%%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj\n4 0 obj<</Length %d>>stream\n%sendstream endobj\n5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\ntrailer<</Size 6/Root 1 0 R>>\n%%%%EOF\n' "${#s}" "$s" > "$f"; }
REAL=$PWD/paper-publish.fixture.pdf THX=$PWD/paper-publish.thanks.pdf TITLE="A Test Title For Benchmarks"; W="Agents Can Build Benchmarks. Approvals Missed What Probing Found: 22 Cases"
tc() { e=$1; export TT=$3; mm t.json 'm["title"] = __import__("os").environ["TT"]'; run tc "title $e: $3" $TOOL check "$T/t.json" --pdf "$2" --offline; [ $RC = $e ] || fail "title $e: [$3] vs $2"; }
cases() { tc 0 "$1" "$W"; tc 0 "$1" "Agents Can Build Benchmarks.   Approvals Missed What Probing Found: 22 Cases"
  for x in "${W/22 Cases/23 Cases}" "$W Today" "${W% Cases}" "Approvals Missed Agents Can Build Benchmarks. What Probing Found: 22 Cases" "We report 22 agent benchmarks built by AI coding agents on one shared TypeScript engine." Agents "22 Cases" "" "   " "Agents Can Build Benchmarks. Approvals Missed" "What Probing Found: 22 Cases" "Pooria Arab" Abstract; do tc 1 "$1" "$x"; done; }
cases "$REAL"; BFP=${BFP:-/tmp/benchmark-family-paper.pdf}  # the same cases on the real paper PDF when it is here, kept out of the transcript so the hash stays the same
if [ -f "$BFP" ]; then cp "$TR" "$TR.keep"; cases "$BFP"; mv "$TR.keep" "$TR"; else echo "notice: $BFP is absent, so the real paper cases are skipped" >&2; fi
tc 0 "$THX" "Robust Agents for Benchmark Probing"; tc 1 "$THX" "Robust Agents for Benchmark Probing Today"
mkpdf "$T/caps.pdf" "A TEST TITLE FOR BENCHMARKS" "Pooria Arab" Abstract; mkpdf "$T/llama.pdf" "A Study Of Models vs. Llama 3" "Pooria Arab"; mkpdf "$T/sup.pdf" "${TITLE}1" "Pooria Arab"; mkpdf "$T/star.pdf" "$TITLE*" "Pooria Arab"
tc 0 "$T/caps.pdf" "$TITLE"; tc 1 "$T/llama.pdf" "A Study Of Models vs. Llama"; tc 0 "$T/llama.pdf" "A Study Of Models vs. Llama 3"; tc 0 "$T/sup.pdf" "$TITLE"; tc 0 "$T/star.pdf" "$TITLE"
echo "not a pdf" > "$T/bad.pdf"; run cb "no text layout" $TOOL check "$T/meta.json" --pdf "$T/bad.pdf" --offline; has cb "cannot find the title block"; [ $RC = 1 ] || fail cb
run cn "no pdftotext" env PATH="$T/none" "$PY" "$TOOL" check "$T/meta.json" --pdf "$REAL" --offline; has cn "pdftotext is not installed"; [ $RC = 2 ] || fail cn
ok "the title must equal the title block of a real PDF: the true title passes, and a changed, extra, missing, reordered, abstract, partial, author, empty or blank title fails; a footnote mark, a superscript digit and an all-caps block pass; Llama 3 is not Llama"
cc() { run cff$2 "CITATION.cff $2" $TOOL check "$T/meta.json" --cff "$T/c$2.cff" --offline; [ $RC = $1 ] || fail "cff $2"; }
printf 'title: "A Test Title For Benchmarks"  # note\nversion: 1\n' > "$T/c1.cff"; printf '\xef\xbb\xbftitle: A Test Title For Benchmarks # note\n' > "$T/c2.cff"; printf 'title: >-\n  A Test Title\n  For Benchmarks\nversion: 1\n' > "$T/c3.cff"
printf 'title: |\n  A Test Title For Benchmarks\n' > "$T/c4.cff"; printf 'title: "a test title for benchmarks"\n' > "$T/c5.cff"; printf 'cff-version: 1.2.0\nreferences:\n  - type: article\n    title: "A Test Title For Benchmarks"\n' > "$T/c6.cff"
printf 'cff-version: 1.2.0\ntitle: "benchmark-family-paper"\ntype: software\npreferred-citation:\n  type: article\n  title: "A Test Title For Benchmarks"\n  authors:\n    - family-names: Arab\n' > "$T/c7.cff"; printf 'preferred-citation:\n  type: article\ntitle: "A Test Title For Benchmarks"\n' > "$T/c8.cff"; mm bf.json 'm["title"] = "benchmark-family-paper"'
run c7b "the software name is not the paper title" $TOOL check "$T/bf.json" --cff "$T/c7.cff" --offline; has c7b "CITATION.cff title"; [ $RC = 1 ] || fail c7b
for c in 1 2 3 4 7 8; do cc 0 $c; done; for c in 5 6; do cc 1 $c; done; ok "a CITATION.cff preferred-citation title is the one compared, as in benchmark-family-paper, else the top-level title; a title is read when quoted, folded, literal, with a comment or a BOM, and fails on a different case or a nested title"
mm u.json 'm["code_url"] = "'$B'/missing"; m["data_url"] = "'$B'/missing2"; m["comments"] = "see http://x.com:abc/ and '$B'/headno"'; run cu "dead, malformed and HEAD-refusing URLs" $TOOL check "$T/u.json"
has cu "missing "; has cu "missing2"; has cu "x.com:abc"; ! grep -q "headno" "$T/out/cu" && [ $RC = 1 ] || fail cu; run co "offline" $TOOL check "$T/u.json" --offline; quiet co; [ $RC = 0 ] || fail co
ok "a dead or malformed URL is one problem and the run goes on, a server that refuses HEAD gets a GET, and --offline sends nothing"
mm multi.json 'm["abstract"] = "Short XXXX \u2014 see x"; del m["license"]'; run cm "many problems" $TOOL check "$T/multi.json" --offline; has cm "abstract has"; has cm "XXXX"; has cm "em dash"; has cm "needs a title and a license"; [ $RC = 1 ] || fail cm
for f in orc orc2; do run co$f "bad ORCID $f" $TOOL check "$T/$f.json" --offline; has co$f "bad ORCID"; ! grep -q Traceback "$T/out/co$f" && [ $RC = 1 ] || fail "check $f"; done
run ct "title as a number" $TOOL check "$T/bt.json" --offline; has ct "wrong type"; [ $RC = 2 ] || fail ct; ok "every text problem is listed, a bad ORCID is a problem, and a title that is not a string is refused"
# the verdict of every venue and of every row with no type goes into the transcript, so the hash covers it
$PY - <<'EOF' | tee -a "$TR" || fail "venue verdicts"
import importlib.machinery, json
pp = importlib.machinery.SourceFileLoader("pp", "./paper-publish").load_module(); recs = json.load(open("paper-venues.json")); v = {}
for r in recs:
    if r["kind"] != "avoid": v.setdefault(r["name"], pp.resolve(r["name"], recs)[1])
print("venue verdicts: %d venues, %d peer-reviewed" % (len(v), sum(bool(x) for x in v.values())))
for n in sorted(v): print("  %-14s %s" % ({True: "PEER-REVIEWED", False: "no", None: "UNKNOWN"}[v[n]], n[:100]))
want = {"IEEE Computer": 1, "IEEE Software": 1, "IEEE Intelligent Systems": 1, "IEEE Security & Privacy": 1, "IEEE Computing in Science": 1, "MSR 2027 Mining Challenge (papers)": 1, "Communications of the ACM (CACM)": 1, "TMLR": 1, "Peer Community In": 1,
        "Substack (self-publish)": 0, "LessWrong": 0, "Hugging Face community blog": 0, "IEEE Spectrum (Expert Authors)": 0, "MIT Technology Review": 0, "arXiv": 0, "Alignment Forum": 0, "InfoQ": 0}
assert not {q: pp.resolve(q, recs)[1] for q, e in want.items() if pp.resolve(q, recs)[1] != bool(e)}, "named venues"
T = ["TMLR", "DMLR", "JMLR MLOSS", "JOSS", "JAIR", "TACL", "ReScience C", "Journal of Open Research Software", "Computational Linguistics (MIT", "Computo", "Communications of the ACM, Practice", "AI Magazine (AAAI)", "Empirical Software Engineering, Machine", "All ACM journals", "New journal, no charge"]
F = ["Research Square", "SSRN (Computer", "Cambridge Open", "Preprints.org", "Wiley Research", "Zenodo (paper copy)", "Figshare", "Hugging Face dataset", "Software Heritage", "How a community", "A community for", "Put a record", "IEEE Spectrum (freelance", "Substack, LessWrong"]
nt = {r["name"]: pp.is_review(r, recs) for r in recs if r["kind"] != "avoid" and "type" not in r["fields"]}
print("rows with no type: %d" % len(nt))
for n in sorted(nt): print("  %-14s %s" % (nt[n], n[:90]))
assert len(nt) == len(T) + len(F) and all((sum(n.startswith(w) for w in T) == 1 and nt[n] is True) or (sum(n.startswith(w) for w in F) == 1 and nt[n] is False) for n in nt), "no-type rows"
mk = lambda s: {"name": "X", "kind": "listed", "section": "s", "source_file": "f", "fields": {"type": "journal", "review": s}}
for s in ["no peer review", "non-peer-reviewed", "without peer review", "unrefereed", "non-refereed", "Peer review: none", "Not peer reviewed"]: assert pp.is_review(mk(s)) is False, s
assert pp.is_review(mk("peer-reviewed")) is True
print("words that deny peer review: 7 checked")
EOF
ok "every venue has a verdict from its own words, every row with no type is asserted, and words that deny peer review count as not peer-reviewed"
! grep -rqF FAKETOKEN "$T/out" "$TR" "$T"/pk* || fail "a token leaked into an output, packet or transcript"; ok "no output, packet or transcript holds the fake token"
OUT=$(mktemp "${TMPDIR:-/tmp}/paper-publish-transcript.XXXXXX"); cp "$TR" "$OUT"; echo "transcript: $OUT"; echo "sha256: $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
