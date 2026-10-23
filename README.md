# Pi-Run

Pi-Run turns [Pi](https://pi.dev/) into a durable, containerized work environment
for software development and system administration. It combines a capable,
versioned toolchain with profiles, sessions, review, and recovery while limiting
host filesystem exposure to the workspace, profile, and narrowly defined runtime
resources.

## Why Pi-Run exists

Agents need enough freedom to investigate, edit, build, test, and learn from the
result. Asking a human to approve every harmless command creates interruption
without necessarily creating control: after enough prompts, approval can become
a reflex. Removing every checkpoint has the opposite problem—an early assumption
can travel too far before evidence or human judgment corrects it.

Pi-Run moves attention from mechanical actions to meaningful control points. The
shipped default profile asks the agent to investigate, propose one small
verifiable increment, wait for approval, implement it, validate the result, and
stop before choosing what happens next. This keeps the agent's prediction horizon
short enough for tests, diffs, observed behavior, and human decisions to answer
back.

That workflow is an opinionated default, not hard-coded Pi-Run behavior. Every
profile owns an editable `AGENTS.md` working contract. Development, maintenance,
and operations profiles can use different human gates, and teams can strengthen,
relax, or replace the supplied lifecycle. Profile and repository instructions
guide behavior; they do not enforce operating-system permissions.

Profiles also define the profile-managed identity and private context exposed to
a run. Selecting a profile mounts that profile—and only that profile—with its
provider authentication, SSH keys, Git configuration, instructions, skills,
settings, Guardian policy, and sessions. Keep profiles purpose-specific so an
administrative credential does not accompany unrelated development work. Other
profiles stay outside the container, but everything in the selected profile is
available to the run. Credentials stored in the workspace or optional shared
mount, and access offered by reachable services, are outside this boundary.

Guardian adds another layer without requiring human interaction for every covered
command. When enabled, a separate evidence-aware Pi reviewer examines acting-agent
`bash` and `run` calls against the current request and applicable instructions. It
releases supported actions; otherwise it permanently cancels the invocation and
opens a dispute. The acting agent can inspect bounded file evidence and submit a
structured position, which Guardian reassesses without granting authority or
releasing the action. The human provides the final direction. Reviewer preferences
and policy are profile-configurable; activation is session-scoped and every new
session starts Off.

Guardian is not a sandbox or an infallible security decision-maker. The temporary
container narrows filesystem exposure, but selected mounts contain real host
data and the default network backend uses host networking. Explicit offline and
restricted TCP modes can narrow session networking with exact
hosts, domains, CIDRs, or public-internet rules; they do not hide mounted
credentials or make writes disposable. Profiles, credentials, Unix
permissions, RBAC, database roles, and network controls bound authority;
instructions, Guardian, protected workflows, and human review reduce the
likelihood of a harmful action.

Pi-Run also assumes those controls can miss something. Git status and diffs make
repository changes visible, while committed history or an independent workspace
backup can recover reviewed content. Encrypted Pi-Run snapshots recover portable
state—including profiles, credentials, sessions, skills, and shared files—but do
not contain workspace source trees or remote-system data. Databases, cloud
resources, and other infrastructure need their own recovery mechanisms.

## What Pi-Run provides

- **Ready-to-use environment:** Pi, language toolchains, diagnostics, service
  clients, web access, and baseline extensions come in one matching runtime
  image.
- **Purpose-specific exposure:** only the selected profile is mounted, providing
  its instructions, provider access, credentials, settings, skills, Guardian
  policy, and conversations while leaving other profiles out of view.
- **Continuity:** stable workspace identities and saved sessions let you leave,
  resume, move a checkout, or reconnect work after recovery.
- **Parallel repository work:** persistent managed Git worktrees give concurrent
  sessions separate branches, indexes, and working files while keeping their
  host paths, shared Git authority, and lifecycle visible.
- **Layered control:** profile selection limits the identity and private context
  presented to the run; configurable instructions set the working contract;
  Guardian can review covered commands; external systems retain final authority.
- **Deliberate remote access:** use profile-specific SSH keys without mounting
  the host's complete `.ssh` folder.
- **Encrypted state recovery:** manual or optional successful-exit snapshots
  protect portable Pi-Run state and support guarded restore. They complement Git,
  workspace backups, and infrastructure recovery rather than replacing them.
- **Selectable session networking:** retain default host networking, choose an
  explicit offline container, or use restricted TCP rules for
  exact hosts, domains, CIDRs, and public-internet access.
- **Understandable boundaries:** the workspace and most selected-profile state
  are writable; network-authority configuration and managed SSH credentials are
  over-mounted read-only. The host home, other profiles, and Docker socket are
  not mounted into a normal session.

## Why Pi?

[Pi](https://github.com/earendil-works/pi) is an MIT-licensed, open-source agent
harness with support for multiple model providers and local or compatible model
endpoints. Pi-Run keeps instructions, skills, settings, sessions, and other
working knowledge in user-controlled profiles rather than binding that context
to one model choice.

Models are replaceable, not interchangeable: changing one can change behavior,
and provider or deployment choices still determine where prompts and context are
processed. Pi-Run supports model choice and portable working knowledge; it does
not by itself guarantee data sovereignty.

## Install and start

Pi-Run targets Linux/amd64 and requires Bash, Docker, `curl`, `jq`, and standard
GNU command-line tools. On x86-64 Windows, it can run in an experimental
[WSL2 configuration](docs/installation.md#windows-via-wsl2-ubuntu-or-debian)
with Ubuntu or Debian, Docker Engine inside the distribution, and Linux-side
storage. WSL1, Windows ARM64, and native Windows execution are outside this
configuration. Run `pi-run doctor` after installation to check the selected
environment. WSL-specific diagnostics have automated coverage, but the
maintainer does not currently have a Windows computer for end-to-end testing,
so this path remains experimental. Feedback is welcome through
[GitHub Issues](https://github.com/aprilsoftware/pi-run/issues).

Install the latest published public release, initialize your Pi-Run environment,
and open the current directory:

```bash
curl -fsSL https://github.com/aprilsoftware/pi-run/releases/latest/download/install.sh | sh
pi-run init
pi-run .
```

The downloaded installer contains its matching version. It verifies the
versioned application archive, pulls the matching runtime and egress images,
and installs the `pi-run` command. `pi-run init` creates the data home and
initial profile;
`pi-run .` opens the current directory as a writable workspace. For explicitly
isolated parallel repository work, `pi-run worktree start <task-name> <repository>`
creates a named persistent host-visible Git worktree. Use `.` for the current
repository. Ordinary launches remain in the selected checkout. See
[workspaces and sessions](docs/workspaces-and-sessions.md) for continuation,
inspection, and security boundaries.

Restricted assets require the
[private-release access procedure](docs/maintainers/private-release-access.md).
See [installation](docs/installation.md) for PATH troubleshooting, diagnostics,
custom locations, upgrades, and uninstalling.

Use `/login` inside Pi to connect a model. Name useful conversations and resume
the latest one later with `pi-run . -c`. The
[getting-started guide](docs/getting-started.md) walks through the complete first
run and explains writable resources before you begin.

## Design background

Start with
[Beyond Permission Prompts: Building a Workstation for AI Agents](https://medium.com/@cedric.nanni/pi-run-building-a-durable-workstation-for-ai-agents-bc47c42105eb),
which brings the ideas together in Pi-Run: short prediction horizons, explicit
authority, portable knowledge, command review, and layered recovery.

These earlier essays develop the ideas that led to it:

- [AI Coding in YOLO Mode](https://medium.com/@cedric.nanni/ai-coding-in-yolo-mode-0765d9dd0d54)
  — move human gates from routine commands to consequential development
  decisions.
- [How Far Should We Let AI Predict?](https://medium.com/@cedric.nanni/how-far-should-we-let-ai-predict-8de37715eaed)
  — keep execution close to verified evidence and shorten the prediction
  horizon.
- [Beyond YOLO Mode: Building Boundaries for Enterprise AI Agents](https://medium.com/@cedric.nanni/beyond-yolo-mode-building-boundaries-for-enterprise-ai-agents-a13a85ee447a)
  — layer behavior, knowledge, runtime review, identity, and real authority.
- [Sovereign AI: The Model Can Change. Your Knowledge Shouldn't Have To.](https://medium.com/@cedric.nanni/sovereign-ai-the-model-can-change-your-knowledge-shouldnt-have-to-24f9909a7d99)
  — preserve choice and control as models and providers evolve.

The essays explain the motivation; the documentation below describes the current
implementation and its exact boundaries.

## Documentation

- [Documentation overview and feature map](docs/index.md)
- [Getting started](docs/getting-started.md)
- [Profiles](docs/profiles.md), [skills](docs/skills.md), and
  [workspaces and sessions](docs/workspaces-and-sessions.md)
- [Planning](docs/planning.md) and [Guardian command review](docs/guardian.md)
- [SSH access](docs/ssh.md)
- [Encrypted snapshots and recovery](docs/snapshots.md)
- [Security and isolation](docs/security.md)
- [Build, test, architecture, and release maintenance](docs/maintainers/development.md)

## License

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Pi-Run source code is available under the [MIT License](LICENSE). Software
bundled into or installed by the runtime image remains subject to its own
license terms.
