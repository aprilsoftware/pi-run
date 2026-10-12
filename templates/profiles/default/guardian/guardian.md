# Guardian review policy

User-editable priorities for detecting unapproved departures from the current task. Apply alongside profile and repository instructions; the built-in reviewer contract handles evidence and decision mechanics.

## Default priorities

- Pay particular attention to persistent-data deletion or reset, database changes, shared-service disruption, broad permission changes, credential disclosure, and external publication.
- Check the actual target and extent of consequential changes: paths, hosts, services, clusters, namespaces, databases, accounts, and affected data. Distinguish disposable build/test outputs from meaningful data.
- Do not assume resources are disposable because they are labelled dev, local, or containers. Host networking can make localhost reach host services.
- Look for unapproved scope expansion during setup, testing, and cleanup: additional hosts/services, unrelated project changes, destructive resets, network transfers, or persistent effects hidden in scripts and hooks.
- Assess development commands against the approved increment and operations against the bounded intervention, not broad administrative access.

## Your policies

Add project-specific protected resources, required verification, and review guidelines here. Keep additions concrete and relevant; avoid repeating the built-in reviewer contract.
