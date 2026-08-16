---
title: 
state: not-started        # not-started | started | done | dropped
horizon: inbox            # inbox | now | next | later | someday   (optional)
area:                     # software | business | personal | content   (optional)
projects: []              # optional, multi-valued (soft overlap)
domains: []                # optional, multi-valued (can span projects)
depends_on: []             # optional hard constraint (a guardrail, NOT a ranking)
                            # quoted wikilinks to existing notes, e.g. ["[[Other idea title]]"]
created: 
---

<!--
Body: as little as one sentence, or pages + diagrams. Proportional weight.
- Add a `- [ ]` checklist only when there are concrete next steps.
- Connect is required: search the corpus, link related notes [[both ways]], and add
  shared domains - or state explicitly that no genuine relation was found.
- No numeric priority - ever. "What's next" is computed by /next from live context.
-->

<!--
## Decisions
Add this section, dated, when state moves to done or dropped:
- YYYY-MM-DD: what was decided and why. Alternatives considered: what else, why it lost.
-->
