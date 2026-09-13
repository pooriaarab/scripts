# character-studio

`character-studio` generates AI images of a real person that still look like that
person.

Give an image model four photographs and a scene. The result is usually a
handsome stranger. Every model we tested pulls a face towards its own average:
the hairline drops, the beard fills in, the jaw widens, the shoulders broaden.
Each render looks fine alone. Next to the real photographs it is someone else.

The tool answers that drift with three parts. A **character pack** writes down
who the person is. Every prompt states that identity before it states the scene.
A vision model then scores the render against the real photographs, and its own
corrections go into the next prompt.

## The pipeline

The tool runs this loop for every shot.

1. Compose the prompt. The photographs come first. Each anchor contributes one
   short `check` line, not its full text.
2. Generate the image. The `wavespeed` CLI calls the image model with the
   reference photograph URLs attached.
3. Verify the render. A vision model scores every anchor from 0 to 5 against the
   real photographs. It never sees the prompt that made the image.
4. Retry. The verifier writes one imperative correction for each anchor it
   marked down. Those lines go back into the prompt as a faults section.
5. Stop on a pass, or after `max_attempts`. The best attempt is kept either way.

The tool writes a JSON report for each shot and one HTML contact sheet for the
pack. The contact sheet puts the renders, the anchor scores and the real
photographs on one page, so you can disagree with the verifier.

## Validate the verifier before you trust it

Read this section before you generate anything. The verifier model is
load-bearing. A weak verifier passes a wrong face, and then the retry loop has
nothing to correct.

On 2026-09-12, `google/gemini-3.8-flash` scored a known-wrong render **97.6%
PASS**. The image had a covered forehead, a dense black beard and a broad build.
None of those match the references. The model invented measurements that agreed
with the MUST text instead of measuring the picture.

Two other models saw the same image and the same anchors.
`gemini-3.1-pro-preview` scored it 59%. `claude-opus-5` scored it 66%. Both set
`same_person` to false. Both named the three real faults.

The verifier prompt in `src/verify.mjs` carries the fix that makes this work.
Keep all three parts if you change it.

- The verifier writes two separate fields for every anchor. `reference` records
  what it sees in the photographs. `candidate` records what it sees in the
  render. It writes both before it scores.
- The verifier must estimate numbers on both images. Forehead height as a
  percentage of face height. Face width divided by face height. Shoulder width in
  head-widths. Beard coverage on the flat of the cheek as a percentage.
- The instructions tell the model that straight 5s mean it did not look. Most
  candidates score 2 or 3 on at least one critical anchor.

### How to validate a verifier

Keep one render that you know is wrong. Then run the `verify` command against
it.

```sh
node tools/character-studio/bin/character-studio.mjs verify pooria \
  characters/pooria/out/hero-builder.attempt-1.jpg \
  --verifier gemini://gemini-3.1-pro-preview
```

A verifier passes this test when it fails the image, sets `same_person` to
false, and names the faults you can see yourself. A verifier that agrees with
your MUST lines is useless. Write the result into the `verification.note` field
of `character.json`, with the date and the score.

Warning: do not run `gallery` until a verifier passes this test. A bad verifier
turns the whole run into an expensive way to produce a stranger.

## Do not describe the face in the prompt

This is the second lesson, and it cost a whole batch of renders.

The first version of this tool put every anchor's full `must` and `never` text
into the image prompt. The result was worse than no identity lock at all. Four
photographs of a Persian man produced a Northern European stranger with light
brown hair and blue eyes.

The cause is simple. A long prose description of a face tells the model to
**generate** a face from the words. The photographs then become style hints. The
more carefully you describe the face, the less the model looks at the reference.

The fix is to give the two jobs two different fields.

| Field              | Read by         | Shape                                      |
| ------------------ | --------------- | ------------------------------------------ |
| `check`            | the image model | one short line, a trait to compare against |
| `must` and `never` | the verifier    | full prose, precise enough to score        |

The image prompt now opens by naming the photographs as the source, states that
this is a photo edit of a real individual, describes only the scene, and closes
with the `check` lines as a comparison list. The same shot that returned a
stranger returned a correct likeness on the first attempt after this change.

Keep a `check` line under about 15 words. Name the trait, not the reason.

## Before you start

- **Node 20 or newer.** The tool is plain ESM and has no dependencies.
- **The `wavespeed` CLI, logged in.** The tool shells out to `wavespeed run` and
  `wavespeed upload`. It also looks in `/opt/homebrew/bin` and `/usr/local/bin`.
- **A verifier API key.** Set `OPENROUTER_API_KEY` for an `openrouter://` model,
  or `GEMINI_API_KEY` for a `gemini://` model.
- **`sips` or `ffmpeg`, optional.** The tool downscales images to 1200 px on the
  long edge before it sends them to the verifier. Full-resolution photographs
  push a six-image request past several providers' size limits. Without either
  tool the images go out at full size.

The tool looks for the key in this order: the environment variable, the file
named by `--env-file`, the file named by `CHARACTER_STUDIO_ENV`, then `.env.local`
and `.env` at the repository root.

There is no `package.json` and no bin link. Call the script by path.

```sh
node tools/character-studio/bin/character-studio.mjs help
```

## The character pack

A pack is one directory. Everything the tool knows about a person comes from it,
so a second person needs only a second directory.

```
characters/pooria/
  character.json     the identity lock, the references, the verifier settings
  shots.json         the scene specs
  sheet-board.md     the panel list for the model sheet
  refs/              the real photographs
  out/               renders, JSON reports and the HTML contact sheet
```

Name a pack by its directory name, such as `pooria`, and the tool looks under
`characters/`. Pass a path that contains a slash to use a pack anywhere else.

### character.json

| Field                              | What it holds                                                |
| ---------------------------------- | ------------------------------------------------------------ |
| `id`, `name`, `version`, `updated` | Labels for the contact sheet.                                |
| `references`                       | One entry per photograph: `file`, `role`, `notes` and `url`. |
| `anchors`                          | The identity lock. See the next section.                     |
| `wardrobe`                         | `default`, `palette` and `never`. Goes into every prompt.    |
| `render`                           | `look` and `never`. The photographic direction.              |
| `verification`                     | The verifier model and the pass gate.                        |
| `report_web_dir`                   | A second place to write the contact sheet. Optional.         |

The `url` field holds the CDN address of the photograph. The `refs` command
fills it in. The tool refuses to load a pack while any reference lacks a URL.

The `verification` block takes these keys.

| Key               | Default | Meaning                                                                       |
| ----------------- | ------- | ----------------------------------------------------------------------------- |
| `model`           | none    | `<provider>://<model>`. `openrouter://` is assumed when the prefix is absent. |
| `pass_score`      | `0.85`  | The weighted mean a render must reach.                                        |
| `critical_min`    | `4`     | The floor every critical anchor must clear alone.                             |
| `critical_weight` | `3`     | The weight at which an anchor becomes critical.                               |
| `max_attempts`    | `3`     | How many times to generate and verify one shot.                               |

### shots.json

The file holds a `defaults` object and a `shots` array. Each shot merges over the
defaults. A shot takes `id`, `group`, `aspect_ratio`, `framing`, `scene`,
`wardrobe`, `expression` and `light`. It can also take `extra` for one more
instruction, `refs` to override which photographs go to the image model, and
`install` for a path to copy the passing render to.

The defaults also carry `model`, `resolution` and `output_format`, which the
tool passes straight to `wavespeed`.

## Commands

### refs

Uploads every file in `refs/` to the CDN and writes the URLs back into
`character.json`. Run this first, and again whenever you add a photograph.

```sh
node tools/character-studio/bin/character-studio.mjs refs pooria
```

### shot

Renders one or more named shots. Each one is verified and retried on its own.

```sh
node tools/character-studio/bin/character-studio.mjs shot pooria portrait-neutral hero-builder
```

### gallery

Renders every shot in the pack. Use `--group` to render one group, `--max` to
stop after a count, and `--only-failed` to skip shots whose last report passed.

```sh
node tools/character-studio/bin/character-studio.mjs gallery pooria --group site
node tools/character-studio/bin/character-studio.mjs gallery pooria --only-failed
```

### sheet

Renders the character model sheet. The panel list comes from `sheet-board.md`,
not from `shots.json`. The sheet uses every reference photograph, a 16:9 frame,
and `google/nano-banana-pro/edit-ultra` at 4k. Override those with `--model` and
`--resolution`.

```sh
node tools/character-studio/bin/character-studio.mjs sheet pooria
```

### verify

Scores one image that already exists. Nothing is generated. Use this to validate
a verifier, or to judge an image from somewhere else.

```sh
node tools/character-studio/bin/character-studio.mjs verify pooria characters/pooria/out/portrait-neutral.jpg
```

The command prints the score for every anchor, what the verifier saw in the
references, what it saw in the candidate, and its correction line.

### install

Copies each passing render to the `install` path its shot declares. Paths are
relative to the repository root. A shot that did not pass is skipped unless you
pass `--force`.

```sh
node tools/character-studio/bin/character-studio.mjs install pooria
```

### report

Rebuilds the HTML contact sheet from the JSON reports already in the output
directory. No model is called, so this is free and fast.

```sh
node tools/character-studio/bin/character-studio.mjs report pooria
```

### Flags

| Flag                 | Applies to                            | Effect                                                   |
| -------------------- | ------------------------------------- | -------------------------------------------------------- |
| `--out <dir>`        | shot, gallery, sheet, install, report | Use a different output directory.                        |
| `--web <dir>`        | shot, gallery, sheet, report          | Write a second copy of the contact sheet and its images. |
| `--verifier <model>` | shot, gallery, sheet, verify          | Override the pack's verifier model.                      |
| `--env-file <path>`  | every command that loads a pack       | Read the API key from this file.                         |
| `--group <name>`     | gallery                               | Render one group only.                                   |
| `--only-failed`      | gallery                               | Skip shots whose last report passed.                     |
| `--max <n>`          | gallery                               | Stop after this many shots.                              |
| `--force`            | install                               | Copy a render that did not pass.                         |
| `--model <id>`       | sheet                                 | Use another image model for the sheet.                   |
| `--resolution <r>`   | sheet                                 | Use another resolution for the sheet.                    |
| `--quiet`            | every command that loads a pack       | Hide the verifier banner line.                           |

## How to write an anchor

An anchor is one trait, with a weight, a MUST line, a NEVER line and a reason.

```json
{
  "id": "forehead",
  "label": "Tall forehead and high recessed hairline",
  "weight": 3,
  "must": "A tall, broad, gently convex forehead that takes roughly the top 38-40% of the face from brow to hairline. The hairline sits high and is clearly mature: the corners above each temple are recessed well back, leaving a rounded central peak between two visible bare temple triangles.",
  "never": "A low or straight hairline. Hair falling forward onto the forehead. A short forehead. A dense fringe. A juvenile hairline with square corners.",
  "why": "This is the single fastest tell. Every earlier failed render put hair low on the forehead and it stopped looking like him immediately."
}
```

**Set the weight by how fast a wrong value breaks the likeness.** Weight 3 means
a wrong value instantly reads as a different person. The prompt labels weight 3
as CRITICAL, weight 2 as IMPORTANT and weight 1 as SUPPORTING. Weight 3 also
arms the hard floor in the pass gate, so do not spend it on a trait you would
forgive.

**Write MUST as a measurement, not as praise.** "Handsome angular face" tells a
model nothing it can check. "Longer than it is wide, with a narrow jaw that
tapers to a softly rounded chin" tells it where to put the lines. Put a number in
wherever a number exists: a percentage, a millimetre length, a count of head
units. The verifier is told to estimate those same numbers on both images, so a
MUST line with a number in it gets checked.

**Write NEVER as the specific failure the model keeps producing.** A general
NEVER line is wasted text. Go and look at the failed renders, then name what you
saw. The beard anchor says "a dense uniform full beard" because that is exactly
what the earlier renders produced.

**Write the reason down in `why`.** Months later, a reader who does not know the
history will read a strict MUST line as fussy and soften it. The `why` field is
the record of the render that failed. The contact sheet prints it under every
anchor.

Derive the anchors by reading the photographs side by side. Do not write them
from memory, and do not edit one without opening the references again.

## How scoring and the pass gate work

The verifier returns a score from 0 to 5 for every anchor, plus an `overall`
summary and a `same_person` verdict. The tool rejects the response if any anchor
is missing.

A score of 0 means the trait is not visible in the render. Those anchors are
judgeable by nobody, so the tool drops them from the arithmetic entirely.

The score is a weighted mean over the remaining anchors.

```
score = sum(weight × anchor_score) / sum(weight × 5)
```

A render passes when all three of these hold.

1. The weighted mean reaches `pass_score`, which is 0.85 by default.
2. Every anchor at or above `critical_weight` scores at least `critical_min`. One
   critical anchor at 3 out of 5 fails the render, whatever the mean says.
3. The verifier did not set `same_person` to false.

The two halves do different jobs. The mean catches a render that is wrong in many
small ways. The floor catches a render that is right everywhere except the one
trait that carries the likeness.

Corrections feed the next attempt. The tool takes every anchor that scored
between 1 and 4 and has a correction line, sorts them by weight and then by
score, and writes them into the prompt under a faults heading.

## Make a pack for yourself

1. **Collect the photographs.** Six is enough. Cover a near-frontal face in even
   light, a close-up of the hair and hairline, a full body for proportion, and a
   half body for the torso. Put them in `characters/<you>/refs/`.

2. **Write `character.json`.** List each photograph with its `role` and a `notes`
   line that says what it is authoritative for. Leave `url` out for now.

3. **Upload the references.**

   ```sh
   node tools/character-studio/bin/character-studio.mjs refs <you>
   ```

4. **Write the anchors.** Open every photograph side by side. Order the anchors by
   how fast a wrong value reads as "not them". Follow the rules above. Eight to
   twelve anchors is a working range.

5. **Generate one throwaway render.** Use a single cheap shot. Expect it to be
   wrong. You now have your known-bad image.

   ```sh
   node tools/character-studio/bin/character-studio.mjs shot <you> portrait-neutral
   ```

6. **Validate the verifier against that image.** Run `verify` with at least two
   models. Keep the one that fails the image and names the faults you can see.
   Write the model, the score and the date into `verification.note`.

7. **Write `shots.json`.** Start with two or three shots. Give each one a
   `framing`, a `scene`, a `wardrobe`, an `expression` and a `light` line.

8. **Run the gallery and read the contact sheet.**

   ```sh
   node tools/character-studio/bin/character-studio.mjs gallery <you>
   open characters/<you>/out/index.html
   ```

9. **Fix the anchors, not the shots.** A fault that shows up across several shots
   is an anchor problem. Add the specific failure to the NEVER line of the anchor
   that owns it, and record why in `why`.

10. **Install the renders you keep.**

    ```sh
    node tools/character-studio/bin/character-studio.mjs install <you>
    ```

The prompt ends with a final check paragraph in `src/prompt.mjs`. That paragraph
names the faults of this pack by hand. Rewrite it for your own anchors when you
add a second character.

## What the tool writes

Everything lands in the pack's `out/` directory, or in the directory you pass to
`--out`.

| File                     | Contents                                                            |
| ------------------------ | ------------------------------------------------------------------- |
| `<shot>.attempt-<n>.jpg` | One render per attempt, kept for comparison.                        |
| `<shot>.jpg`             | The best attempt, copied under the shot id.                         |
| `<shot>.report.json`     | The scores, the observations and the corrections for every attempt. |
| `character-sheet.jpg`    | The best model sheet.                                               |
| `index.html`             | The contact sheet.                                                  |
| `refs/`                  | A copy of the real photographs, for the contact sheet.              |

The contact sheet is self-contained. Open it with a browser, or point `--web` at
a directory your dev server already serves.
