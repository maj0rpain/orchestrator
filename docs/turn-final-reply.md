# Turn-final reply

The one home of the procedure for asking a human a long-block question, and of
the rule for a printout that asks nothing. Each site that asks a turn-final
question, or prints an unattended printout, names this doc and keeps only what
is specific to it: its answer words, its restatement example and its
question-path verb.

## Turn-final reply

End the turn on one plain-text reply with no tool call in it, holding the long
block and then the question with its answer words spelled out. The human's next
message is the answer. Never ask it with the ask-the-user capability (per
`docs/host-capabilities.md`: `AskUserQuestion` on Claude Code, `ask_user` on
Junie), and never write the block in a response that also calls a tool: some
hosts hide a long text written beside a tool call, and the human never sees it
(ADR-0051).

An answer word and its option's full label are the same answer, both matched
after trimming surrounding whitespace, letter case and trailing punctuation:
`Accept.` is `accept`.

## Near-miss reply

A reply matching none of the site's answer forms - a typo, extra words around an
answer word, mixed forms - is never guessed at and never re-shown. State in one
line what you would do, in the site's answer format, then ask a short
confirmation with the ask-the-user capability (`AskUserQuestion` on Claude Code,
`ask_user` on Junie), nothing long in front of it: *Yes, apply that* / *No, I'll
answer again*. *Yes, apply that* does exactly what the line states. Any other
reply to the confirmation (*No*, free text, a dismissed ask) counts as *No*.
Nothing is ever applied on a guess.

## Question path

On *No*, or on a reply that is clearly a question, answer it in chat and apply
nothing, then end the turn again on the block and its question, in one
turn-final reply.

## Unattended printout

A block printed only so a human watching can see it, with no question after it,
is not a turn-final reply. A reply with no tool call ends the turn, so never end
the turn on it: go on in the same turn.
