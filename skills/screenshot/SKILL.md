---
name: screenshot
description: Attaches the most recent screenshot from ~/Desktop/Screenshots/ into the conversation by reading it inline. Use whenever the user invokes /screenshot, says "use my latest screenshot", "attach my screenshot", "grab the screenshot I just took", or similar. Also use proactively when the user mentions a screenshot and hasn't attached one yet.
---

Attach the most recent screenshot from the user's Screenshots folder to this conversation.

## Steps

1. Find the most recent screenshot:
   ```bash
   ls -t ~/Desktop/Screenshots/*.png 2>/dev/null | head -1
   ```

2. Read the file with the Read tool — Claude Code renders images inline, making it visible in the conversation.

3. Tell the user which screenshot you attached (just the filename is enough — they can see it).

## Notes

- If the folder is empty or doesn't exist, say so and ask the user to point you at the right path.
- Don't add commentary about what you see in the screenshot unless the user asks — just attach it and confirm.
