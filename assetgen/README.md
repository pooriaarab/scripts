# assetgen

Generate, cut out, upscale and slice game art through WaveSpeed.

```bash
assetgen models                                    # models, prices, styles
assetgen pipeline --prompt "a ripe red tomato" --count 4 --out ./assets
assetgen upscale --in ./sprites --out ./sprites-2x --scale 4
assetgen bgremove --in ./raw --out ./cut
```

Every command takes `--dry-run`, which prints the cost and makes no API call.

## Why `pipeline` is the default you want

Generating with an expensive model is worse value than generating with a cheap
one and upscaling:

| Route | Per asset | Resolution | Transparent |
|---|---|---|---|
| `pipeline` (flux-schnell + bgremove + real-esrgan) | **$0.0064** | 4096px | yes |
| gpt-image-2.5 alone | $0.024 | 1024px | no |

## Three failures this tool exists to prevent

None of them raise an error. You find them by opening an output file.

1. **Models ignore "transparent background".** However often the prompt asks,
   text-to-image returns opaque RGB. A batch of 200 sprites with the backdrop
   baked in looks fine in a file listing. Hence `bgremove`, on by default in
   `pipeline`.
2. **The upscaler destroys alpha.** `real-esrgan` returns RGB JPEG, so any
   transparency you already had is gone and the thumbnail still looks right.
   Every upscale re-applies the source alpha, resized.
3. **`wavespeed run --sync` aborts the submission.** Without it the CLI polls
   and succeeds. Never pass it.

A fourth, which is a technique rather than a bug: **models drift.** The same
character prompt twice gives two different characters. Use `--reference` to
anchor the style, and keep style strings in `styles.json` rather than
improvising per call.

## Cost controls

This spends real money per image, so:

- every command prints an estimate first
- anything over $1 needs `--yes`
- an existing output file is skipped, so a re-run resumes instead of paying twice
- ten consecutive failures aborts the batch

## Verifying output

Check the alpha channel rather than the thumbnail:

```python
from PIL import Image
Image.open(p).convert("RGBA").split()[-1].getextrema()   # (255,255) = opaque
```

## Requires

Python 3, Pillow, and the `wavespeed` CLI logged in (`wavespeed login`).
