# Further sharing between the spec review's batch and ticket parsers

This project shares three pieces of the spec-review module's batch side
and ticket side: the `@@` line split (`spec_review_at_line`), the `@@`
block reader (#2568), and the Other-list token walk
(`spec_review_answer_tokens`). Both sides use each of them the same way;
only the batch side has a `@@ quote` block for the reader. Two further
extractions were weighed and declined.

## Why these are out of scope

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

Reconsider if a third kind of batch appears and needs these parsers or answers.

## Prior requests

- #1121: "the two parsers repeat the `@@` header split, the block-buffer
  append and the anchor/replace handling" - filed by the review loop as a
  Standards-axis major against PR #1120. The header split was extracted in
  #1264; the block-buffer append and the anchor/replace handling were
  declined then, and taken in #2568.
- #1124: "the two answer functions repeat the Other-list tokenizer and the
  twice-named check" - filed as a Standards-axis major against PR #1120. The
  token walk was extracted, and the `named` string dropped, in #1264; the
  item lookup was declined.
- #1128: "`spec_review_reasons` takes eight positional arguments, a batch
  kind passed as loose strings by its two callers" - filed as a
  Standards-axis major against PR #1120 and declined in #1264.
- #2568: "a shared @@ anchor / replace / end block reader for both
  spec-review parsers" - filed by a code audit (finding #51). Taken: the
  reader reports a malformed block's line and message to each side's own
  die function rather than taking it as a callback, and owns the block
  buffer, so the append is no longer repeated. #2547 had just found the
  same CRLF defect in both copies.
