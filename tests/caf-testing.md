# Call a Friend testing

The ordinary CAF suites use temporary profiles and fake providers. They must not
contact configured providers:

```bash
bash tests/caf-config-test.sh
bash tests/caf-lifecycle-test.sh
```

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
