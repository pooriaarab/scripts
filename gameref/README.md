# gameref

Learn a genre's mechanics by watching reference gameplay videos.

Feeds YouTube footage to Gemini on Vertex and gets back structured mechanics
rather than prose. Merges findings across many videos, so a mechanic named by
one video is a lead and a mechanic named by twenty is a requirement.

Built for Chef Dash, where the question was "what does Overcooked actually do
that we have not thought of". It is game-agnostic: point it at any genre.

## Use

```bash
gameref search "Overcooked 2 gameplay walkthrough" \
               "Overcooked 2 co-op 4 player" \
               --per-query 12 --min-seconds 180 --max-seconds 1800

gameref analyse videos.json --limit 34 --clip-seconds 600

gameref merge reports --out mechanics.json
gameref dedupe mechanics.json --out mechanics-deduped.json
```

`merge` groups on the exact name, then `dedupe` clusters the names that mean the
same thing. Both stages exist because the first is not enough: across 31 videos
one dash arrived as `dash`, `dash-burst`, `dash-boost` and `chef-dash`, and each
looked like an independent finding.

That matters beyond tidiness. The count of how many videos saw a mechanic is the
output you act on, and splitting one mechanic across four names understates every
one of them. On a real run dedupe took 239 names down to 100 mechanics and moved
dish washing from an apparent 8 sightings to its true 25, which is the difference
between a detail and the most-attested mechanic in the genre.

`dedupe` sends only the names and one description each, never the whole corpus,
and carries through any name the model failed to place rather than letting the
clustering step quietly shrink the findings.

## Output

One object per mechanic:

```json
{
  "name": "overcook-warning",
  "category": "hazard",
  "what_happens": "Leaving cooked food on the heat source triggers an escalating alarm before it catches fire.",
  "feedback": "Flashing red warning above the pot, the pot shakes, an alarm sounds.",
  "confidence": "seen"
}
```

`confidence` is `seen` or `inferred`. The prompt asks for `inferred` whenever
the model reasoned from a UI element or a result rather than watching the act,
because a confident list of guesses is worse than a short honest one.

`feedback` is deliberate. How a game tells you something happened is most of
what makes it feel good, and it is the part a design document usually omits.

## Requirements

`yt-dlp` for search. A Google Cloud project with Vertex AI enabled, reached
through application default credentials at `~/.config/gcloud/adc_personal.json`.

Override with `GAMEREF_PROJECT`, `GAMEREF_LOCATION`, `GAMEREF_MODEL`.

## Three traps, each of which cost a run

**AI Studio and Vertex are different billing pools.** A key for
`generativelanguage.googleapis.com` can be out of prepayment credit while Vertex
on the same account works. That is why this talks to Vertex.

**Vertex rejects a `contents` entry with no explicit `role`**, and says
`Please use a valid role: user, model`, which does not name the missing field.
AI Studio defaults it.

**Vertex wants camelCase.** `fileData`, `fileUri`, `mimeType`. Send the
snake_case spelling that AI Studio accepts and the request succeeds with the
video silently dropped, so the model answers from the prompt alone. That reads
as a plausible result rather than as an error, which makes it the worst of the
three.

## Cost

Video runs about 260 tokens per second, plus audio. A five-hour longplay is
millions of tokens and mostly repeats what the first ten minutes showed, so
`search` filters on duration and `analyse` sends a clip with offsets rather than
a whole stream. Ten minutes of footage is roughly 25,000 tokens.
