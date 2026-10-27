# Guardian and shared Guard review

Guardian applies the shared evidence-aware Guard review layer to acting-agent
shell execution. When Guard is On, it checks whether a proposed command fits
your current request and applicable instructions, then either releases it or
challenges and withholds the action. The primary and Guardian first try to
resolve that challenge themselves; you arbitrate only if disagreement remains.
The same configured Guard reviewer also checks Call a Friend disclosures while
Guard is On.

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

Guardian is loaded for every profile. Fresh profiles, genuinely new sessions,
and older sessions without mode metadata start with Guard review **Off** unless
the selected profile's new-session default was deliberately changed. Check the
current mode and reviewer:

```text
/guardian-status
```

Open the complete settings menu:

```text
/guardian
```

Enable shared review directly:

```text
/guardian-mode on
```

Mode belongs to the current session. Resuming that session restores its mode,
and branch navigation keeps the same session-wide setting. Change the default
for genuinely new sessions separately:

```text
/guardian-default on|off
```

Changing the default does not alter the current session. Use
`/guardian-mode off` when you deliberately want covered commands to proceed
without Guard review. Turning it Off also makes an enabled CAF use its bounded
unreviewed path, cancels active Guard/CAF work without retry, and clears an open
Guardian dispute; it never replays a withheld invocation.

The Guard reviewer must be explicitly selected; Pi-Run does not silently use
the conversation model or CAF friend. The menu and `/guardian-model` and
`/guardian-thinking` commands save the shared reviewer preferences in private
`guard/config.json`. Reviewer calls can add latency and provider cost, and may
send commands, CAF disclosures, instructions, selected conversation context,
and inspected file excerpts to that provider. Choose a trusted destination
appropriate for the workspace's privacy requirements.

Guard Runtime shows two rows below Pi's editor: the Guard row with reviewer model
and activity, and the CAF row with friend model and activity. Detailed model,
thinking, mode, and status behavior is in the
[Guardian reference](reference/guardian.md).

## Resolve a challenge or arbitrate a dispute

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

A `retract` position withdraws the command immediately without another reviewer
call. A `narrow` position also withdraws the original; any replacement command
receives normal Guardian review. Both outcomes close the challenge and let the
primary continue without asking you.

For `contest`, Guardian performs a fresh bounded assessment of the original
action and structured position. This additional reviewer-model call can add
provider latency and cost. The explanation remains an untrusted agent claim,
never user authority. Status shows `dispute · assessing` during this pass.

If Guardian reports **Concern resolved**, the challenge closes and the primary
may propose the exact command once more without another reviewer call. The
original tool call itself remains cancelled and is not replayed by Guardian.
Changed arguments, working directory, session state, or user direction invalidate
the one-use release and trigger normal review.

**Concern remains**, **User restriction remains**, and **Assessment unavailable**
leave a genuine unresolved dispute and stop automatic follow-up for your
judgment. If the agent submits nothing, settlement also closes read access and
waits for you without another model call.

When human arbitration is required, respond normally to approve a defined scope,
reject it, request clarification, or give a different direction. Your message
clears the dispute for fresh review, but its presence alone is not approval.

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

While Guard is On, a provider failure, timeout, missing reviewer, invalid
response, or missing review context is not approval. Guardian withholds the
invocation and opens the same challenge workflow. A primary retraction can close
the challenge, but a contested action remains stopped unless Guardian completes
an `ALLOW` reassessment. It never silently downgrades an On review to unreviewed
execution. You can provide new direction, use
`/guardian-resume` without granting authority, retry later, or deliberately turn
Guard Off for the session.

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

- Fresh profiles and genuinely new sessions default review Off unless the
  profile-specific future-session default was deliberately changed; resumed
  sessions restore their recorded mode.
- Guard mode is shared: On reviews Guardian commands and CAF disclosures; Off
  skips command review and lets enabled CAF use its bounded unreviewed path.
- Normal review covers acting-agent `bash` and `run`; an open dispute blocks all acting-agent tools except its bounded native reads.
- A disputed invocation did not execute and is never replayed automatically; an accepted contest permits only one exact new invocation.
- Retraction or narrowing withdraws the original without human arbitration; narrowing grants no authority to a replacement.
- Human arbitration is required only when a contest remains unresolved or reassessment is unavailable.
- `/guardian-resume` clears only the dispute latch and grants no authority.
- While Guard is On, reviewer failure opens a dispute and never releases the
  invocation or downgrades it to unreviewed execution.
- Allowed or released does not mean execution succeeded or its effects were
  independently verified.
- Instructions and policy guide decisions but do not reduce filesystem,
  credential, network, or remote-system permissions.

For reviewer selection, evidence sources, dispute transitions, interrupted
reviews, and log details, see the
[Guardian behavior reference](reference/guardian.md).

[Documentation index](index.md) · [Profiles](profiles.md) · [Planning](planning.md)
