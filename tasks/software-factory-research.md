# Software factory approaches and Pi-Run applicability

## Status and purpose

This document records external research used to assess possible v0.11 software factory architectures. It compares patterns, tradeoffs, and Pi-Run readiness. It is research evidence, not an approved implementation plan, backlog authority, or permission to create tasks, run agents, change repositories, contact providers, push branches, open pull requests, merge, deploy, or publish.

The current bounded factory direction remains documented separately in [software-factory-design.md](software-factory-design.md). Future planning may use this research, but product decisions require explicit review and approval.

## Research conclusion

“Software factory” currently describes three overlapping product families:

1. **Platform factory:** standardized templates, environments, CI/CD, policy, security checks, service catalogs, and golden paths.
2. **Agentic task factory:** an issue or specification becomes a tested branch or pull request through a controlled coding-agent workflow.
3. **Autonomous factory:** software continuously discovers, prioritizes, implements, reviews, deploys, measures, and improves work.

Pi-Run is already well positioned for the second family and provides useful parts of the first. The third requires durable unattended scheduling, safe write brokers, broader orchestration, production feedback, and substantially more governance than a `/loop` command.

The most appropriate initial v0.11 target is a **bounded local factory**:

```text
approved task
    → managed worktree and prepared runtime
    → implementation and deterministic verification
    → fresh-context review
    → validated local result
    → human decision about commit, push, PR, merge, or publication
```

## Approach 1: single-agent iterative loop

Ralph-style loops and long-running Codex sessions use a repeated cycle:

```text
goal/spec → inspect → implement → test → repair → update status → repeat
```

OpenAI's long-horizon account emphasizes durable specification and status files, milestone acceptance criteria, continuous verification, repository state, and worktree isolation. Ralph-style practice intentionally favors one process doing one task per iteration rather than beginning with multi-agent coordination.

### Strengths

- Simple orchestration and few concurrency problems.
- Easy to observe and reproduce.
- Works with current coding models and ordinary development tools.
- Maps directly to Pi sessions and managed worktrees.

### Risks

- Long contexts drift or repeat mistakes.
- Self-review shares implementation bias.
- Vague goals can consume substantial time and tokens.
- External waiting requires polling or events.

### Pi-Run readiness: high

Pi-Run already provides the session, worktree, runtime, tool, network, Guardian, and transcript boundaries. Missing pieces are bounded loop scheduling, run state, limits, deterministic evidence, no-progress handling, and fresh review.

## Approach 2: specification-driven staged factory

GitHub Spec Kit represents a staged process:

```text
constitution → specification → clarification → plan → tasks
             → implementation → convergence
```

The specification and intermediate artifacts remain durable and reviewable instead of disappearing into chat history. The model implements against explicit requirements and repeatedly checks convergence.

### Strengths

- Strong traceability and human review points.
- Good fit for complex or regulated work.
- Reduces goal drift and supports fresh agent contexts.
- Produces durable definitions of scope and completion.

### Risks

- Can become document-heavy.
- Incorrect specifications produce incorrect implementations consistently.
- Small fixes may not justify every stage.
- Specifications can become stale or contradict behavior.

### Pi-Run readiness: high

Plan, `plan_read`, task hashing, repository instructions, and documentation are a strong foundation. A factory task still needs stricter identity, acceptance, effect, validation, budget, and terminal-state fields. A saved Plan may provide context but must not become whole-plan execution authority.

## Approach 3: issue-to-pull-request worker

GitHub Copilot coding agent and similar asynchronous systems use:

```text
assigned issue → isolated environment → branch/PR → plan/checklist
               → implementation → tests → review feedback → revisions
```

The issue is intake and context. The pull request becomes the collaboration, review, CI, and handoff surface.

### Strengths

- Familiar developer workflow and strong visibility.
- Natural asynchronous operation.
- CI provides deterministic external feedback.
- Humans can intervene through review comments.

### Risks

- Issues and review comments are untrusted and may contain prompt injection.
- Push and PR creation are consequential external effects.
- Requires network access and GitHub credentials.
- Repeated CI remediation can become an uncontrolled loop.
- A pull request is not a security or correctness boundary.

### Pi-Run readiness: medium-high

Managed worktrees, Git/SSH, sessions, and restricted networking support local execution. Missing capabilities include safe issue import, durable PR identity, CI/review event ingestion, explicit external-write authority, and a narrow push/PR output mechanism. A local reviewable branch remains the safer initial output.

## Approach 4: event-driven agentic workflows

GitHub Agentic Workflows and Claude scheduled tasks separate triggers from agent reasoning:

```text
schedule | API call | repository event
    → bounded agent workflow
    → declared reviewable or safe output
```

GitHub workflows use Markdown instructions plus frontmatter for triggers, permissions, tools, and safe outputs. Access is read-only by default, and write operations are limited to declared output types. Claude scheduled tasks package a prompt, repositories, connectors, and schedule/API/GitHub triggers in a durable cloud or self-hosted task.

### Strengths

- Better than polling when real events exist.
- Suitable for triage, CI investigation, documentation, and review.
- Trigger, permissions, and output can be declared independently.
- Can run without an open developer terminal.

### Risks

- Requires a durable service or cloud runner.
- Webhooks and retries introduce duplicate and out-of-order delivery.
- Event payloads are untrusted.
- Durable credentials and secret brokerage become necessary.

### Pi-Run readiness: medium locally, low for unattended operation

A session `/loop` can support local waiting. Pi-Run does not yet provide a daemon, webhook receiver, durable queue, cloud scheduler, or idempotent event processor. The architecture should still distinguish a wake-up from authority: an event may make an approved run eligible to continue but cannot approve new work.

## Approach 5: role-based multi-agent workflow

MetaGPT models a software organization through product-manager, architect, project-manager, engineer, and related roles coordinated by standard operating procedures.

### Strengths

- Focused responsibilities and explicit handoff artifacts.
- Fresh contexts reduce some implementation bias.
- Different models can be selected for different tasks.

### Risks

- Role simulation can add ceremony without quality.
- Handoffs lose context and raise cost.
- Agents can disagree, recurse, or generate unnecessary work.
- Multiple agents do not guarantee independent verification.

### Pi-Run readiness: medium

Primary, Guardian, CAF reviewer, and CAF friend have security and workflow roles; they should not be repurposed into a simulated development team. Pi-Run can instead run Primary instances sequentially: implementation, fresh review, and bounded remediation. This preserves the established four-agent architecture within each process.

## Approach 6: planner-worker-judge parallel factory

Cursor's large autonomous experiments evolved from flat peer coordination to a planner-worker-judge structure. Flat agents sharing a task file and locks became brittle: locks leaked, coordination bottlenecked, and agents avoided difficult end-to-end work. Separating planners, focused workers, and a cycle judge scaled better, though Cursor still reports drift, overlong runs, and the need for fresh starts.

### Strengths

- Can reduce elapsed time on large decomposable projects.
- Explicit roles improve responsibility and focus.
- Fresh cycles reduce tunnel vision.

### Risks

- Requires leases, retries, deduplication, conflict handling, and integration.
- Shared branches or coordination files create races.
- A judge becomes a powerful authority point.
- Cost, observability, and reproducibility become difficult.

### Pi-Run readiness: low for initial v0.11

Managed worktrees provide a strong future isolation primitive, but Pi-Run lacks planner queues, worker leases, concurrency budgets, cross-process coordination, result integration, and judge semantics. The state model should permit later parallel runs without implementing them now.

## Approach 7: golden-path and platform factory

Traditional software factories emphasize standardized delivery rather than autonomous coding. Backstage Software Templates generate components from organization-owned skeletons and publish them through repeatable steps. DevSecOps factories combine templates, CI/CD, scanners, governance, audit logs, observability, and deployment conventions.

### Strengths

- Makes repositories predictable for humans and agents.
- Encodes organizational rules mechanically.
- Improves setup, reproducibility, and compliance.
- Often provides more leverage than additional agents.

### Risks

- Templates and golden paths can become rigid or stale.
- Requires ongoing organizational maintenance.
- Does not resolve ambiguous product requirements by itself.

### Pi-Run readiness: high as a complementary layer

Profiles, runtime Dockerfiles, skills, `AGENTS.md`, managed worktrees, Plan, network modes, Doctor, and release tests already provide golden-path elements. Repository readiness should become an explicit factory assessment without modifying or approving the repository automatically.

## Cross-cutting findings

### The harness matters more than one large prompt

SWE-agent's Agent–Computer Interface research found that bounded file views, concise search, immediate lint feedback, and explicit empty-output messages materially improve agent behavior. OpenAI similarly emphasizes structured repository knowledge, executable constraints, tools, logs, and feedback loops. Pi-Run should improve the environment and evidence model rather than construct a single universal factory prompt.

### Durable external state limits drift

Long-running systems repeatedly externalize specifications, milestones, status, decisions, tests, results, known issues, and run logs. A transcript alone is insufficient. Host-owned factory state remains appropriate, with a bounded model-readable projection for the active phase.

### Events are preferable to unnecessary polling

`/loop` is useful when no event API exists or a session must periodically inspect CI, a build, or review. Process completion, CI events, review events, and human resume are better triggers when available. A later wake-up abstraction should support several trigger types without letting a trigger create authority.

### Typed safe outputs reduce credential exposure

GitHub Agentic Workflows separate broad agent reasoning from narrow permitted writes such as creating an issue, comment, or pull request. A future Pi-Run output broker could validate task/run/approval identity and perform one typed host operation instead of giving the agent unrestricted `gh`, push, merge, or publication credentials.

### Flat multi-agent coordination is a poor starting point

Research and field reports favor one approved task, one acting agent, deterministic checks, fresh review, and human escalation before adding planner/worker swarms. Shared writable coordination files and peer-selected tasks create races, leaked locks, duplication, and progress without responsibility.

### Outcomes matter more than activity

Useful factory metrics include accepted, blocked, failed, and completed tasks; validation and review rates; remediation cycles; elapsed time; human interventions; escaped defects; and cost per accepted result. Tokens, lines, PRs, and turns alone can reward churn.

## Pi-Run capability assessment

### Strongly supported now

- Local single-agent and specification-driven work.
- Managed-worktree and prepared-runtime isolation.
- Human approval boundaries and persistent conversations.
- Deterministic local validation, command review, and restricted networking.
- Local reviewable results.

### Requires v0.11 implementation

- Host-owned task/run state and exact task approval lifecycle.
- Bounded `/loop` and run state machine.
- Validation evidence records and fresh review sessions.
- Factory visibility, recovery, limits, and no-progress handling.

### Design now, implement later

- Generic event/wake-up sources.
- Typed safe-output broker.
- GitHub issue/PR linkage.
- Repository readiness assessment.
- Provider/model and cost policy.
- Draft pull-request creation.

### Outside initial v0.11

- Flat swarms and planner-worker concurrency.
- Unattended daemon or cloud routines.
- Automatic backlog consumption.
- Automatic merge, release, deploy, production repair, or self-evolution.

## Factory maturity levels

- **Level 0 — Assisted workstation:** a human starts and directs each session.
- **Level 1 — Bounded local factory:** approved task → worktree → implementation → verification → fresh review → local result. This is the initial v0.11 target.
- **Level 2 — Asynchronous task worker:** approved task → durable runner → draft PR → review feedback.
- **Level 3 — Event-driven maintenance factory:** event → task draft → approval → execution → typed safe output.
- **Level 4 — Parallel factory:** planner → isolated workers → judge/integration → review.
- **Level 5 — Continuous autonomous product operation:** signals → prioritization → implementation → deployment → measurement → adaptation.

The architecture should leave Levels 2–4 possible without claiming that v0.11 already supplies them. Level 5 remains outside the current product direction.

## Recommended future plan and design updates

Later planning should consider adding:

1. **Factory levels:** identify initial v0.11 explicitly as Level 1.
2. **Trigger/wake-up abstraction:** `/loop` is one trigger, not the controller.
3. **Safe-output broker:** future external writes become typed host operations.
4. **Repository readiness assessment:** instructions, validation, worktrees, secrets, external effects, generated files, and recovery.
5. **Attempt evidence manifest:** immutable task/run identity, validation, review, usage, and terminal outcome.

The existing choices remain supported: local reviewable worktree as first output, host-owned non-mounted authority state, exact task-hash approval, one acting agent plus fresh review context, and no automatic commit, push, PR, merge, release, deployment, or next-task selection.

## Sources

- [OpenAI: Harness engineering](https://openai.com/index/harness-engineering/)
- [OpenAI: Run long-horizon tasks with Codex](https://developers.openai.com/blog/run-long-horizon-tasks-with-codex)
- [OpenAI Agents API architecture](https://developers.openai.com/api/docs/guides/agents-api/architecture)
- [OpenAI sandbox security](https://developers.openai.com/api/docs/guides/agents-api/environments/security)
- [Claude Code: Run prompts on a schedule](https://code.claude.com/docs/en/scheduled-tasks)
- [Claude Code: Scheduled tasks](https://code.claude.com/docs/en/routines)
- [GitHub Agentic Workflows](https://docs.github.com/en/copilot/concepts/agent-capabilities/agent-powered-workflows-and-operations/about-github-agentic-workflows)
- [GitHub coding agent issue-to-PR workflow](https://github.blog/ai-and-ml/github-copilot/assigning-and-completing-issues-with-coding-agent-in-github-copilot/)
- [GitHub Spec Kit](https://github.com/github/spec-kit)
- [SWE-agent Agent–Computer Interface](https://github.com/SWE-agent/SWE-agent/blob/main/docs/background/aci.md)
- [Cursor: Scaling long-running autonomous coding](https://cursor.com/blog/scaling-agents)
- [MetaGPT](https://github.com/geekan/MetaGPT)
- [Backstage Software Templates](https://backstage.io/docs/features/software-templates/)
- [Anthropic: Securing an AI-native SDLC](https://claude.com/resources/articles/how-anthropic-secures-its-ai-native-software-development-lifecycle)
- [Factory: Software Factory](https://factory.ai/product/software-factory)
- [Geoffrey Huntley: Everything is a Ralph loop](https://ghuntley.com/loop/)
