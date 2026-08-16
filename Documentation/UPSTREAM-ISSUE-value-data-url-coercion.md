# Draft upstream report: `Value` silently converts strings that look like data URLs

Status: **draft for review — not submitted.** Intended for
`modelcontextprotocol/swift-sdk` as an issue, or as the description of a small pull request.
Everything below the summary is supporting material; the summary alone is enough to act on.

---

## Summary

Decoding JSON with `Value` turns any string whose contents happen to look like a data URL into
`Value.data`, and encoding turns it back into a *re-generated* data URL. A string that arrives as
`"data:,hello"` does not survive a round trip, and a string that arrives as
`"data:text/plain;base64,aGk="` comes back re-spelled.

This affects any string carried through `Value`: tool arguments, tool results, resource contents,
prompt arguments, elicitation content, and `_meta`. It is silent — no error, no warning — and it is
lossy in both directions.

**Where:** `Sources/MCP/Base/Value.swift`, in `init(from:)` and `encode(to:)`.

**Reproduction** (three lines, no server needed):

```swift
let json = Data(#"{"note":"data:,hello"}"#.utf8)
let decoded = try JSONDecoder().decode([String: Value].self, from: json)
let reencoded = try JSONEncoder().encode(decoded)
// {"note":"data:text\/plain;base64,aGVsbG8="}
```

**Suggested fix:** stop inferring `.data` while decoding. A JSON string is a string; construct
`.data` explicitly at the call sites that genuinely mean binary content. If the inference must be
kept for source compatibility, it should at minimum preserve the original spelling so encoding is
the identity, and it should be opt-in rather than the default.

**Why it matters now:** `2026-07-28` tightens what may pass through unchanged — `_meta` is required
on every request, `requestState` is an opaque string a client must echo **exactly**, and tool
`inputSchema` may be any JSON Schema 2020-12 document. A silent string rewrite in the shared value
type is a poor foundation for those requirements. See [Appendix C](#appendix-c) for the specific
interactions.

Details: [Appendix A](#appendix-a) — exact code path · [Appendix B](#appendix-b) — what does and does
not trigger it, with outputs · [Appendix C](#appendix-c) — specification interactions ·
[Appendix D](#appendix-d) — fix options and trade-offs · [Appendix E](#appendix-e) — verification
notes and related work.

---

<a id="appendix-a"></a>

## Appendix A — The code path

Decoding, `Value.init(from:)`:

```swift
} else if let value = try? container.decode(String.self) {
    if Data.isDataURL(string: value),
        case let (mimeType, data)? = Data.parseDataURL(value)
    {
        self = .data(mimeType: mimeType, data)
    } else {
        self = .string(value)
    }
}
```

Every decoded JSON string is tested against `Data.isDataURL(string:)`, and on a match the string is
replaced by `.data(mimeType:_:)`. The original text is discarded at this point: `.data` stores a
MIME type and bytes, not the spelling they came from.

Encoding, `Value.encode(to:)`, then regenerates a canonical form via
`data.dataURLEncoded(mimeType:)`. Because the input spelling was not retained, the output is
whatever that helper produces — always base64, always with an explicit MIME type, percent-encoding
normalized away.

The asymmetry is the bug: **decode is lossy, encode is generative, and nothing records that a
substitution happened.**

<a id="appendix-b"></a>

## Appendix B — What triggers it

Measured outputs from the reproduction above, varying only the input string (run against this
repository, not reasoned):

| Input string | Round-trips as | Lossless? |
| --- | --- | --- |
| `"data:,hello"` | `"data:text/plain;base64,aGVsbG8="` | no — implied MIME type made explicit, body re-encoded as base64 |
| `"data:text/plain,hello%20world"` | `"data:text/plain;base64,aGVsbG8gd29ybGQ="` | no — percent-encoding replaced by base64 |
| `"data:text/plain;base64,aGk="` | `"data:text/plain;base64,aGk="` | yes, by coincidence — already canonical |
| `"data:"` | `"data:"` | yes — not a valid data URL, stays a string |
| `"Data:,hello"` | `"Data:,hello"` | yes — prefix match is case-sensitive |
| `"see data:,hello"` | `"see data:,hello"` | yes — must start with the prefix |

So the trigger is narrow but entirely reachable from ordinary text: any string beginning with
`data:` that parses as a data URL. Realistic sources include documentation strings that quote a data
URL, a tool argument naming a URI scheme, a user pasting a data URL as text, a `requestState` blob
that happens to start with `data:`, and test fixtures written by hand.

Note the failure is *worse* for the human-readable spellings. A canonical base64 data URL survives;
a plain `data:,hello` does not.

<a id="appendix-c"></a>

## Appendix C — Specification interactions

None of these is a specification violation on its own — the SDK is free to model JSON however it
likes — but each is a place where a silent string rewrite becomes protocol-visible.

- **`requestState` must be echoed exactly.** `2026-07-28`
  `basic/patterns/mrtr.mdx` requires the client to return the server's opaque `requestState`
  unchanged, and tells servers to integrity-protect it. If such a blob starts with `data:` and is
  carried as a `Value`, the client returns a re-spelled string and any HMAC or AEAD check fails. The
  server cannot distinguish that from tampering.
- **Tool schemas are arbitrary JSON Schema 2020-12 documents.** `server/tools.mdx` and
  `basic/index.mdx` permit any 2020-12 keywords. A `default`, `const`, `enum`, or `examples` value
  that is a data-URL-shaped string is rewritten in transit, so the schema a client validates against
  is not the schema the server published.
- **Mirrored request headers must agree with the body.** `2026-07-28` requires `Mcp-Param-*` values
  to match the JSON body exactly, and servers to reject a mismatch with `-32020`. A value rewritten
  by `Value` after the header was generated from the original produces a spurious mismatch.
- **Resource contents distinguish `text` from `blob`.** `server/resources.mdx` models them as
  separate fields. Inferring binary from a string's contents blurs a distinction the protocol keeps
  explicit.

<a id="appendix-d"></a>

## Appendix D — Fix options

**Option 1 — remove the inference (recommended).** Decode JSON strings as `.string`, always.
Construct `.data` explicitly where binary content is meant. Encoding `.data` continues to emit a
data URL, so producers are unaffected.

*Cost:* a source-compatible but behavior-visible change for anyone relying on the inference —
today, code that reads `.data` from a decoded payload would start reading `.string`. Given that the
inference is undocumented and silently lossy, that seems the right trade, but it is a judgement for
the maintainers.

**Option 2 — preserve the original spelling.** Keep the inference, but carry the source text so
encoding is the identity for anything that was decoded. Fixes the round trip without changing which
case callers observe.

*Cost:* `Value.data` grows a field or gains a parallel case; `Equatable`/`Hashable` semantics need a
decision (is a `.data` decoded from two different spellings of the same bytes equal?).

**Option 3 — make it opt-in.** Default to `.string`; expose a decoding option for callers that want
the old behavior.

*Cost:* the most API surface for the least benefit, but it breaks nobody.

Any option should come with a test asserting that decode-then-encode is the identity for a set of
data-URL-shaped strings, which is the property that is missing today.

<a id="appendix-e"></a>

## Appendix E — Verification and related work

- Reproduced against `main` at `a0ae212` (release 0.12.1) and against the MCP 2026-07-28 work in
  progress; the code path is byte-identical in both, so this is a pre-existing defect and not a
  regression from that series.
- Independently observed by
  [PR #273](https://github.com/modelcontextprotocol/swift-sdk/pull/273), which cites the same
  `Value.swift` behavior as motivation for a much larger change — a hand-written exact-JSON parser
  and a raw request-handling API. That pull request leaves the defect itself in place: its raw path
  covers inbound server requests only, while outbound results still encode through `Value`. This
  report is deliberately narrower: fix the coercion, in the type where it lives, for every code path
  at once. Filing it separately gives the maintainers the option of taking the small fix without
  taking the parser.
- No conformance scenario covers this today. Worth proposing one: a tool that echoes a
  data-URL-shaped string argument, asserting the value returns byte-identical.
