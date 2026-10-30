#!/usr/bin/env python3
"""Check ci-baseline without live GitHub calls: a fake `gh` answers from fixtures."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
FAKE_GH = """#!/usr/bin/env python3
import json, re, sys
path = sys.argv[2]
page = int(re.search(r"[&?]page=(\d+)", path).group(1))
if "/actions/runs?" in path:
    run = {"id": 1, "name": "CI", "event": "push", "created_at": "2026-10-30T10:00:00Z"}
    print(json.dumps({"workflow_runs": [run] if page == 1 else []}))
else:
    def job(i, conclusion="success", start="10:00:10", end="10:00:20"):
        return {"conclusion": conclusion, "created_at": "2026-10-30T10:00:00Z",
                "started_at": "2026-10-30T" + start + "Z", "completed_at": "2026-10-30T" + end + "Z"}
    if page == 1:
        jobs = [job(i) for i in range(100)]
    else:
        # one more real job, and a skipped job whose end is before its start
        jobs = [job(100), job(101, "skipped", "10:00:10", "10:00:09")]
    print(json.dumps({"jobs": jobs}))
"""


class CiBaseline(unittest.TestCase):
    def test_counts_every_page_and_ignores_skipped_jobs(self):
        with tempfile.TemporaryDirectory() as tmp:
            gh = Path(tmp) / "gh"
            gh.write_text(FAKE_GH)
            gh.chmod(0o755)
            env = {**os.environ, "PATH": f"{tmp}:{os.environ['PATH']}"}
            out = subprocess.run(
                ["python3", str(ROOT / "ci-baseline"), "o/r", "--json"],
                capture_output=True, text=True, env=env, check=True,
            ).stdout
        result = json.loads(out)
        self.assertEqual(result["jobs"], 101)  # 100 on page one, 1 real job on page two
        self.assertEqual(result["job_seconds"], 1010)
        self.assertGreaterEqual(result["median_run_s"], 0)


if __name__ == "__main__":
    unittest.main()
