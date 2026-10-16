# paper-publish failure modes

`paper-publish` helps a person publish a paper fast. It makes a Zenodo draft, saves repos to Software Heritage, writes one submission packet per venue, and checks a paper before anyone submits. It never submits to a peer-reviewed venue. It never publishes a Zenodo record unless a person passes two flags.

The tests in `paper-publish.test.sh` run against a fake local server. They use no network and no real token. They cover each row marked "yes". The `meta.json` keys are `title`, `abstract`, `authors` (`name`, `affiliation`, `orcid`), `license`, `keywords`, `subject_class`, `comments`, `code_url`, `data_url`, `data_concept_dois`, `related_identifiers`, and `venues`. Each name in `venues` must match a venue in `paper-venues.json`. `packet` writes one file for each.

| # | Failure | Wanted behavior | Tested |
|---|---|---|---|
| 1 | `ZENODO_TOKEN` is not set, or a person passes the token in argv, for example `--token X`. | Exit 2. Send no request. No such option exists, and the error does not repeat the value. | yes |
| 2 | An upstream error body repeats the Authorization header, or an upstream redirects to another host. | Replace the token with `***` in every message. Drop the header on a cross-host redirect. The token never reaches a file. | yes |
| 3 | `--publish` without `--i-confirm-permanent`. | Print the exact title and file list. Exit 2. Send no request, not even the draft call. | yes |
| 4 | `--publish` with both flags. | Build the draft. Then send one publish call. | yes |
| 5 | A plain run. | Stop at a draft. The upstream never sees a publish call. Print the draft id and the preview URL. | yes |
| 6 | Zenodo answers 4xx, for example 403 on create. | Exit 1. Name the step, the status, and the Zenodo message. | yes |
| 7 | Zenodo answers 5xx or a non-JSON body after the draft exists. | Exit 1. Name the draft id so a person can discard it. Do not retry. | yes |
| 8 | A file is missing, or larger than the 50 GB Zenodo limit. | Exit 2 before any request. Name the file. | yes |
| 9 | `--new-version-of` names a concept id. | Find the latest version. Open a new draft. Remove the inherited files. Upload the new files. | yes |
| 10 | The server is unreachable, or `meta.json` is not JSON or lacks title, abstract, authors, or license. | Exit 1 with `cannot reach` and the host, or exit 2 and name the key. No traceback. | yes |
| 11 | Software Heritage answers 429. | Wait for the `Retry-After` seconds. Then retry the same call. | yes |
| 12 | A save request fails, is rejected, or times out. Or a URL is not http or https. | Print the status for that URL and go on. Exit 1 at the end. Refuse a bad URL with exit 2 before any request. | yes |
| 13 | `packet` names a venue that `paper-venues.json` does not list. | Exit 2. Write no file. Do not invent a venue. | yes |
| 14 | `packet` names two peer-reviewed venues. | Exit 2 and explain dual submission. `--allow-second-review-venue` lifts it. The checklist then carries a warning. | yes |
| 15 | A venue reviews blind and a person pastes the packet as is. | Each packet shows the venue's review mode and says to hide the authors and use anonymous links when it is blind. | yes |
| 16 | The title differs in `meta.json`, the PDF first page, or `CITATION.cff`. | Exit 1. List each source and what it says. | yes |
| 17 | An ORCID has a wrong checksum or shape. | Exit 1 in `check`. Exit 2 in `zenodo-draft`. | yes |
| 18 | The text has `XXXX`, an em dash, a bad abstract length, a missing license, or a dead URL. | Exit 1. List every problem, not just the first. | yes |
| 19 | `--offline` is set. | Skip the URL requests. Run every other check. | yes |
| 20 | `pdftotext` is not installed. | Exit 2 and name the tool. | yes |
| 21 | Zenodo changes its API. | UNVERIFIED against a live deposit. The calls follow developers.zenodo.org. Only the read call `GET /records/<concept>/versions/latest` ran live, on 2026-10-16. Dry-run on `https://sandbox.zenodo.org/api` first. | no, needs a live token |
| 22 | A person trusts the packet and skips the venue page. Or asks the tool to click Submit, solve a CAPTCHA, or tick an agreement. | Every packet names its source and check date. There is no submit command. `CHECKLIST.md` lists those steps for a person. | no, a human rule |

