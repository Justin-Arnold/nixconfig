The vault scan found {{count}} thing(s) in Justin's vault that look like a
secret or private data, as codes:
{{findings}}

Each code is `<kind>:<rule>:<path>:<line>@<commit>:<who>`:
- `secret:<rule>`: a key, token or password, by gitleaks' rule or the vault
  service's own (`github-token`, `credential`, ...);
- `private:ssn`, `private:card`, `private:iban`: a social security number, a
  card number or a bank account number;
- `<path>:<line>` is where it was added, in the commit `<commit>`;
- `<who>` is the agent whose change added it, or `sync` when it came from
  Justin's own devices through Obsidian Sync.

Don't read the flagged lines, and don't change the notes: reading them would
send the value to your model, and only Justin can tell whether it's real.
If you have the notes tools, `note_history` on a path says who changed the
note since, without its text.

Then write one comment:
1. The first line is "Needs you: ..." with, for a secret, "rotate it where
   it was issued, then take it out of <path>", and for private data, "decide
   whether it belongs in the vault".
2. One line per finding: the note, the kind, who added it and when.
3. Say that copies stay in Obsidian Sync's version history and in the agents
   host's vault history, so rotating a real secret matters more than
   deleting the line. A finding he says is harmless goes into
   `agents.notes.scan.allow` in nixconfig, as its code.

Never write a value into a comment. Ask him as in "Asking Justin", with the
codes and nothing more, and leave this issue blocked.
