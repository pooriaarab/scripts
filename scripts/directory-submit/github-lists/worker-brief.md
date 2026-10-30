# Worker brief: prepare GitHub list submissions for the directory fleet

You run on a Box. You have `git`, `node`, `python3` and `curl`.
You have NO credentials to use. Do not look through environment variables, config files or token stores.
Do not try any token you find. You do not fork, push or open a PR. You prepare patches. A person files them.
Public repos clone with no login: `git clone --depth 1 https://github.com/<owner>/<repo>`.

## Goal
`SHARD` (a JSON file path given in your prompt) lists targets: public GitHub repos or issue forms that
accept new entries for free. For each target, prepare the change for each fleet site that fits.
The sites are 17 niche directories. Their public facts are in `/home/user/facts.json` (name, domain, url, tagline, short and long description, tags, MCP endpoint, API, llms.txt).
Read that file. The fleet template repository is private: do not try to clone it. Each site's own pages at its domain are public if you need more.

## Rules
1. Read the target's `CONTRIBUTING`, README and the last 10 merged PRs (use the public GitHub web pages via curl, or
   `git log` in your clone) before you edit. Copy the exact entry format, sort order and title style.
   Edit only the file the rules name.
2. Fit check. Add a site only if the list's scope honestly covers it (for example an MCP list takes a site that ships an MCP server;
   an OSINT list does not take a dating-coach site). If a site does not fit, record `skipped` with the reason. Never stretch a description.
3. One link per PR is common. Respect it: prepare one change per site where the rules say so, and never more than 3 per repo.
   For the others, record `skipped` with reason `one entry per PR rule, retry later`.
4. For each change, work in a fresh public clone of the upstream repo. Do not commit.
   Save these files under `~/out/<shard name>/<repo>-<site>/`:
   - `change.patch`: the output of `git diff` against the base commit (a plain diff, no author, no commit)
   - `pr.json`: `{"upstream": "owner/repo", "base": "<default branch>", "base_sha": "<sha>", "branch": "add-<site>", "title": "...", "body": "..."}`
   PR title and body: plain and short. Say what the site is, that it is free, and give the URL. No marketing words.
   If the repo asks for disclosure of AI help, put that in the body. If the repo bans AI-assisted PRs, record `blocked` with that reason.
5. For an issue-form target (`method: github-issue`), save `issue.json`: `{"upstream": "owner/repo", "title": "...", "body": "..."}`
   using the form's fields. If the form needs a browser to submit, record `blocked`.
6. Check each patch: `git apply --check` against a fresh clone must succeed.
7. Never print or write a secret. Never put an email address in a patch or a PR body, except a contact address a list entry format requires and that the site itself publishes.
8. Stop after 60 minutes or when the shard is done.

## Output
Append one JSON line per (target, site) pair to `~/results/<shard name>.jsonl`:

    {"target": "<name exactly as in the shard>", "site": "<site slug>", "status": "ready|blocked|skipped",
     "dir": "<the ~/out path, or empty>", "reason": "<one short sentence>"}

`ready` needs a patch that passes `git apply --check`. A target you did not reach gets no line.
At the end, print the counts and the file path.
