#!/usr/bin/env python3
"""assetgen - generate, cut out, upscale and slice game art via WaveSpeed.

The cheapest route to a high quality asset is generate-cheap-then-upscale, not
generate-expensive. flux-schnell + bgremove + real-esrgan costs $0.0064 and
lands at 4x resolution with real transparency. gpt-image-2.5 alone costs $0.024,
still has an opaque background, and still needs upscaling for sprite work.
`pipeline` is that route and is the one you want.

Four things this tool exists to stop you rediscovering. Each cost a real cycle:

  1. Text-to-image models IGNORE "transparent background" in the prompt. They
     return opaque RGB and nothing warns you, so a sprite ships with its backdrop
     baked in. Hence the bgremove step, on by default.
  2. real-esrgan returns RGB JPEG with NO alpha channel. It silently destroys
     transparency you already have. We always re-apply the source alpha.
  3. `wavespeed run --sync` aborts the submission. Without it the CLI polls and
     succeeds. Never pass --sync.
  4. Image models drift: the same character prompt twice gives two different
     characters. Use --reference as a style anchor, and keep styles in
     styles.json so a project reuses one string instead of improvising.
"""
import argparse, json, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.exit("assetgen needs Pillow: pip3 install Pillow")

HERE = Path(__file__).parent
STYLES = json.loads((HERE / "styles.json").read_text())
MODELS = json.loads((HERE / "models.json").read_text())
CONFIRM_OVER = 1.00
MAX_CONSECUTIVE_FAILURES = 10


def resolve(kind, name):
    table = MODELS[kind]
    if name in table:
        return table[name]["id"], table[name]["price"]
    for entry in table.values():
        if entry["id"] == name:
            return entry["id"], entry["price"]
    sys.exit(f"unknown {kind} model '{name}'. known: {', '.join(table)}")


def ws(args, timeout=300):
    r = subprocess.run(["wavespeed", *args], capture_output=True, text=True, timeout=timeout)
    return r.stdout + r.stderr


def upload(path):
    for word in ws(["upload", str(path)]).split():
        if word.startswith("http"):
            return word
    return None


def run_model(model_id, inputs, out_path):
    """Never pass --sync: it aborts the submission. Polling is the working path."""
    args = ["run", model_id]
    for k, v in inputs.items():
        args += ["-i", f"{k}={v}"]
    args += ["--download", str(out_path)]
    ws(args)
    return out_path.exists()


def restore_alpha(src_png, raw_png, out_png, scale):
    """real-esrgan hands back RGB. Put the source alpha back or the sprite is ruined."""
    src = Image.open(src_png).convert("RGBA")
    w, h = src.width * scale, src.height * scale
    big = Image.open(raw_png).convert("RGB").resize((w, h), Image.LANCZOS)
    big.putalpha(src.split()[-1].resize((w, h), Image.LANCZOS))
    out_png.parent.mkdir(parents=True, exist_ok=True)
    big.save(out_png)


def money(n, price):
    t = n * price
    return f"${t:.4f}" if t < 0.01 else f"${t:.2f}"


def gate(count, price, args, what):
    print(f"{what}: {count} image(s) x ${price} = {money(count, price)}")
    if args.dry_run:
        print("dry run, no API calls made")
        return False
    if count * price > CONFIRM_OVER and not args.yes:
        sys.exit(f"that is over ${CONFIRM_OVER:.2f}. re-run with --yes to confirm.")
    return True


def each(items, fn, label):
    done = failed = consecutive = 0
    with ThreadPoolExecutor(max_workers=4) as pool:
        for ok, name in pool.map(fn, items):
            if ok:
                done, consecutive = done + 1, 0
            else:
                failed, consecutive = failed + 1, consecutive + 1
                print(f"  FAIL {name}")
                if consecutive >= MAX_CONSECUTIVE_FAILURES:
                    print(f"  aborting: {MAX_CONSECUTIVE_FAILURES} consecutive failures")
                    break
    print(f"{label}: {done} ok, {failed} failed")
    return done


def _fanout(args, kind, inputs_for, out_default, label):
    """Shared body for the per-file commands: bgremove and upscale."""
    model_id, price = resolve(kind, args.model)
    src = Path(args.__dict__["in"])
    files = sorted(src.rglob("*.png")) if src.is_dir() else [src]
    out_root = Path(args.out or out_default)
    if not gate(len(files), price, args, label):
        return
    def one(f):
        rel = f.relative_to(src) if src.is_dir() else Path(f.name)
        dest = out_root / rel
        if dest.exists():                       # resume rather than pay twice
            return True, str(rel)
        dest.parent.mkdir(parents=True, exist_ok=True)
        url = upload(f)
        if not url:
            return False, str(rel)
        ok = inputs_for(f, url, dest, model_id)
        return ok, str(rel)
    done = each(files, one, label)
    print(f"spend ~{money(done, price)}  ->  {out_root}")


def cmd_generate(args):
    model_id, price = resolve("text-to-image", args.model)
    if not gate(args.count, price, args, "generate"):
        return
    style = STYLES.get(args.style, "")
    prompt = f"{args.prompt}. {style}" if style else args.prompt
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    ref_url = upload(args.reference) if args.reference else None

    def one(i):
        dest = out / f"{args.name}-{i:03d}.png"
        if dest.exists():
            return True, dest.name
        inputs = {"prompt": prompt}
        if ref_url:
            inputs["image"] = ref_url
        return run_model(model_id, inputs, dest), dest.name

    done = each(range(args.count), one, "generate")
    print(f"spend ~{money(done, price)}  ->  {out}")


def cmd_bgremove(args):
    """Models ignore 'transparent background' and return opaque RGB. Cut it out."""
    _fanout(args, "bgremove",
            lambda f, url, dest, mid: run_model(mid, {"image": url}, dest),
            "./assets/nobg", "bgremove")


def cmd_upscale(args):
    def work(f, url, dest, mid):
        raw = dest.with_suffix(".raw.png")
        if not run_model(mid, {"image": url, "scale": args.scale}, raw):
            return False
        restore_alpha(f, raw, dest, args.scale)
        raw.unlink(missing_ok=True)
        return True
    _fanout(args, "upscale", work, "./assets/upscaled", "upscale")


def cmd_pipeline(args):
    _, gen_price = resolve("text-to-image", args.model)
    _, up_price = resolve("upscale", args.upscale_model)
    bg_price = 0.0 if args.no_bgremove else resolve("bgremove", args.bgremove_model)[1]
    per = gen_price + bg_price + up_price
    steps = f"generate ${gen_price}" + ("" if args.no_bgremove else f" + bgremove ${bg_price}") + f" + upscale ${up_price}"
    print(f"pipeline: {args.count} x ({steps}) = {money(args.count, per)}")
    if args.dry_run:
        print("dry run, no API calls made")
        return
    if args.count * per > CONFIRM_OVER and not args.yes:
        sys.exit(f"that is over ${CONFIRM_OVER:.2f}. re-run with --yes to confirm.")

    def stage_args(**over):
        ns = argparse.Namespace(**vars(args))
        ns.dry_run, ns.yes = False, True
        for k, v in over.items():
            ns.__dict__[k] = v
        return ns

    raw = Path(args.out) / "_raw"
    cmd_generate(stage_args(out=str(raw)))
    stage = raw
    if not args.no_bgremove:
        cut = Path(args.out) / "_nobg"
        cmd_bgremove(stage_args(**{"in": str(stage), "out": str(cut), "model": args.bgremove_model}))
        stage = cut
    cmd_upscale(stage_args(**{"in": str(stage), "out": args.out, "model": args.upscale_model}))


def cmd_sfx(args):
    """Generate a sound effect.

    `duration` is REQUIRED and must be an INTEGER. Neither is documented. Omitting
    it 400s naming the field; passing 1.5 400s again saying it wants an integer.
    Two round trips to discover, so it is always sent and always coerced.

    The file comes back as AAC regardless of the extension you ask for, so name
    outputs .aac unless you intend to transcode.
    """
    model_id, price = resolve("sfx", args.model)
    if not gate(args.count, price, args, "sfx"):
        return
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    def one(i):
        dest = out / (f"{args.name}.aac" if args.count == 1 else f"{args.name}-{i:03d}.aac")
        if dest.exists():
            return True, dest.name
        return run_model(model_id, {"prompt": args.prompt, "duration": int(args.duration)}, dest), dest.name

    done = each(range(args.count), one, "sfx")
    print(f"spend ~{money(done, price)}  ->  {out}")


def cmd_models(args):
    for kind, table in MODELS.items():
        print(f"\n{kind}:")
        for name, m in sorted(table.items(), key=lambda kv: kv[1]["price"]):
            print(f"  ${m['price']:<8} {name:<16} {m['id']}")
    print("\nstyles:", ", ".join(STYLES))


def main():
    p = argparse.ArgumentParser(prog="assetgen", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp):
        sp.add_argument("--dry-run", action="store_true", help="print cost, make no API calls")
        sp.add_argument("--yes", action="store_true", help="confirm a spend over $1")

    g = sub.add_parser("generate", help="text to image")
    g.add_argument("--prompt", required=True)
    g.add_argument("--style", default="2.5d-cartoon", choices=list(STYLES) + [""])
    g.add_argument("--model", default="flux-schnell")
    g.add_argument("--count", type=int, default=1)
    g.add_argument("--name", default="asset")
    g.add_argument("--reference", help="image to anchor the style, fights model drift")
    g.add_argument("--out", default="./assets/generated")
    common(g); g.set_defaults(func=cmd_generate)

    b = sub.add_parser("bgremove", help="cut the background out, giving real transparency")
    b.add_argument("--in", required=True)
    b.add_argument("--out", default="./assets/nobg")
    b.add_argument("--model", default="feynobg")
    common(b); b.set_defaults(func=cmd_bgremove)

    u = sub.add_parser("upscale", help="upscale, preserving alpha")
    u.add_argument("--in", required=True, help="file or directory")
    u.add_argument("--out", default="./assets/upscaled")
    u.add_argument("--scale", type=int, default=4)
    u.add_argument("--model", default="real-esrgan")
    common(u); u.set_defaults(func=cmd_upscale)

    pl = sub.add_parser("pipeline", help="generate, cut out, upscale: best quality per dollar")
    pl.add_argument("--prompt", required=True)
    pl.add_argument("--style", default="2.5d-cartoon", choices=list(STYLES) + [""])
    pl.add_argument("--model", default="flux-schnell")
    pl.add_argument("--bgremove-model", default="feynobg")
    pl.add_argument("--upscale-model", default="real-esrgan")
    pl.add_argument("--no-bgremove", action="store_true", help="keep the generated background")
    pl.add_argument("--count", type=int, default=1)
    pl.add_argument("--name", default="asset")
    pl.add_argument("--reference")
    pl.add_argument("--scale", type=int, default=4)
    pl.add_argument("--out", default="./assets/final")
    common(pl); pl.set_defaults(func=cmd_pipeline)

    sx = sub.add_parser("sfx", help="generate a sound effect")
    sx.add_argument("--prompt", required=True)
    sx.add_argument("--model", default="sonilo-sfx")
    sx.add_argument("--duration", type=int, default=2, help="whole seconds; the model requires an integer")
    sx.add_argument("--count", type=int, default=1)
    sx.add_argument("--name", default="sfx")
    sx.add_argument("--out", default="./assets/audio")
    common(sx); sx.set_defaults(func=cmd_sfx)

    m = sub.add_parser("models", help="list models, prices and styles")
    m.set_defaults(func=cmd_models)

    main_args = p.parse_args()
    main_args.func(main_args)


if __name__ == "__main__":
    main()
