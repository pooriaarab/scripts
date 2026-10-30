# Measure web performance changes

Start with a measured constraint. Change one cause. Repeat the same experiment.
Report bytes, requests, and time as separate results. Do not promise a percentage before measuring it.

## Set the measurement boundary

1. Use a production build for both versions.
2. Record the build revision and tool versions in private run metadata.
3. Choose representative public, sign-in, authenticated, and data-heavy routes.
4. Include supported languages, slow devices, and a long-lived browser session.
5. Fix viewport, browser, CPU, network settings, region, and dataset.
6. Verify the authenticated user state when a route requires sign-in.
7. Define the action and end condition before running it.
8. Run at least five samples per version and cache condition.

Keep browser-cold, browser-warm, and CDN cache conditions separate.
Use a fresh browser context for each cold sample. Record service worker behavior.
For warm samples, use the same navigation sequence with caching enabled.
Confirm actual cache hits instead of assuming that a second visit is warm.
Alternate before and after runs when network conditions can change.

Save every sample, sample count, median, and worst observed value.
Use more samples for tail estimates. Do not present five samples as a stable p95.
Keep failures in the report. A successful retry does not explain an earlier failure.

## Select the next check

| Symptom | Inspect | Measure |
|---|---|---|
| Fonts delay text | Weights, route preloads, subsets, fallback | Requested font body bytes, requests, text rendering |
| Repeat visits still fetch bundles | Static path rules and response headers | Network requests, revalidation bytes, cache hits |
| Large API responses | Projection, pagination, compression | Encoded bytes, decoded bytes, round trips |
| Slow first response | Queries, external calls, queueing | TTFB, server duration, work per request |
| High server cost | Repeated reads, polling, idle work | Billable rows, CPU, memory, requests per interval |
| Slow page after data arrives | Images, JavaScript, hydration, layout | LCP, interaction delay, layout shifts, main-thread time |

## Count bytes at the right layer

Name each byte metric and its collection method.
`encodedBodySize` measures the encoded response body. `decodedBodySize` measures the decoded body.
`transferSize` includes response headers. A revalidation can transfer bytes without a new body.
See [body size](https://developer.mozilla.org/en-US/docs/Web/API/PerformanceResourceTiming/encodedBodySize)
and [transfer size](https://developer.mozilla.org/en-US/docs/Web/API/PerformanceResourceTiming/transferSize).

A zero can mean cache use or unavailable cross-origin timing data.
Check timing permissions and use browser network events to confirm the cause.
Verify the instrument with one known network request and one known cache hit.
Do not mix response-body lengths with protocol transfer counts in one total.
Do not infer transfer bytes from disk file sizes or a compressed build report.

## Reduce font transfers without changing text

- List the actual font requests for every representative route.
- Remove unused weights and route-inappropriate preloads only after checking actual use.
- Check variable-font and separate-weight transfers under the same rendering requirements.
- Split common characters from the remaining supported characters when useful.
- Make CSS Unicode ranges disjoint for each weight and style.
- Verify that their union covers every source codepoint you promise to preserve.
- Check punctuation, status symbols, minus signs, currencies, and extended language ranges.
- Preserve required substitutions, shaping, kerning, and fallback metrics.
- Check Latin, accented text, non-Latin text, and mixed scripts in the browser.
- Confirm the custom font renders the text; fallback can hide a missing glyph.
- Compare screenshots and text metrics for each weight and style.
- Record extra downloads when mixed text loads both common and complement faces.
- Pin the generator and compression versions.
- Record input checksums, upstream provenance, and the correct redistribution license.
- Regenerate twice and verify the output matches.

Font subsetting can remove layout features as well as characters.
Check the [fontTools subset options](https://fonttools.readthedocs.io/en/latest/subset/index.html) before choosing feature settings.
A smaller font file is a byte result. A faster text paint requires a separate timing result.

## Remove static revalidation safely

Apply long-lived immutable caching only to public assets whose URL changes with their content.
Content hashes or build-scoped paths can provide that contract.
Audit every file under the matched prefix before changing a wildcard rule.
Keep old build assets available while old pages or open tabs can still request them.

Check hashed CSS, JavaScript, and fonts on the deployed host.
Also check an unhashed logo, HTML, an API response, and an authenticated response.
Keep unhashed resources on an update-aware policy.
Never extend public caching to private responses.
See [Cache-Control semantics](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Cache-Control).

Run the same warm navigation sequence before and after.
Count network fetches, revalidations, transferred bytes, and cache hits separately.
Check first visits too. Better repeat-visit caching does not prove faster cold loads.

## Reduce API and server work

Use an equivalent dataset and request sequence for both versions.
Check one page, later pages, empty results, large results, and permission boundaries.

- Return only fields the client needs.
- Bound result sizes with pagination.
- Confirm compression on the actual response.
- Count all follow-up requests; a smaller page can require more round trips.
- Keep status codes, ordering, permissions, and client behavior equivalent.
- Measure query count, rows read, external calls, CPU, and peak memory.
- Measure queue wait and latency under realistic concurrency.
- Check errors and timeouts as well as successful requests.
- Check idle polling and background tasks over a fixed interval.
- Preserve diagnostic logs when moving code.
- Test invalidation and freshness before adding caches.

Distinguish application rows returned from database rows read or billed.
Use reconciled billable counts before claiming cost savings.
Fewer queries alone do not prove fewer billed rows or lower latency.

## Keep the experiment isolated

Write the E2E failure cases before changing behavior.
Use synthetic records and unique namespaces for seeded provider identifiers.
Do not seed IDs that fake external services can generate later.
Check the intended row after a callback; a 200 response alone proves little.
Run related specs together against persistent test storage to expose collisions.
Back up synthetic local state before resetting it.
Never reset production data to repair a benchmark.

## Keep evidence useful and safe

Save a repeatable command and a machine-readable artifact outside the source tree.
Store only approved numeric measurements, status codes, labels, and explicit test outcomes.
Exclude names, email addresses, private domains, full URLs, credentials, raw headers, and response bodies.
Exclude cookie values, raw navigation errors, browser storage, and unsanitized traces.
Use generic route labels in shared reports.
Run a fake-secret case and confirm that the published artifact excludes it.
Keep private revision mappings and commands separate from the shareable artifact when they reveal project identity.
Capture before and after screenshots with synthetic data for visible changes.
Attach proof separately; do not commit proof media.

Use this empty report shape. Fill it only with real observations:

```json
{
  "scenario": "route-a-cold",
  "metric": "fontEncodedBodyBytes",
  "unit": "bytes",
  "boundary": "font response bodies per navigation",
  "cacheCondition": "fresh-browser-context",
  "beforeSamples": [],
  "afterSamples": [],
  "sampleCountBefore": 0,
  "sampleCountAfter": 0,
  "medianBefore": null,
  "medianAfter": null,
  "worstBefore": null,
  "worstAfter": null,
  "reductionPercent": null,
  "limitations": []
}
```

For a lower-is-better metric, compute `(before - after) / before * 100`.
Use the same statistic on both sides. A negative result means a regression.
For a zero baseline, report the absolute difference and omit the percentage and ratio.
Do not turn fewer bytes into a claim of faster loading without timing evidence.

## Review and verify the release

1. Run the local gate before each push.
2. Get an independent review of the exact commit.
3. Resolve findings and wait for green checks.
4. Walk the affected flow on the deployment preview.
5. Merge through the normal release process.
6. Confirm the deployed revision contains the reviewed change.
7. Confirm the intended targets actually deploy; a successful workflow can skip every target.
8. Repeat the relevant route, byte, or header checks in production.
9. Record remaining limits and regressions.

Do not close the work at a green build or a home-page response alone.
