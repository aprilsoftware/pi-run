# Call a Friend testing

The ordinary CAF suites use temporary profiles and fake providers. They must not
contact configured providers:

```bash
bash tests/caf-config-test.sh
bash tests/caf-lifecycle-test.sh
```

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

The default `agentic` strategy is the production evidence-tool workflow. The
experimental `decision-only` strategy supplies the same bounded initial
evidence but exposes only `caf_guard_decide`; it cannot investigate further:

```bash
CAF_REVIEW_EVAL=1 CAF_REVIEW_EVAL_STRATEGY=decision-only bash tests/caf-review-eval.sh
```

Repeat each selected case up to ten times with
`CAF_REVIEW_EVAL_REPEAT`. Repetitions create fresh private reviewer transcripts:

```bash
CAF_REVIEW_EVAL=1 CAF_REVIEW_EVAL_CASE=exact-referential-confirmation CAF_REVIEW_EVAL_STRATEGY=decision-only CAF_REVIEW_EVAL_REPEAT=5 bash tests/caf-review-eval.sh
```

The evaluator reports per-run results and aggregate correctness, incomplete
responses, reviewer requests, evidence calls, and input bytes. Strategy
selection changes only the source-level evaluator and does not change the
installed or production CAF reviewer.

The evaluator contacts only the configured Guard reviewer. It never contacts
the configured friend, runs commands, reads real conversation history, or
writes the selected profile. Each case has a fresh private reviewer transcript
and reports only its ID, expected and actual decision, bounded request/evidence
counts, strategy, repetition, and a bounded incomplete-review error. The fixtures
cover direct and delegated abstract authorization, required minimization, a
minimized retry, exact referential confirmation, incomplete authorization,
standing and current refusal, destination mismatch, and broad requests carrying
unnecessary private detail. A fixture can set `authorizationComplete` to `false`
to verify that a truncated authorization snapshot cannot support `ALLOW`.

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

or:

```bash
CAF_LIVE_TESTS=1 \
CAF_LIVE_TEST_MODE=unreviewed \
bash tests/caf-live-test.sh
```

The guarded candidate requires distinct configured Guard reviewer and CAF friend
models. It submits one fixed synthetic disclosure to the Guard reviewer and, if
allowed, sends one fixed fictional public API question to the friend. The
reviewer can use more than one model request if its bounded correction protocol
requires it. The unreviewed candidate sends the same friend question while the
temporary Guard Runtime is Off and asserts that it made zero reviewer requests.
Both modes make exactly one friend request.

The candidate does not enable friend-generated public search and does not expose
nested tools. It cannot execute the fictional command or any workspace action.
There is no automatic retry or repetition. An outer 420-second timeout bounds
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
instructions/policy, and any bounded evidence it requests. Neither destination
receives real session history, real profile instructions, unrelated workspace
files, or credentials from the harness. Temporary state is removed on exit.

A successful result is one JSON object reporting only mode, final CAF status,
model identifiers, model-request counts, and fixed safety assertions. It does
not print or persist the friend answer outside the temporary directory. A pass
is a bounded interoperability signal, not proof of provider behavior or a
security guarantee.
