# llmctl

> Fast, pipe-friendly CLI for testing OpenAI-compatible and Anthropic LLM endpoints.

`llmctl` is a single-binary debugger for chat-completion APIs. It speaks
OpenAI Chat Completions, OpenAI-compatible servers (llama-server, vLLM,
Ollama, …), and Anthropic Messages — through one provider abstraction
where `format × timing` (text/json/ndjson × stream/batch) are orthogonal.

```bash
llmctl "explain recursion"
echo "summarize" | llmctl < article.txt
llmctl --base-url http://10.0.0.64:8800 --model gemma "hi"
llmctl --output ndjson "hi" | jq .
llmctl --provider anthropic --model claude-sonnet-4-5 "hi"
llmctl --extra cache_prompt=true --extra seed=42 "hi"
llmctl -i                                          # REPL with slash commands
```

## Why

- **One CLI for every chat API** — built-in `local` (llama-server),
  `openai`, `openai-compat`, `anthropic`. Swap providers without
  rewriting your shell pipeline.
- **Provider as a triple of pure functions** — `builder` /
  `stream_decoder` / `batch_decoder`. Adding a new provider means
  three functions, not a new code path.
- **Concurrent multi-model** — repeat `--model` to fan out the same
  prompt to multiple models in parallel, get tagged NDJSON back.
- **Pipe-native output** — `--output text|json|ndjson` covers
  human terminals, structured tools, and streaming consumers.
- **REPL with sessions** — `llmctl -i` gives you a 10-command slash
  REPL; conversations persist via `--session path.json` and fork via
  `--save-session`.
- **`--extra` passthrough** — any provider-specific knob
  (`cache_prompt`, `seed`, `repeat_penalty`, …) goes through
  type-inferred without a CLI flag for it.
- **Single binary, no runtime deps** — Zig 0.16, ~1.3 MB.

## Install

Build from source (until release tarballs are published):

```bash
git clone https://github.com/agent-rt/llmctl
cd llmctl
zig build -Doptimize=ReleaseSafe
./zig-out/bin/llmctl --version
```

Requires Zig 0.16.

## Quick reference

```
PROVIDER:
    --provider <name>       local | openai | openai-compat | anthropic
    --base-url <url>        Override provider base URL
    --model, -m <name>      Repeat for concurrent multi-model

PROMPT:
    --system <text|@file>   System prompt (`@path` reads from file)

PARAMETERS:
    --temperature <f>       --max-tokens <n>       --top-p <f>
    --extra k=v             Pass-through (repeatable, type-inferred)
    --extra-json '{...}'    Pass-through from JSON

OUTPUT:
    --output text|json|ndjson  (default: text)
    --buffer / --no-stream     Buffer until completion
    --no-color                 Disable ANSI

SESSION:
    --session <path>           Load+update conversation
    --save-session <path>      Save (or fork)
    -i, --interactive          REPL (10 slash commands; /help)

DEBUG:
    --dry-run                  Print request body, exit (auth redacted)
    --verbose, -v              Print provider/url/latency/usage
```

## Defaults

`~/.config/llmctl/defaults` — one `key=value` per line — sets fallback
values for any flag:

```
provider=local
base-url=http://10.0.0.64:8800
model=unsloth/gemma-4-26B-A4B-it-GGUF:gemma-4-26B-A4B-it-UD-Q4_K_M
max-tokens=4096
```

## Position in the Agent-RT family

| Tool | Layer |
|---|---|
| **`llmctl`** | Direct chat-completion API client (debugging, scripting) |
| [`acpctl`](https://github.com/agent-rt/acpctl) | ACP agent invocation |
| [`mcpctl`](https://github.com/agent-rt/mcpctl) | MCP server invocation |
| [`secretctl`](https://github.com/agent-rt/secretctl) | Encrypted secret store + capability injection |

`llmctl` is the leaf — it talks HTTP to a model and gets out of the
way. Pair with `secretctl exec --tag ai -- llmctl …` to keep API keys
out of your shell environment.

## Status

v0.2.0 — provider matrix (`local`, `openai`, `openai-compat`,
`anthropic`), concurrent multi-model, sessions, REPL, `--extra`
passthrough. 46/46 tests passing. Tested against llama-server.

## License

Apache-2.0 — see [LICENSE](./LICENSE).
