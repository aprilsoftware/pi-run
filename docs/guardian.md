# Guardian command review

Guardian adds an evidence-aware review between the acting agent and shell
execution. It checks whether a proposed command fits your current request and
applicable instructions, then either releases it, asks for your decision, or
withholds it.

This is useful when an ordinary-looking command could target the wrong path,
expand beyond an approved increment, affect persistent data, or reach a real
service. Guardian focuses human attention on uncertain or consequential actions
without interrupting every command.

All commands below belong in **Pi's input editor**, not the host shell.

## Understand the coverage first

Guardian reviews acting-agent tool calls named exactly `bash` or `run`, including
nested calls with those names. It can inspect bounded local evidence while
reviewing, but it does not execute the proposed command itself.

Guardian does **not** gate native `read`, `write`, or `edit`, other custom tools,
or commands you run in a host terminal. It is not a sandbox, operating-system
permission boundary, or guarantee that a model judgment is correct. Writable
mounts, credentials, and host networking remain available to uncovered tools and
released commands.

Keep task scope, targets, and intended effects explicit. Guardian supplements
[isolation boundaries](security.md), human review, access controls, and backups;
it does not replace them.

## Check and enable review

Guardian is loaded for every profile, but a profile without saved preferences
starts with review **Off**. Check the current mode and reviewer:

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

The mode is saved in the selected profile and applies to later sessions. Use
`/guardian-mode off` only when you deliberately want covered commands to proceed
without Guardian review. Check status after changing profiles or after a startup
warning rather than assuming an old setting still applies.

By default, Guardian follows the conversation model and thinking level. The menu
can select a different configured reviewer model or thinking level. Reviewer
calls can add latency and provider cost, and may send commands, instructions,
selected conversation context, and inspected file excerpts to that provider.
Choose settings appropriate for the workspace's privacy requirements.

The status row below Pi's editor shows whether Guardian is Off, On, Reviewing,
waiting for approval, or Paused. Detailed model, thinking, and status behavior is
in the [Guardian reference](reference/guardian.md).

## Respond to an execution confirmation

A completed review has three normal outcomes:

| Outcome | What happens |
| --- | --- |
| Allowed | Guardian releases this invocation without interrupting you. |
| Needs approval | Guardian displays the proposed action and asks whether to run it once. |
| Existing user restriction | Guardian withholds the invocation rather than asking you to override the restriction. |

When a dialog appears, inspect the working directory, command, arguments,
targets, and effects. Open the full action when the preview is shortened.

- **Yes** releases only this invocation. It does not approve later commands, a
  future increment, or an entire plan.
- **No** or Escape means the invocation was not executed. Further `bash` and
  `run` calls pause for that run instead of repeatedly prompting.
- A later real user message can reopen normal review for a new invocation. It
  does not replay the cancelled command or grant blanket permission.

Planning and normal authorization checkpoints remain applicable. Approving a
saved plan does not automatically authorize every command; see
[planning approval](planning.md#approve-the-saved-revision).

### If review is unavailable

A provider failure, timeout, missing reviewer, invalid response, or missing
review context is not approval. When the confirmation interface is available,
Guardian may instead ask:

```text
Run once without review?
```

Choosing Yes is your decision to release that one invocation **without a
completed reviewer assessment**. It is not an AI approval. Without an available
confirmation interface, an invocation needing confirmation is withheld.

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
separates the command, reviewer decision and evidence, human confirmation,
release or withholding, and eventual tool result. This helps explain whether an
invocation was reviewed, approved once, executed, failed, or never released.

The log is bounded diagnostics—not a complete, tamper-proof audit trail. It can
contain commands, paths, conversation excerpts, evidence, and errors. Treat it
and the complete profile as private, and review material before sharing it.
Detailed browser controls, rotation, partial-record behavior, and fields are in
the [Guardian reference](reference/guardian.md#retained-review-logs).

## Essential boundaries

- Review starts Off when no valid preferences have been saved.
- Only acting-agent `bash` and `run` calls enter this gate.
- “Run once” applies to one invocation, not the surrounding task or plan.
- A declined invocation did not execute and is never replayed automatically.
- “Run once without review?” means the reviewer did not complete.
- Allowed or released does not mean execution succeeded or its effects were
  independently verified.
- Instructions and policy guide decisions but do not reduce filesystem,
  credential, network, or remote-system permissions.

For reviewer selection, evidence sources, status transitions, interrupted
reviews, confirmation invalidation, and log details, see the
[Guardian behavior reference](reference/guardian.md).

[Documentation index](index.md) · [Profiles](profiles.md) · [Planning](planning.md)
