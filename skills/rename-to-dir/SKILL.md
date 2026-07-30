---
name: rename-to-dir
description: Renames the current Claude session to the basename of the current working directory. Use when the user invokes /rename-to-dir or asks to "rename session to current folder/directory".
---

Rename this session to the current working directory's folder name.

## Steps

1. Get the current directory name:
   ```bash
   basename "$PWD"
   ```

2. Invoke the built-in `/rename` slash command with that name as the argument using the Skill tool.

3. Confirm the rename to the user in one short line.
