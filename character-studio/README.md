# character-studio

Generate images of a real person that still look like them.

Image models pull a face towards their own average. The hairline drops, the
beard fills in, the jaw widens. Each render is plausible on its own and wrong
next to the real photographs.

This directory holds the engine. The method, and the mistakes worth avoiding,
are written up as the `consistent-character-images` skill in
[pooriaarab/skills](https://github.com/pooriaarab/skills).

## Status

The engine arrives in parts, because it is about 1,500 lines and the PR
standard caps a change at 500. Nothing here runs until every part has landed.

| part | modules | issue |
|---|---|---|
| 1 | `pack.mjs`, `prompt.mjs` | #386 |
| 2 | `wavespeed.mjs`, `image.mjs` | to follow |
| 3 | `verify.mjs`, `pipeline.mjs` | to follow |
| 4 | `triage.mjs`, `bakeoff.mjs`, `report.mjs` | to follow |
| 5 | `bin/character-studio.mjs`, full README | to follow |

## What is here now

`src/pack.mjs` loads a character pack: the identity lock, the shot list and the
reference photographs. It also resolves variants and decides which anchors a
given shot can actually show.

`src/prompt.mjs` composes the two prompts, one for a photograph and one for a
character reference sheet.

Both carry the reasoning for their shape in comments. The important one: a long
prose description of a face makes the model generate a face from the words and
ignore the reference photographs, so generation and verification read different
fields of the same anchor.
