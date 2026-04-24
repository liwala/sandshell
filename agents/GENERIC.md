# Generic adapter

Use these instructions through the agent's own project-instruction, system
prompt, or repo-guidance mechanism.

- Prefer the agent's strongest built-in sandbox, approval, or workspace-scoping
  controls
- Keep the agent inside the current repo unless the user explicitly approves
  broader access
- If the agent has no native enforcement surface, treat sandshell as advisory
  policy and surface trust-boundary changes to the user explicitly
