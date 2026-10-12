# Skills

A skill gives Pi reusable guidance for a kind of work. It can package
instructions, references, scripts, and supporting files so a reviewed procedure
can be reused without pasting it into every conversation.

Pi advertises each skill by name and description, then reads its detailed
instructions when relevant. A skill supplies knowledge and tools; it does not
grant permission to run commands, use credentials, or contact remote systems.

## Choose where a skill belongs

| Kind | Use it for | Availability |
| --- | --- | --- |
| Core | Pi-Run's own launcher and profile guidance | Supplied by the runtime to every profile |
| Global | Reviewed guidance reused across profiles | Stored once and selected per profile; mounted read-only |
| Profile-local | Guidance or private knowledge owned by one profile | Stored in that writable profile and always active after restart |

The core names `pi-run` and `profile-management` are reserved. Use global skills
for shared, reviewed packages and local skills when the content belongs to one
profile or access context.

## Inspect available skills

Run in your **host terminal**:

```bash
pi-run skill list
pi-run --profile operations skill list
```

The list identifies each skill as `core`, `global`, or `profile`. `active` means
it will load for the profile's next run; `filtered` means a global skill is not
selected. Listing does not start Pi or invoke a model.

## Add a reviewed skill

Pi-Run intentionally has no `skill add` or package-download command. Inspect a
skill's complete instructions, scripts, references, assets, and dependencies,
then copy the whole package directory into one of these locations:

```text
Global:        ~/Pi-Run/skills/workspace-review/
Profile-local: ~/Pi-Run/profiles/default/skills/workspace-review/
```

Use the actual data home from `pi-run home` and the intended profile. Do not
merge with an existing package accidentally. Keep unfinished packages outside an
active `skills/` directory.

After copying, validate selection and start a new Pi-Run container:

```bash
pi-run --profile default skill list
pi-run --profile default .
```

Skill discovery and global mounts are fixed at launch. Adding a package does not
change an already-running session.

## Write a minimal skill

Create `workspace-review/SKILL.md` with matching frontmatter:

```markdown
---
name: workspace-review
description: Explain code, scripts, and operational notes before changes are proposed.
---

# Workspace review

Inspect the applicable instructions and documentation first.
Summarize the purpose, prerequisites, and unresolved questions.
```

`SKILL.md` must begin with non-empty, single-line `name` and `description`
fields. The declared name must match the package directory. State when the skill
is useful, not only what it contains, and use relative paths for supporting
files.

## Filter global skills

The selected profile's `skills` field controls global skills:

| Value | Effect |
| --- | --- |
| `null`, or absent | Load every installed global skill. |
| `[]` | Load none. |
| `["name"]` | Load only the named installed skills. |

For example, merge this field into the existing `profile.json`:

```json
{
  "skills": ["workspace-review"]
}
```

Do not add core or profile-local names to this list. Profile-local skills remain
active. Creating a profile resets this filter to `null`; review
[what is copied](profiles.md#what-is-copied) before first launch.

## Validation and trust

Pi-Run validates package names, frontmatter, structure, file types, and size. It
rejects symbolic links, hard links, special files, and filesystem crossings
rather than following them. A malformed active package can stop listing or
launch, so keep drafts outside managed skill roots.

Validation does **not** establish that instructions or scripts are trustworthy.
A read-only global mount protects package files from modification, but the
package can still influence commands, writable files, and reachable services.
Review all content before making a skill available and keep credentials out of
shareable packages.

For exact naming rules, package limits, validation timing, duplicate handling,
and profile-selection semantics, see the
[Profiles and Skills reference](reference/profiles-and-skills.md).

[Documentation index](index.md) · [Profiles](profiles.md) ·
[Security](security.md)
