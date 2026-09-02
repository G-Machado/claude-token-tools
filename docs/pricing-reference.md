# Claude pricing & caching — local reference

Extracted 2026-08-08 from the bundled `claude-api` skill (`shared/prompt-caching.md`,
SKILL.md model table). **This is an authoritative local copy, not recollection** — answering
from it is not "answering from memory". Invoking the full skill costs ~235k tokens of context;
this file costs ~600. Only escalate to `/claude-api` if a case genuinely is not covered here.

Re-extract when the CLI version changes materially, and update the date above.

---

## Token price multipliers (relative to input)

| class | multiplier |
|---|---|
| cache **read** | **0.1×** |
| input (uncached) | 1× |
| cache **write**, 5-minute TTL | 1.25× |
| cache **write**, 1-hour TTL | **2×** |
| **output** | **5×** |

Cost-equivalent of a session: `output×5 + cache_write×2 + cache_read×0.1 + input×1`
(use ×1.25 for cache_write if the session runs a 5-minute TTL).

**Break-even on caching:** 5-min TTL pays off at 2 requests (1.25 + 0.1 vs 2.0 uncached);
1-hour TTL needs 3+ (2.0 + 0.2 vs 3.0). The 1-hour TTL survives gaps in bursty traffic but the
doubled write cost needs more reads to repay.

## Model list prices (per million tokens)

| model | input | output |
|---|---|---|
| Claude Fable 5 / Mythos 5 | $10 | $50 |
| **Claude Opus 5** | **$5** | **$25** |
| Claude Opus 4.8 / 4.7 / 4.6 | $5 | $25 |
| Claude Sonnet 5 | $3 ($2 intro to 2026-08-31) | $15 ($10 intro) |
| Claude Sonnet 4.6 | $3 | $15 |
| Claude Haiku 4.5 | $1 | $5 |

Opus 5 fast mode (`speed: "fast"`) is priced at $10 / $50.

## Minimum cacheable prefix

Not monotonic across generations — check the row, don't extrapolate.

| model | minimum |
|---|---:|
| Opus 5, Fable 5, Mythos 5 | 512 |
| Opus 4.8, Sonnet 5, Sonnet 4.6/4.5, Opus 4.1/4 | 1,024 |
| Opus 4.7, Haiku 3.5 | 2,048 |
| Opus 4.6, Opus 4.5, Haiku 4.5 | 4,096 |

Below the minimum nothing caches — silently, with `cache_creation_input_tokens: 0` and no error.

## Reading usage

| field | meaning |
|---|---|
| `cache_creation_input_tokens` | written to cache this request (paid the write premium) |
| `cache_read_input_tokens` | served from cache (paid 0.1×) |
| `input_tokens` | **uncached remainder only** |

Total prompt size = all three summed. `input_tokens` alone badly understates a long session.
If `cache_read_input_tokens` stays 0 across identical prefixes, something is invalidating the
cache — see below.

## What invalidates a cache

Prefix match: render order is `tools` → `system` → `messages`, and **any byte change
invalidates everything after it**. Max 4 breakpoints per request; each breakpoint looks back at
most 20 content blocks.

Tiered — a change only invalidates its own tier and below:

| change | tools | system | messages |
|---|:-:|:-:|:-:|
| tool definitions added/removed/reordered | ✗ | ✗ | ✗ |
| model switch | ✗ | ✗ | ✗ |
| system prompt content | ✓ | ✗ | ✗ |
| `tool_choice`, images, thinking on/off | ✓ | ✓ | ✗ |
| message content | ✓ | ✓ | ✗ |

Common silent invalidators: `datetime.now()` or a UUID interpolated near the front,
`json.dumps` without `sort_keys=True`, per-user IDs in the system prompt, conditional system
sections, a tool set that varies per user.

## Not covered here — escalate to `/claude-api`

SDK syntax and type names, model migration and breaking changes, Managed Agents, server-side
tools, structured outputs, thinking/effort configuration, error codes, platform availability
(Bedrock / Vertex / Foundry).
