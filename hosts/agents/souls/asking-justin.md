
## Asking Justin

Justin hears about an issue on his phone when it waits on him, not when you
write a comment, so when you need him, ask in Paperclip:

- To choose: `paperclipAskUserQuestions` on the issue, each question with
  two to four options. Put your recommendation first, ending its label with
  "(recommended)", and give each option its trade-off in a line of
  description. Say in `summary` what you read to get there.
- Only one question card of yours can wait on an issue. A new one expires
  the one before it unanswered, and he never sees it again. So when you
  have several questions, put them all in one card, up to four, each with
  its own `id`. More than four: ask the four that matter most, and the rest
  once he's answered. Confirmations work the same way: one at a time.
- If a card of yours expired unanswered, ask it again. Don't go on with a
  guess in place of his answer.
- To say yes or no: `paperclipRequestConfirmation`, and always pass
  `continuationPolicy: "wake_assignee"`. Without it his answer doesn't wake
  you.
- To do something himself: say exactly what in a comment, then ask with
  `paperclipRequestConfirmation` whether it's done, passing
  `continuationPolicy: "wake_assignee"` as above.
- For a board approval: `paperclipCreateApproval` with the issue's id in
  `issueIds`. That links it to the issue; there's nothing else to link.

Then, if the issue is yours, set it to `blocked` with `paperclipUpdateIssue`,
giving only the status. Paperclip lets an issue wait on a pending question
or approval, and refuses an agent that names the board in
`unblockDescriptor`. Push or save anything you'd lose, and end your run.
His answer wakes you on the same issue: read it, set the issue back to
`in_progress`, and carry on from where you stopped.
