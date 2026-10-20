# Further sharing between the spec review's batch and ticket parsers

This project shares only two pieces of the spec-review module's batch side
and ticket side: the `@@` line split (`spec_review_at_line`) and the
Other-list token walk (`spec_review_answer_tokens`). Both sides use each of
them the same way. Four further extractions were weighed and declined.

## Why these are out of scope

- **The block-buffer append.** `spec_review_batch_parse` and
  `spec_review_tickets_parse` each add a line to the open block's buffer in
  one line. A helper would replace that one line with one call, which
  coding-standards section 1 rules out.
- **A shared `@@` block reader.** The anchor, replace and quote handling looks
  alike in the two parsers, but it reacts differently. Each side has its own
  die function and stores a finished block in its own place: an item's or
  option's `SR_` arrays, or the `ST_` arrays. Only
  the batch has a quote mode, and the two return to different modes. A shared
  reader would need the die function passed in as a callback for those
  reactions, which section 1 warns against.
- **A shared item lookup with its repeat check.** `spec_review_answer` and
  `spec_review_tickets_answer` each find a token's item and refuse an unknown
  one. To word its messages, a shared lookup would need each side's noun
  (item or ticket item), source (`batch.md` or `tickets.md`) and answer name
  passed in. That is the mode argument section 1 warns against.
- **A batch-kind prefix or table for `spec_review_reasons`.** It takes eight
  positional arguments, and its two callers each pass one fixed set. A kind
  prefix and a lookup table would add indirection to rule out a mismatch
  between those arguments, and with only two call sites a mismatch is
  unlikely.

Reconsider if a third kind of batch appears and needs these parsers or
answers, or if a parser's block handling comes to react the same way on
both sides.

## Prior requests

- #1121: "the two parsers repeat the `@@` header split, the block-buffer
  append and the anchor/replace handling" - filed by the review loop as a
  Standards-axis major against PR #1120. The header split was extracted in
  #1264; the rest was declined.
- #1124: "the two answer functions repeat the Other-list tokenizer and the
  twice-named check" - filed as a Standards-axis major against PR #1120. The
  token walk was extracted, and the `named` string dropped, in #1264; the
  item lookup was declined.
- #1128: "`spec_review_reasons` takes eight positional arguments, a batch
  kind passed as loose strings by its two callers" - filed as a
  Standards-axis major against PR #1120 and declined in #1264.
