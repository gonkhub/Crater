Update SYSTEM_PROMPT.md to reflect what the most recently merged branch added to the game.

Steps to follow — do them in order, do not skip any:

1. Read `SYSTEM_PROMPT.md` in full so you know the current state of the document.

2. Run `git log --oneline main..HEAD` (or `git log --oneline -20` if on main) to identify the commits that make up the recently merged branch.

3. Run `git diff HEAD~<N>..HEAD --stat` (where N is the number of commits in the branch) to get a high-level view of which files changed.

4. Read every `.gd` file that was modified or added by the branch. Understand what each change does and why.

5. Read any handoff `.md` files added by the branch — they contain authoritative descriptions of design intent.

6. Synthesise what changed into targeted edits to `SYSTEM_PROMPT.md`:
   - Add new systems or subsystems that didn't exist before.
   - Update existing sections where behaviour has materially changed.
   - Add new entries to the Design Invariants table if the branch introduced decisions that must not be silently undone.
   - Remove or correct anything that is now outdated.
   - Rewrite for compactness without losing details important for future understanding.

7. Do not summarise what you changed — just produce the updated file. The user can review the git diff.

Working relationship reminder: you are documenting what the user built, not redesigning it. Keep descriptions factual and concise. Do not editorialize.
