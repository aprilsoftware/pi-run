# Planning before execution

Planning gives you and Pi a place to investigate a goal, compare approaches, and
agree on what should happen before implementation begins. The saved draft makes
the intended outcome, scope, risks, and validation visible for review instead of
leaving them scattered through a conversation.

Planning works for software changes and operational procedures. Approval hands
the agreed revision back to the normal workflow; it does not automatically
execute every step.

All commands below belong in **Pi's input editor**, not the host shell.

## Start a planning discussion

Give `/plan` a goal:

```text
/plan Improve the repository's build documentation without changing the build.
```

For an administrative task, include operational limits:

```text
/plan Prepare a diagnostic procedure for startup failures. Do not connect to servers or restart services.
```

Pi enters planning mode and starts a discussion focused on investigation and
design. Use the conversation to clarify desired outcomes, alternatives,
dependencies, risks, exclusions, and validation.

**Planning is not read-only and is not a sandbox.** Normal tools remain available.
If investigation must not edit files, execute commands, or contact remote
systems, state those restrictions explicitly. Planning changes the objective,
not tool permissions.

Guardian remains independent. Entering or leaving planning does not enable,
disable, or reconfigure [Guardian](guardian.md).

## Save and refine the draft

When the direction is ready, ask the agent to record it:

```text
Record the current plan, including its scope, unresolved questions, and validation.
```

The agent uses the planning-only `plan_record` tool. This saves a title, goal,
and Markdown body in session metadata; it does not create a project file or
approve work.

Inspect the saved revision:

```text
/plan-show
```

Discussion after the last record is not part of the saved draft. Ask the agent
to record refinements, then use `/plan-show` again before approval.

A bare `/plan` returns to planning mode without discarding the draft or starting
a new model turn. By contrast, `/plan <goal>` starts a fresh goal and discards
the previous active draft.

## Approve the saved revision

After reviewing `/plan-show`, enter:

```text
/plan-approve
```

Pi displays the complete saved plan and asks for confirmation. Approval applies
to that exact saved title, goal, and body. Unsaved discussion, another branch's
draft, or a later revision is not included.

On confirmation, Pi records approval, exits planning, and sends one handoff to
the agent. Normal instructions and authorization checkpoints still apply. With
the default development workflow, the agent investigates and proposes a concrete
increment before implementation; approving the overall plan does not approve all
increments or shell commands.

Guardian settings remain unchanged. Re-approving the same revision does not send
a second handoff, while recording a new revision requires fresh approval.

## Export an optional Markdown copy

Export is useful when the plan should also exist as a workspace document:

```text
/plan-export PLAN.md
```

Export creates a new plaintext `.md` file relative to the workspace. It does not
overwrite an existing file, create missing parent directories, approve the plan,
start implementation, commit the file, or publish it.

Review exported content before sharing it; plans can contain private project or
operational information. Exporting an approved plan does not turn the file into
portable proof of approval.

## Abandon planning without approval

```text
/plan-exit
```

This exits planning and discards the active draft without approval or a work
handoff. It keeps conversation history, historical branches, and files already
exported. Export first if you need a standalone copy.

## Resume and navigate branches

Planning mode, drafts, and approval records are saved with the session and follow
the active conversation branch. After resuming or switching branches, use:

```text
/plan-show
```

to confirm which revision and approval state are active before exporting or
approving. Continue the owning conversation through
[session resume](workspaces-and-sessions.md#resume-across-workspaces).

## Command summary

| Command | Effect |
| --- | --- |
| `/plan <goal>` | Start a fresh planning goal and discussion. |
| `/plan` | Re-enter planning without discarding the current draft. |
| `/plan-show` | Display the active saved revision and approval state. |
| `/plan-export <path.md>` | Create a new plaintext workspace copy; not approval. |
| `/plan-approve` | Confirm the exact saved revision and return to the normal workflow. |
| `/plan-exit` | Exit and discard the active draft without approval. |

For revision identity, size limits, export path rules, confirmation invalidation,
branch behavior, and failure semantics, see the
[Planning behavior reference](reference/planning.md).

[Documentation index](index.md) · [Getting started](getting-started.md) ·
[Guardian](guardian.md)
