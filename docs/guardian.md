# Guardian command review

Guardian adds an evidence-aware review between the acting agent and shell
execution. It checks whether a proposed command fits your current request and
applicable instructions, then either releases it or opens a human-arbitrated
dispute that withholds the action.

This is useful when an ordinary-looking command could target the wrong path,
expand beyond an approved increment, affect persistent data, or reach a real
service. Guardian focuses human attention on uncertain or consequential actions
without interrupting every command.

All commands below belong in **Pi's input editor**, not the host shell.

## Understand the coverage first

Guardian reviews acting-agent tool calls named exactly `bash` or `run`, including
nested calls with those names. It can inspect bounded local evidence while
reviewing, but it does not execute the proposed command itself.

Outside a dispute, Guardian does **not** gate native `read`, `write`, or `edit`,
other custom tools, or commands you run in a host terminal. While a dispute is
open, it permits only bounded native `read` calls and withholds other acting-agent
tools. It is not a sandbox, operating-system permission boundary, or guarantee
that a model judgment is correct. Writable
mounts, credentials, and host networking remain available to uncovered tools and
released commands.

Keep task scope, targets, and intended effects explicit. Guardian supplements
[isolation boundaries](security.md), human review, access controls, and backups;
it does not replace them.

## Check and enable review

Guardian is loaded for every profile, and every new session starts with review
**Off**. Check the current mode and reviewer:

```text
/guardian status
```

Open the complete settings menu:

```text
/guardian
```

Enable command review directly:

```text
/guardian-mode on
```

Mode belongs to the current session. Resuming that session restores its mode,
and branch navigation keeps the same session-wide setting. Every new session
starts Off, even when another session in the selected profile has Guardian On.
Use `/guardian-mode off` when you deliberately want covered commands in the
current session to proceed without Guardian review. Turning it Off also clears
an open dispute; it never replays the withheld invocation.

By default, Guardian follows the conversation model and thinking level. The menu
can select a different configured reviewer model or thinking level; those
preferences are saved in the profile and apply to later sessions. Reviewer
calls can add latency and provider cost, and may send commands, instructions,
selected conversation context, and inspected file excerpts to that provider.
Choose settings appropriate for the workspace's privacy requirements.

The status row below Pi's editor shows whether Guardian is Off, On, Reviewing,
or in a Dispute while the agent investigates or waits for you. Detailed model,
thinking, and status behavior is in the [Guardian reference](reference/guardian.md).

## Arbitrate a dispute

A completed review has three normal outcomes:

| Outcome | What happens |
| --- | --- |
| Allowed | Guardian releases this invocation without interrupting you. |
| Missing authority or material uncertainty | Guardian withholds the invocation and opens a dispute. |
| Existing user restriction | Guardian withholds the invocation and opens a dispute so only you can change the applicable direction. |

The original invocation is cancelled and never resumed. Guardian shows its reason
to you and the acting agent. The agent may make at most six native `read` calls
to inspect files, but commands, edits, writes, network tools, and unknown tools
remain blocked. During that investigation Guardian exposes a model-only
`guardian_justify` tool. The agent submits whether it retracts, narrows, or
contests its proposal, a concise explanation, and optional evidence references.

Guardian then performs a fresh bounded assessment of the original action and the
structured position. This is an additional reviewer-model call and can add
provider latency and cost. The explanation remains an untrusted agent claim,
never user authority. The transcript panel reports **Concern resolved**, **Concern
remains**, **User restriction remains**, or **Assessment unavailable**, together
with Guardian's reason. Status shows `dispute · assessing` during this pass.

Submission terminates the acting agent's automatic follow-up and leaves the
dispute waiting for you regardless of the assessment. Even **Concern resolved**
does not release or replay the original invocation. If the agent submits nothing,
settlement still closes read access and waits for you without another model call.

Respond normally to approve a defined scope, reject it, request clarification,
or give a different direction. Your message clears the dispute for fresh review,
but its presence alone is not approval. Every later command is a new invocation.

To clear the latch without adding conversational authority, use:

```text
/guardian-resume
```

This neither authorizes nor replays anything. If the unresolved problem remains,
Guardian can immediately open another dispute.

Planning and normal authorization checkpoints remain applicable. Approving a
saved plan does not automatically authorize every command; see
[planning approval](planning.md#approve-the-saved-revision).

### If review is unavailable

A provider failure, timeout, missing reviewer, invalid response, or missing
review context is not approval. Guardian withholds the invocation and opens the
same dispute workflow. It never offers to run the invocation without a completed
review. You can provide new direction, use `/guardian-resume` without granting
authority, retry later, or deliberately turn Guardian Off for the session.

Command release is also separate from execution success. If an executed action
fails or its effects are uncertain, verify what happened before retrying,
especially for non-idempotent operations.

## Customize review priorities

The selected profile's `guardian/guardian.md` adds your review priorities to the
built-in contract, profile instructions, repository instructions, and current
request. Use it to identify concrete protected resources—for example a shared
database, production namespace, required service, credential boundary, or
publication target.

Policy text guides review; it does not grant authority, change tool coverage, or
create an operating-system restriction. Keep mode, model, and thinking settings
in the Guardian menu rather than editing private configuration casually.

## Inspect retained reviews

Open the read-only log browser:

```text
/guardian-log
```

Use `/guardian-log <search terms>` to start with a filter. Each retained review
separates the command, reviewer decision and evidence, dispute state, release or
withholding, and eventual tool result. Historical entries can still contain the
older one-time confirmation fields. This helps explain whether an invocation was
reviewed, executed, failed, or never released.

The log is bounded diagnostics—not a complete, tamper-proof audit trail. It can
contain commands, paths, conversation excerpts, evidence, and errors. Treat it
and the complete profile as private, and review material before sharing it.
Detailed browser controls, rotation, partial-record behavior, and fields are in
the [Guardian reference](reference/guardian.md#retained-review-logs).

## Essential boundaries

- Every new session starts with review Off; resumed sessions restore their mode.
- Normal review covers acting-agent `bash` and `run`; an open dispute blocks all acting-agent tools except its bounded native reads.
- A disputed invocation did not execute and is never replayed automatically.
- `/guardian-resume` clears only the dispute latch and grants no authority.
- Reviewer failure opens a dispute and never releases the invocation.
- Allowed or released does not mean execution succeeded or its effects were
  independently verified.
- Instructions and policy guide decisions but do not reduce filesystem,
  credential, network, or remote-system permissions.

For reviewer selection, evidence sources, dispute transitions, interrupted
reviews, and log details, see the
[Guardian behavior reference](reference/guardian.md).

[Documentation index](index.md) · [Profiles](profiles.md) · [Planning](planning.md)
