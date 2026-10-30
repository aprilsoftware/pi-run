# Call a Friend testing

The ordinary CAF suites use temporary profiles and fake providers. They must not
contact configured providers:

```bash
bash tests/caf-config-test.sh
bash tests/caf-lifecycle-test.sh
bash tests/caf-agent-loop-test.sh
bash tests/caf-dialogue-agent-loop-test.sh
```

The failure agent-loop test uses Pi's real `createAgentSession` lifecycle with a
synthetic provider. It verifies that a failed `call_friend` receives exactly one
explain-only primary response with no model-visible tools, then restores the
previous tool set after `agent_settled`.

The dialogue agent-loop test uses the same native lifecycle with synthetic
primary, reviewer, and CAF models. It verifies that the CAF agent can request
more than three focused questions, the primary can automatically issue a second
standalone `call_friend` without another user turn, the CAF reviewer independently
reviews both disclosures, retained CAF history reaches the next CAF agent
invocation without implicit primary context, and the primary receives the final
answer. Protocol and lifecycle fixtures separately verify a fourth consultation
round and the high emergency persistence boundary. CAF lifecycle fixtures also
verify multiple sequential searches, independent review of every query,
research-before-clarification retention, legacy single-search restoration, and
the cumulative research-state boundary. Neither test contacts a real provider or
friend.

## Opt-in Guard-review evaluation

`tests/caf-review-eval.sh` evaluates the source-tree CAF disclosure contract
against the configured Guard reviewer before building or releasing an image. It
uses only the fictional cases in `tests/caf-review-cases.json` and skips by
default:

```bash
bash tests/caf-review-eval.sh
```

Enable all cases explicitly with one command:

```bash
CAF_REVIEW_EVAL=1 bash tests/caf-review-eval.sh
```

To investigate one case without sending the other fixtures, select its ID:

```bash
CAF_REVIEW_EVAL=1 CAF_REVIEW_EVAL_CASE=minimized-retry-authorization bash tests/caf-review-eval.sh
```

The evaluator's `production` strategy is the default and references
`CAF_GUARD_REVIEW_DOMAIN` directly. Production review receives compact initial
evidence and exposes the same bounded history, file, resource, user-change, and
guidance tools as the CAF reviewer agent, plus `caf_guard_decide`. The earlier
selectable A/B strategy established comparative evidence but is no longer
exposed by the evaluator.

Repeat each selected case up to ten times with
`CAF_REVIEW_EVAL_REPEAT`. Repetitions create fresh private reviewer transcripts:

```bash
CAF_REVIEW_EVAL=1 CAF_REVIEW_EVAL_CASE=exact-referential-confirmation CAF_REVIEW_EVAL_STRATEGY=production CAF_REVIEW_EVAL_REPEAT=5 bash tests/caf-review-eval.sh
```

The evaluator reports per-run results and aggregate correctness, incomplete
responses, reviewer requests, evidence calls, and input bytes.

The evaluator contacts only the configured Guard reviewer. It never contacts
the configured friend, runs commands, reads real conversation history, or
writes the selected profile. Each case has a fresh private reviewer transcript
and reports only its ID, expected and actual decision, bounded request/evidence
counts, strategy, repetition, and a bounded incomplete-review error. The fixtures
cover direct and delegated abstract authorization, required minimization, a
minimized retry, exact referential confirmation, long-session current authority,
standing and current refusal, destination mismatch, and broad requests carrying
unnecessary private detail. A fixture can add more than 100 older messages and
set `authorizationComplete` to `false` to verify that the reviewer distinguishes
a compact initial snapshot from the complete current-branch evidence available
through its bounded tools.

This is an opt-in semantic evaluation, not a deterministic unit test: provider
behavior can vary and requests can incur charges. A release candidate should
not proceed while the configured release reviewer repeatedly disagrees with the
case contract. Ordinary offline tests still use fake providers and remain the
required deterministic gate.

## Opt-in live candidate

`tests/caf-live-test.sh` is a source-level interoperability check. By default it
skips before loading Pi or contacting a provider:

```bash
bash tests/caf-live-test.sh
```

A live invocation must explicitly select exactly one mode:

```bash
CAF_LIVE_TESTS=1 \
CAF_LIVE_TEST_MODE=guarded \
bash tests/caf-live-test.sh
```

For a two-round guarded clarification consultation:

```bash
CAF_LIVE_TESTS=1 \
CAF_LIVE_TEST_MODE=guarded-dialogue \
bash tests/caf-live-test.sh
```

Or for one unreviewed answer candidate:

```bash
CAF_LIVE_TESTS=1 \
CAF_LIVE_TEST_MODE=unreviewed \
bash tests/caf-live-test.sh
```

Guarded modes require distinct configured Guard reviewer and CAF friend models.
The basic candidate submits one fixed synthetic disclosure to the reviewer and,
if allowed, sends one fixed fictional public API question to the friend. The
`guarded-dialogue` candidate requires the friend to request one fictional
compatibility fact through `caf_ask_primary`, then sends that authorized fact in
a second standalone, independently reviewed call. It requires one consultation
identity, rounds one and two, and a final answer. The reviewer can use more than
one model request per review when its bounded agent loop requires it. The
unreviewed candidate sends the basic friend question while the temporary Guard
Runtime is Off and asserts that it made zero reviewer requests.

The candidate does not enable friend-generated public search and does not expose
nested tools. It cannot execute the fictional command or any workspace action.
There is no automatic retry or repetition. An outer 900-second timeout bounds
the complete invocation.

The harness reads the selected profile's authentication, model registry, and
explicit Guard/CAF model selections. Authentication is opened through Pi's
read-only credential store, model-catalog network refresh is disabled, and the
harness verifies that the relevant real-profile files remain byte-identical.
Configured providers can still incur charges and receive request metadata.
OAuth credentials that require a storage refresh can fail because writes are
not permitted.

All prompt-bearing state is synthetic and temporary:

- profile and workspace instructions;
- Guard and CAF policy;
- session and authorization message;
- workspace files;
- Guard/CAF journals and mode state.

The user-supplied disclosure to the friend contains only the fixed fictional
public API question and its fixed purpose; the friend also receives CAF's role
instructions and the synthetic temporary policy. The Guard reviewer receives
the synthetic authorization, proposed friend disclosure, synthetic
instructions/policy, bounded initial authorization evidence, and operation-specific
bounded evidence tools over only the temporary synthetic session and workspace.
Neither destination receives real session history, real profile instructions,
unrelated workspace files, or credentials from the harness. Temporary state is
removed on exit.

A successful result is one JSON object reporting only mode, final CAF status,
model identifiers, model-request counts, and fixed safety assertions. It does
not print or persist the friend answer outside the temporary directory. A pass
is a bounded interoperability signal, not proof of provider behavior or a
security guarantee.
