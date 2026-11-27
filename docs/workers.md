# RPC Workers

The Worker interface is an experimental, machine-oriented execution primitive for
an external Factory/controller. Ordinary `pi-run .` remains interactive and does
not depend on Factory, Herdr, or a daemon. Run these commands on the Docker host.

A Worker is one foreground Pi RPC process with a fixed profile, workspace,
conversation, and appended Role. Factory owns orchestration, human interaction,
logs, retries, and task success. Pi-Run owns environment validation, execution,
identity binding, locking, and bounded cleanup. No completion automatically
commits, integrates, finishes a worktree, pushes, releases, deploys, or selects
another task.

## Commands

```bash
pi-run worktree create review-one /path/to/repository --json
pi-run --profile default worker launch /path/to/worktree --role-file /path/to/reviewer.txt
pi-run worker inspect 'worker-v1:…' --json
pi-run worker resume 'worker-v1:…'
```

`worktree create` requires the name, repository, and `--json`. It uses the same
managed-worktree rules as `worktree start`: exact committed HEAD, no copying of
dirty source changes, no Pi/model launch, and no automatic integration. Its JSON
object has `schemaVersion: 1`, `workspaceId`, `repositoryId`, `name`, `branch`,
`path`, and `base`. Use its `path` for Worker launch. The offline Git helper still
requires the existing local utility image.

`worker launch` requires a workspace and a nonempty UTF-8 Role file, at most
256 KiB, without NUL bytes. It accepts no arbitrary Pi argument passthrough.
Select the profile with the ordinary leading `--profile` option. `inspect` and
`resume` resolve the original profile and workspace from the reference; they do
not accept a redundant profile override or choose a newest conversation.

Launch uses the existing prepared-image validation, then the immutable image ID,
`--pull never`, non-TTY stdin, and Docker's init process. The prepared core must
contain the Worker adapter from this source. Building/upgrading images remains
an explicit host action; launch does not build, pull, or fall back. Restricted
mode retains the version-matched egress sidecar and its existing protections.

## Transport v1

Keep the child's stdin **and** stdout open. Send UTF-8 JSON objects, one per LF;
CRLF is accepted. Split only on LF, not Unicode paragraph/line separators. Read
stdout continuously and respect pipe backpressure. Diagnostics go to stderr.
Pi RPC messages, events, and supported extension UI records retain their native
shape; small Pi-Run lifecycle records use a separate `pi_run_` namespace.

Wait for:

```json
{"type":"pi_run_worker_ready","schemaVersion":1,"reference":"worker-v1:…","sessionId":"…","sessionFile":"/profile/sessions/…/….jsonl","commands":["…"]}
```

Readiness follows an actual Pi `get_state` exchange and durable host binding
publication. It means the RPC session is selected—not that a provider is
reachable, credentials work, or a conversation has been saved. Startup UI
requests can arrive before readiness and may require a response. Work messages
before readiness receive errors.

```json
{"type":"prompt","id":"work-1","message":"Review the current changes."}
{"type":"prompt","id":"work-2","message":"Also check error handling.","streamingBehavior":"followUp"}
{"type":"abort","id":"cancel-1"}
{"type":"pi_run_shutdown","id":"stop-1"}
```

A prompt response acknowledges acceptance/queueing, not completion. Continue
reading through `agent_settled`. That event, a zero exit code, and an agent's own
success claim are **not quality gates**. Factory must assess results independently.

### Supported operations

- `prompt`, `steer`, `follow_up`, `clear_queue`, `abort`, `abort_retry`.
- `get_state`, `get_messages`, `get_session_stats`, `get_entries`, `get_tree`,
  `get_last_assistant_text`, `get_available_models`,
  `get_available_thinking_levels`.
- `set_session_name`, `compact`.
- `extension_ui_response` for pending supported dialogs.
- `pi_run_shutdown` for intentional termination.

IDs are optional strings up to 256 characters; outstanding IDs must be unique.
The adapter remaps command IDs internally, avoiding collisions with its own
queries. Unknown commands, session new/switch/fork/clone, model/configuration
mutations, controller-side shell execution, and slash-command prompts are
rejected. Ordinary task messages can still direct the agent to use its tools.
This command subset protects lifecycle invariants; it is not a new permission
system or a sandbox against code inside the container.

`select`, `confirm`, `input`, and `editor` requests use native
`extension_ui_request` / `extension_ui_response` IDs. Forward them to Factory's
human interface, then send the appropriate `value`, `confirmed`, or
`cancelled: true`. Pi-Run never supplies approval. Notifications require no
response. Pi's supplied dialog timeouts still apply. TUI-only custom components
remain unavailable; `/snapshot` is not an RPC feature.

### Bounds and failure handling

- Input records: 8 MiB maximum; output records: 32 MiB maximum. Oversized,
  malformed, or unterminated records stop the Worker instead of corrupting the
  stream. Large history requests may therefore require narrower `get_entries`
  queries.
- At most 128 outstanding requests and 128 pending dialogs.
- Internal RPC requests: 30 seconds. Host readiness: up to 60 seconds after
  starting the container; Docker setup calls have 30-second deadlines with
  two-second kill escalation.
- A heartbeat record (`pi_run_worker_heartbeat`, schema version 1) every five
  seconds helps detect a closed output pipe even when idle. Output stalled for
  30 seconds terminates the Worker; a blocked Pi input pipe has the same bound.
  This is not a network heartbeat service.
- Abort cancels pending dialogs, waits for already-submitted prompt acceptance,
  clears steering/follow-up queues, then invokes Pi abort. New work is rejected
  while abort is pending. A stuck/failed abort stops the Worker rather than
  returning false availability.
- `pi_run_shutdown` requests intentional shutdown. EOF, output loss, SIGTERM,
  SIGHUP, and SIGINT also trigger shutdown, but are not classified as successful
  intentional exits. Shutdown clears queues, aborts, closes Pi input, and allows
  ten seconds before forcefully ending its process group. The host removes only
  containers carrying this launch's random label, with bounded Docker calls.
- `pi_run_worker_exit` reports the Pi subprocess outcome (`scope: "pi"`). The
  final **launcher exit status** is authoritative for host cleanup and automatic
  snapshot failures. Zero means orderly intentional termination, not task
  success; protocol/connection failures normally return 74.

A Factory must close its pipes when control is lost. A leaked open descriptor or
a stalled upstream application is not detectable as human abandonment. SIGKILL,
Docker-daemon failure, and host failure can prevent immediate cleanup. If cleanup
cannot be confirmed, Pi-Run retains ownership for host investigation instead of
allowing another writer. No rollback of completed tools or remote effects is
promised.

## Binding, inspection, and resume

Host-private data is stored under:

```text
<PI_RUN_HOME>/worker-sessions/<opaque-id>/
    binding.json
    role.txt
```

Directories are private (0700), files single-link/private (0600), and binding
updates are atomic. Only the selected Role file is mounted, read-only at
`/run/pi-run-role.txt`. The binding directory is never mounted. Workspace/Git
mounts that would expose it are refused. Pi appends the Role with
`--append-system-prompt`, preserving profile baseline instructions. A different
Role means a new Worker conversation. The reference is a lookup key, not a
credential or authorization token.

Bindings retain profile, stable workspace identity, exact Pi session identity
and filename, Role digest, prepared image identity, and configuration digest.
They do not contain live process state, task outcomes, or a global Worker log.
No automatic retention/deletion policy is introduced.

`inspect --json` reports bounded binding metadata, workspace availability,
`transcriptSaved`, `configurationChanged`, `runtimeMatches`, and `resumable`.
Unavailable checks can be `null`. This is preflight information, not a live
process registry or a reservation. It does not print Role contents or credentials.

Pi saves a new conversation lazily when user/assistant entries exist. A ready
but unused Worker can have a reference without a saved transcript. Inspection
reports that fact; resume refuses the missing file instead of silently starting
a replacement conversation.

Resume checks the session header and its `/workspace` working directory,
reapplies the original Role, and verifies both startup identity and configuration.
The conservative fingerprint covers profile configuration, baseline instructions,
settings/models/web-search/Git configuration, Guardian/Guard/CAF configuration
and policy, credential files, runtime context, active skills, and workspace
`.pi/settings.json`. Changes to these inputs (including byte-level rewrites) or
to the prepared image refuse resume with an explanation; there is no force-drift
option. Conversation history, logs, caches, ordinary source edits, and OAuth
refresh state in `auth.json` are excluded. Do not treat a fingerprint as proof of
security, correctness, or unchanged external infrastructure.

Missing/moved workspaces require explicit reconnection using existing workspace
commands. Resume never clones source, builds images, replays work automatically,
or guesses another conversation. Reconcile previous effects before sending a
new task instruction.

## Ownership and recovery

Workers use the existing managed-worktree launch lock, including while idle;
interactive managed-task launches and `worktree finish` respect the same lock.
Workers also take workspace exclusion for direct workspaces and a binding lock
for duplicate resume. Distinct workspaces can run concurrently. Ordinary direct
TUI launches retain their existing behavior and are not a universal exclusive
filesystem lock.

A stale Worker lock is deliberately **not** automatically reclaimed based only
on a dead launcher PID: a container may outlive its CLI. Verify the exact
container, descendants, and sidecar on the host before deliberately removing a
stale lock. Never use `worktree finish` as process cleanup.

Encrypted complete snapshots include Role/session bindings alongside profiles
and conversations. Restore never starts Workers or restores live locks. Older
snapshots without Worker metadata restore an empty binding set, not mismatched
live references. Workspaces, machine paths, and images still require normal
reconnection/preparation; restored bindings do not relax drift checks.

Existing profile-driven automatic snapshots run after a successful intentional
`pi_run_shutdown`, not EOF/connection loss. Snapshot output goes to stderr and
never restarts a Worker. Restic/network access still follows the separately
configured snapshot backend.

## Validation

```bash
bash tests/worker-test.sh
bash tests/worker-rpc-test.sh
bash tests/worker-roundtrip-test.sh
```

The first two use disposable fake Docker/Pi peers plus an isolated, offline
installed-Pi RPC check without prompts or provider calls. They cover creation-only
behavior, multiple messages, exact resume, Role drift, interactions, queued abort, framing,
limits, timeouts, networking argv, cleanup refusal, and ordinary runtime loading.
Snapshot tests cover binding portability, older snapshots, and interrupted-restore
rollback. Fake mounts are not evidence of real Docker isolation.

Opt-in **host** smoke acceptance requires a non-root user, Docker, Bash, jq,
Git, GNU `timeout`, and an already-built local candidate core containing the
adapter. The host client does not require Node.js; Node runs inside the image:

```bash
PI_RUN_TEST_REAL_DOCKER=1 PI_RUN_WORKER_TEST_CORE=<local-candidate> bash tests/worker-real-docker-test.sh
```

This explicitly builds a disposable profile image and tests offline non-TTY
readiness, read-only Role mounting, knowledge initialization, connection loss,
and cleanup. The RPC phase has a 90-second deadline plus a 15-second forced-stop
grace period; `PI_RUN_WORKER_TEST_TIMEOUT_SECONDS` can set the deadline to 1–300
seconds. Failed runs retain their disposable home/worktree and prepared image
for inspection rather than deleting data that might still be mounted. Successful
runs remove their fixtures and attempt to remove the disposable profile image.
Without opt-in it reports SKIP. `bash tests/worker-host-client-test.sh` checks the
controller with isolated fake Docker/launcher commands and no host Node; it is
not real-Docker acceptance. The smoke test is not real-provider, full
restricted-egress, or live Guardian/CAF acceptance. No live-provider call,
installation, publication, or release is performed by the deterministic suite.

### Offline conversation and exact-resume acceptance

The additional round-trip acceptance uses real Pi and the unchanged Worker adapter
with a deterministic OpenAI-compatible HTTP/SSE fixture. The mock listens only on
loopback **inside the offline Worker container**. It checks that the original Role
and baseline instructions reach Pi's provider request, and replies with assertions
about the conversation history rather than generating model output. Its fixed
dummy API key is not a credential and is used only in the disposable profile.

On the approved Docker host, with the same already-built candidate core:

```bash
PI_RUN_TEST_REAL_DOCKER=1 PI_RUN_WORKER_TEST_CORE=<local-candidate> bash tests/worker-roundtrip-real-docker-test.sh
```

This tests two messages in one process, cancellation of a genuinely open response
stream with pending steering/follow-up work, post-abort availability, saved history,
intentional shutdown, and exact resume with the same reference/session/Role. It
changes the caller's original Role input before resume to verify that the stored
copy is used. The restored history must reach the mock provider on the next turn.
Binding inspection, successful launcher exit, and actual container/lock cleanup
are checked independently of the Pi exit event.

The host needs Bash, Docker, jq, Git, GNU timeout and standard Linux/GNU tools—not
Node. A separate offline utility container runs the test controller through private
FIFO mounts. Neither container receives the Docker socket; no ports are published.
The provider fixture is copied into the disposable Worker's writable container
layer after readiness. The candidate image, entrypoint, adapter, and protection
extensions are not replaced or disabled. Tests never auto-answer approval dialogs.
The RPC phases have a combined 240-second deadline plus 15 seconds of termination
grace. Failures retain the temporary home and diagnostics for inspection.

`worker-roundtrip-test.sh` validates the same mock provider and FIFO controller
against installed Pi/the adapter with isolated configuration. That local regression
requires Node/Pi where it runs (normally the development container), uses no real
credentials, and rejects five invalid model/prompt/baseline/Role inputs as well.
It substitutes only the host binding handshake and disables extensions in that
local test; it is
not evidence of Docker mounting, host binding, or protection-extension behavior.
The real-Docker test leaves the normal extensions loaded but emits no tool calls.
Neither test establishes live-model quality, live Guardian/CAF review effectiveness,
or the complete restricted-network provider path.
