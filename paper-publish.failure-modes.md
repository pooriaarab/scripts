# paper-publish failure modes

`paper-publish` helps a person publish a paper fast. It makes a Zenodo draft, saves repos to Software Heritage, writes one submission packet per venue, and checks a paper before anyone submits. It never submits to a peer-reviewed venue. It never publishes a Zenodo record unless a person passes two flags.

The tests in `paper-publish.test.sh` run against a fake local server. They use no network and no real token. They cover each row marked "yes". The `meta.json` keys are `title` and `abstract` (strings), `authors` (a list of objects with `name`, `affiliation`, `orcid`), `license`, `keywords`, `subject_class`, `comments`, `code_url`, `data_url`, `data_concept_dois`, `related_identifiers`, and `venues` (a list of venue names). Each name in `venues` must match one venue in `paper-venues.json`. `packet` writes one file for each.

| # | Failure | Wanted behavior | Tested |
|---|---|---|---|
| 1 | `ZENODO_TOKEN` is not set. | Exit 2. Send no request. | yes |
| 2 | The token has a space, a control character such as a trailing `\r`, or a non-ASCII character. Or any other unexpected error. | Exit 2 at start and never show the value. For any other unexpected error: exit 1, pass the message through the token scrub, print no traceback. | yes |
| 3 | A person passes the token in argv, for example `--token X`. Or abbreviates a flag, for example `--pub`. | Exit 2. No such option exists. Abbreviations are off, so `--pub --i-confirm-permanent` cannot pass the publish gate. An argument error never repeats a value. | yes |
| 4 | An upstream error body repeats the Authorization header. An upstream redirects to another host. A response body links to another host. | Replace the token with `***`. Drop the header on a cross-host redirect. Refuse any link (bucket, latest_draft, self) that is not on the `ZENODO_BASE` origin, with exit 2. The test uses the bucket link. | yes |
| 5 | `--publish` without `--i-confirm-permanent`. | Print the exact title and file list. Exit 2. Send no request, not even the draft call. | yes |
| 6 | `--publish` with both flags. | Build the draft. Then send one publish call. | yes |
| 7 | A plain run. | Stop at a draft. The upstream never sees a publish call. Print the draft id and the preview URL. | yes |
| 8 | Zenodo answers 4xx, 5xx, a non-JSON body, or any status other than the one expected: 200 for lookups and metadata, 201 for create and new version, 200 or 201 for upload, 204 for delete, 202 for publish. | Exit 1. Name the step, the status, and the message. If the draft exists, name its id so a person can discard it. Do not retry. | yes, except a 3xx |
| 9 | A file is missing, or larger than the 50 GB Zenodo limit. | Exit 2 before any request. Name the file. | yes |
| 10 | `--new-version-of` names a concept id. | `GET /records/<concept>/versions/latest`, then `POST .../actions/newversion`, then fetch `links.latest_draft`. Remove the inherited files. Upload the new files. | yes |
| 11 | The server is unreachable. Or `meta.json` is not JSON, has a wrong type, or lacks title, abstract, authors, or license. | Exit 1 with `cannot reach` and the host, or exit 2 and say what is wrong. No traceback. | yes |
| 12 | Software Heritage answers 429, with a `Retry-After` that is missing, negative, or huge. | Wait for the `Retry-After` seconds, at most 60. Use 60 if the value is not a number or is negative. Retry the same call. A negative `--interval` or `--timeout` exits 2. | yes, except the cap and odd `Retry-After` values |
| 13 | A save request fails, is rejected, times out, or the answer has no request id or is not JSON. Or a URL is not http or https. | Print the status for that URL and go on. Exit 1 at the end. Refuse a bad URL with exit 2 before any request. Percent-encode the origin URL in the call. | yes, except the encoding and a non-JSON answer |
| 14 | `packet` names a venue that `paper-venues.json` does not list, or a name that matches several venues, for example `IEEE`. | Exit 2. Write no file. Do not invent a venue. Take an exact name first, else a unique prefix. If several venues match, list the candidate names. | yes |
| 15 | `packet` names two peer-reviewed venues. | Exit 2 and explain dual submission. `--allow-second-review-venue` lifts it. The checklist then carries a warning. | yes |
| 16 | The title differs in `meta.json`, on PDF page 1, or in `CITATION.cff`. | Exit 1. The title must equal the title block, which is the first 1 to 5 lines of page 1, after the same normalising of unicode, quotes, spaces and wrapped hyphens. A substring or a different case does not pass. In `CITATION.cff` only the top-level `title:` counts. | yes |
| 17 | A venue reviews blind and a person pastes the packet as is. | Each packet shows the venue's review mode and says to hide the authors and use anonymous links when it is blind. | yes |
| 18 | The text has `XXXX`, an em dash, a bad abstract length, a missing license, or a dead URL in the abstract, comments, `code_url` or `data_url`. | Exit 1. List every problem, not just the first. A check reads at most 1 byte of each URL body. | yes |
| 19 | An ORCID has a wrong checksum or shape. | Exit 1 in `check`. Exit 2 in `zenodo-draft`. No traceback. | yes |
| 20 | `--offline` is set. Or `pdftotext` is not installed. | Skip the URL requests and run every other check. Exit 2 and name the tool. | yes |
| 21 | Zenodo changes its API. | UNVERIFIED against a live deposit. The calls follow developers.zenodo.org. Only the read call `GET /records/<concept>/versions/latest` ran live, on 2026-10-16. Dry-run on `https://sandbox.zenodo.org/api` first. | no, needs a live token |
| 22 | A person trusts the packet and skips the venue page. Or asks the tool to click Submit, solve a CAPTCHA, or tick an agreement. | Every packet names its source and check date. There is no submit command. `CHECKLIST.md` lists those steps for a person. | no, a human rule |
