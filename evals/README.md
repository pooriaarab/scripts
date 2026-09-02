# Ori model-fit eval (scripts#198)

Phase 1 is attended. Do not invent interview answers — a guessed eval looks
correct and measures nothing.

```sh
curl -fsSL https://openrouter.ai/labs/ori/install.sh | bash
ori login
cd /path/to/scripts
ori code --prompt-file evals/PROMPT.txt
```

Ask Ori to measure factory routing decisions from `agent-routing.json`:
mechanical (GLM/DeepSeek flash) vs scoped (Codex) vs judgement (Claude/Codex).

Commit the resulting `evals/**/*.eval.ts`. Cap spend inside the file. Pin the
harness and run model. Phase 2 is `.github/workflows/ori-eval.yml`.
