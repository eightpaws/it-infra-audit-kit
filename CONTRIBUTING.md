# Contributing

The kit is judged by two things: it must never write to the systems it inspects, and every finding must be explainable to the person who owns the system.

## A false positive

The most useful report is a check that cried wolf. Open an issue with:

| Field | Why |
|---|---|
| Check ID and the line from the report | so the check can be fixed, not the whole kit |
| What the system actually looks like | the real value the check misread |
| The command the check runs | so it can be replaced with a better probe |
| OS and module versions | `ActiveDirectory` behaviour changes between Windows releases |

## A new check

A check is accepted when it answers "what breaks the business or leaks data", not "what is untidy". Include:

- what it reads and which command it uses (read-only, no exceptions);
- what a healthy value looks like, and what a risk level means for a non-specialist;
- what it cannot see (missing elevation, absent module, virtualised environment);
- how it behaves when the system is unavailable: a check that fails closed must say so.

## Code changes

- Read-only by construction: no `Set-`, no writes, no service restarts. If a command needs elevation, mark the result "unreadable" rather than guessing.
- Every finding carries a severity and a one-line "what to do first".
- Output shape is fixed: the JSONL rows and the rendered table are a contract; changing them is a breaking change and needs a version bump.
- Russian and English documentation move together: `README.md` and `README.en.md`, same sections.

## License

Code and scripts: MIT. Text, documentation and sample reports: CC BY 4.0. See `LICENSE` and `LICENSE-DOCS`.
