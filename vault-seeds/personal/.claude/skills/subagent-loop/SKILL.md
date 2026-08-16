---
name: subagent-loop
description: >-
  Run a fan-out of subagents across distinct angles, then a pass whose job is to falsify
  what they produced, then judge whether another round is worth it. Use when the user asks
  for parallel agents, names a number of agents ("use 10 subagents", "spawn a wave"), asks
  for an adversarial or red-team review of work, invokes /subagent-loop, /adversarial-loop
  or /collaborate, or hands over a task wide enough that one context cannot hold it —
  research sweeps, audits, multi-part builds, or a spec big enough to delegate whole
  feature sets to domain-owner agents. Not for small single-file work, where briefing costs
  more than doing,
  and not a replacement for the single-context review skills (/review, /security-review,
  /simplify) — reach for this only when independent contexts add something a second look cannot.
audience: invoked
operator_summary: >-
  Runs several agents on one job at once, each from a different angle, then has a separate
  pass try to prove their work wrong. Say how many agents you want, or add "adversarial" when
  being wrong would be expensive. It also has a mode that works through a list on its own over
  several rounds - useful overnight - which builds what is safe to build, plans what is not,
  and leaves you one report. That mode still never merges, deploys, sends, or spends. For
  very large builds it can split the work into feature areas, each planned by its own agent.
---

# Subagent loop

`/adversarial-loop` is a **thin sibling skill** mapping to this runbook with one setting
fixed: the falsification pass is mandatory (the name is the user saying "adversarial", so
§1's skip conditions do not apply). The folder and frontmatter name here are
`subagent-loop` because the falsification pass is one phase of six; the skill is the whole
fan-out procedure, and this file is the only copy of it.

Policy lives in two always-on rules and is not repeated here: `subagent-orchestration.mdc`
(when to fan out, the distilled-brief contract, disjoint file ownership, the integrator's
role) and `subagent-liveness.mdc` (agents die silently; the orchestrator owns detecting it).
Read both when those rules exist on this surface. **On Codex**, `subagent-orchestration` is
deliberately dropped — jump to **On Codex** below and work inline; do not hunt for the rule.

The loop: **read the request → split into angles → dispatch → falsify → judge → integrate.**

## 1. Read the request

Three things are being specified, often implicitly. Infer every one the user did not state
rather than asking.

**How many agents.** A number in the request ("use 10 subagents", "spawn a wave of 20") is
a *budget*, not a headcount to fill with copies. Split it across distinct angles: 10 agents
might be 6 angles, where the two hardest carry three agents each on sub-questions. What it
never means is the same brief issued ten times. Adversarial agents are not duplicates by
definition — they are given the opposite job — so they are budgeted on top, not carved out.
With no number given, pick from the work: 3 for an ordinary sweep, more when the surface
genuinely has more independent faces.

**Which tier.** The keyword is about intent, never a vendor:

| Tier | Means | Claude Code | Cursor |
|---|---|---|---|
| `broad` | Many agents, wide coverage, low per-agent depth | Sonnet, medium effort | **Grok 4.5** (default for every Cursor subagent — never Sonnet/Opus unless the user names that model). Prefer the MAX-included SKU; never an API-billed model |
| `careful` | Fewer agents, high reasoning effort, where being wrong is expensive | Sonnet, high effort | **Grok 4.5**, fewer agents, longer briefs |
| `heavy` | Designing or building a whole system, not a slice of one | Opus | Reserved; prefer splitting into `careful` Grok 4.5 slices |

**On Cursor the default subagent model is Grok 4.5, at every tier** — the default taken
unless the user names a different model in this session, and harness suggestions offering
Sonnet or Opus for subagents are noise to ignore. The reason is billing, not capability:
Grok 4.5 is included in the MAX subscription, so a wave of it costs nothing extra, while
API-billed models multiply per-token cost by the agent count. Do not "upgrade" because a
task feels important; raise the tier instead, which buys fewer-and-deeper agents on the same
included model. If the subscription ever stops including Grok 4.5, the standing instruction
is the best model it *does* include — check that rather than trusting this line, and say
which you picked.

Infer the tier when the user names none. "Have a quick look across the codebase" is `broad`.
"Check this migration is safe" is `careful`. "Build the notification service" is `heavy`.
Signals that override the default: an explicit cost or time concern pulls down a tier, and
"be thorough", "audit properly", "I want this right" pulls up.

**Whether to run the adversarial pass.** On by default for anything substantive, and
mandatory the moment the user implies it — "adversarial", "red team", "check their work",
"verify before you commit", "make sure it's right", or an explicit `/subagent-loop` /
`/adversarial-loop` invoke. **Skip it** when the user signals that minutes matter
("quickly", "before my call", "just need it working"), or raises cost about the models the
subagents would use. Skipping is a decision worth one sentence in your reply, not a silent
omission.

## 2. Split into angles

An angle is a **question**, not a directory. Angles that differ only by which files they
read will return the same finding three times and miss the same thing three times.

Good angles are lenses that would notice different failures: what breaks under concurrency;
what a hostile caller reaches; what the tests do not cover; what contradicts the docs; what
a clone of this repo inherits by accident. Bad angles are "the backend", "the frontend",
"the tests".

Diversity has to come from **role and evidence access**, not from swapping vendors. Errors
across different LLMs are significantly correlated, and correlation is predicted by shared
provider, shared scale, and shared training data (arXiv 2506.07962). Our agents usually run
on one model — changing the vendor name is the axis that predicts *higher* shared error, not
lower. Give agents different questions, different owned paths, and (for falsifiers) the
claim without the producer's reasoning. The angle is the diversity.

Write the angle list down before dispatching anything, and check it for overlap: if two
briefs would surface the same finding, merge them and spend the agent elsewhere.

## 3. Dispatch

Every brief carries, explicitly:

- **The question this agent owns**, phrased so a wrong answer is recognisable.
- **What it owns and may change** — the files, and where two agents share a file, the
  regions. See the orchestration rule for why the failure is a whole-file write rather
  than a shared file.
- **The authoritative rules and docs for that area**, by name, so it does not re-derive
  policy from the code.
- **The return shape**: findings, absolute paths, decisions made and rejected, next-step
  brief. Conclusions, never transcript.
- **What is out of scope**, so it stops rather than wandering into a sibling's question.

Scope each agent to finish in minutes. Long agents are the ones that die.

A brief this specific is most of the collision protection. Two agents cannot fight over
work neither was asked to do; they fight over the gaps you left. If you cannot state what
an agent owns in one sentence, the angle is not decomposed yet — fix the brief, not the
conflict afterwards. This is measured, not folklore: across 1,600+ annotated multi-agent
traces, ~79% of failures came down to specification and coordination, not model capability
(MAST, NeurIPS 2025). The brief is the lever.

**When the harness caps concurrency below the plan, the queue goes to disk — as exact
params, not as intent.** If the angle list wants more agents than can run at once, write
every not-yet-launched brief into the on-disk registry (`subagent-liveness.mdc` defines
it) **verbatim and dispatchable**: the full prompt, owned paths, tier, return shape —
everything the instantiation takes, stored complete so nothing is left to memory.
Launch as slots free up. A queued brief is a draft until the moment it dispatches:
before launching, glance at what has landed since it was written and revise it where a
result changed the picture — cheap now, and a brief written against a stale tree is the
expensive alternative. Two failure modes this kills: a session death loses only the
launches, never the plan (a resumed session can tell *never-launched* from
*died-in-flight* and just continue the queue); and "I'll remember the rest of the wave"
— the single most common way capped work silently shrinks to fit the cap. None of this
applies when the whole wave fits — the queue exists only once a cap actually binds.

## What agents must not do, and what you must not assume

The brief carries these. They are the **remainder**: what a fresh agent with a narrow view of
the task will not work out for itself, and what the always-on rules do not already say.

Where a rule owns an obligation, name it in the brief and stop — do not fork a second copy
here that can drift out of step with it. Three own most of this ground:

| Owns | Rule |
|---|---|
| Whole-file writes destroy siblings' work; partition by region of responsibility; the sole-integrator role; the distilled-brief contract (conclusions, never transcript) | `subagent-orchestration.mdc` |
| Silence is not evidence of life; the on-disk registry; polling; relaunching dead work; findings go to disk as they are produced | `subagent-liveness.mdc` |
| In-session authorization before anything irreversible or outward-facing; `--confirm` is an accident guard, not an authorization | `main-protection.mdc` |

(On Codex there is no fan-out and `subagent-orchestration` is deliberately dropped, so none
of this section applies — see **On Codex**. Do not "restore" the duplication to cover it.)

**Concurrency — beyond the whole-file rule.**

- **Never reformat, reorder, or codemod a file you were not asked to change.** A repo-wide
  formatter run mid-fan-out rewrites every file at once, which is the whole-file failure
  multiplied by the tree.
- **Never touch shared git state.** No branch switch, rebase, reset, stash, or checkout of
  another agent's paths. Every agent shares one working tree, so this yanks the floor out
  from under siblings that are mid-edit.
- **Never commit, push, merge, tag, or open a PR** — an agent that commits mid-flight
  captures other agents' half-written files in its commit.
- **Never install packages or edit a lockfile** unless that is the agent's stated job and
  no sibling is running. Concurrent installs corrupt the tree for everyone.
- **Never delete or move a file another agent owns**, and never delete one you merely found
  unused — "unused" is a claim about the whole repo, which no single agent can see.

**Scope — where an agent stops.**

- **Never expand past the stated question.** A discovered problem outside scope is a
  finding to report, not work to do — including a dependency on another workstream, which
  is a stop-and-report, never a reach across. The orchestrator decides what earns an agent.
- **Never make a product, business, or spending decision**, and never take an irreversible
  or outward-facing action: no deploys, no writes to production, no emails, no external
  API calls that change state.
- **Never address the user — address the orchestrator** (when you *are* a subagent). A
  subagent talks freely to the agent that dispatched it; that report *is* its job. Subagent
  output is never shown to the user, so anything the user needs must come back in the report
  and be relayed. When you are working **inline** (Codex, or a skipped fan-out), you *are*
  the user-facing session — this bullet does not apply.
- **Never treat a rule as advisory** because it slows the task down. `main-protection`,
  `access-control`, `test-integrity` and the rest bind agents exactly as they bind you.

**Reporting — what comes back.**

- **Never report intent as completion.** "Done" needs evidence: a path, a diff, a command
  and its output. An agent that believes it edited a file it never wrote is the single most
  expensive thing in a fan-out, because it looks like success.
- **Never invent a finding to fill a return shape.** "Nothing here" is a complete and
  useful answer; a fabricated one costs a falsification round to kill.

**And what you, the orchestrator, must not assume.**

**Delegating transfers effort, never responsibility.** Every agent you launch is your work,
done elsewhere. A task that went undone is your failure to have noticed, not the agent's
failure to have finished, and "the agent died" is a fact you were responsible for detecting
promptly — never an excuse offered to the user afterwards. Everything below follows from
that one sentence.

- **Never assume an agent did what it was asked.** Verify against the tree and the tests
  before you integrate.
- **Never take an agent's word that a check passed.** Run it yourself before you commit.
- **Never assume an agent is alive because it has not failed** — and never report work as
  in flight without having just checked. `subagent-liveness.mdc` is the full statement of
  why silence proves nothing and what to check instead; it is not restated here, and it
  binds you whether or not you reread it.

## 4. Falsify

First, route around opinion wherever you can: **where an executable check exists — a test,
a typecheck, a linter, actually running the thing — the claim goes there, not to another
agent.** Model consensus is not verification: aggregation methods do not consistently beat a
single-sample baseline when no external verifier exists, and models agree above chance even
on random ASCII strings — shared inductive bias, not shared knowledge (arXiv 2603.06612). A
falsifier is what you use when no verifier exists, not the first resort.

The adversarial pass is **not a second review**. A reviewer asks "is this good?" and finds
reasons to agree. A falsifier is told: *this finding is probably wrong — show me why*. It
gets the claim, the evidence offered for it, and read-only access, and it reports whether
the claim survives contact with the code.

- One falsifier per substantive claim, not one per agent. A wave that returns three real
  findings needs three falsifications, however many agents produced them.
- The falsifier must not be the agent that produced the claim, and must not see its
  reasoning — only the claim and the evidence. Its own context is the point.
- A claim that survives is reported as confirmed *with what the falsifier tried*. A claim
  that dies is reported as dead, not quietly dropped: knowing a plausible finding was
  checked and disproved is worth as much as the finding would have been.

## 5. Judge

You read the reports and decide whether another round earns its cost. There is no fixed
round count. Another round is worth it when the reports **disagree** with each other, when
a confirmed finding opens a question nobody was briefed on, or when coverage came back
visibly thin (an agent that returned little usually hit a bad brief, not an empty subject).
It is not worth it when the findings converged, or when the remaining questions are ones
you can answer faster inline than you can brief.

**Never resolve by majority vote.** Plurality voting discards a right answer already present
in the candidate pool (oracle gap up to 32.3 points — arXiv 2605.00914). Your judgment is
orchestration, not a ballot. Treat **unanimity as suspicious rather than conclusive** —
correlated error means agreement is the cheap outcome, not proof.

**A second round must bring new evidence, never more discussion.** Homogeneous multi-agent
debate matched or underperformed isolated self-correction on every tested model, at
2.1–3.4× the tokens (arXiv 2605.00914). More talk is not a round.

Say which of those applied. "Running another round" and "stopping here" are both decisions
the user should see the reason for.

## 6. Integrate

You are the sole integrator and the only voice the user hears. Subagent output is input to
you, never output to them, and none of it is visible to the user unless you relay it.

Stage only files whose author has reported. A tree mid-fan-out contains half-written work,
and sweeping it into a commit is how a broken import reaches the branch.

Report per `reporting-to-the-user.mdc`: close the loop on what was asked, at the conceptual
level, with the findings that survived falsification and the ones that did not.

## Keeping track, mechanically

The prohibitions above say what not to assume; `subagent-liveness.mdc` is the machinery that
lets you *know* instead — an on-disk registry outside the repo, a polling schedule rather
than passive waiting, liveness read from modification times under each agent's owned paths,
and the assume-everything-dead posture after any restart. Set the registry up when you
dispatch, not when you get worried. Read that rule; this skill does not carry a second copy
of it.

## Domain delegation — working a big spec

Sometimes the spec is not a list of tasks but a set of **feature sets or domains**, each
too large for the orchestrator to write worker briefs for directly. `/collaborate` is
the thin sibling skill that invokes this loop in that mode; the mode itself is this
section.

**The constraint, measured rather than assumed:** on Claude Code, subagents cannot
spawn subagents — the Agent primitive is absent from a subagent's toolset (probed
empirically there, 2026-08). True process recursion exists only by shelling out to
`claude -p` from an agent's Bash, which the harness does not supervise: no completion
notification, liveness only by side effects. On Cursor, `claude -p` **is** the standard
dispatch primitive (the per-surface table in `subagent-orchestration.mdc`), so every
level is side-effect-supervised and flat is still the shape the orchestrator can
actually watch. On Codex there is no fan-out at all — keep the domain structure as
sections of one inline plan. The design below follows the supervision, not the
possibility.

**The pattern: logical recursion, flat execution.** The hierarchy lives in the briefs
and the integration structure, never in the process tree:

- The orchestrator partitions the spec into domains with disjoint file ownership, and
  owns the partition.
- Per domain, a **domain-owner agent** is dispatched whose deliverable is not the code
  but the plan: the domain's work breakdown as *exact, dispatchable worker briefs* (the
  same five-part brief contract as §3), the integration notes, and the domain's
  acceptance criteria. An owner emits briefs to the on-disk registry **as it produces
  them**, never solely in its final message — and a domain whose planning cannot finish
  in a short pass is split into two domains, not given a longer agent.
- The orchestrator dispatches those worker briefs itself, at depth one, where the
  harness supervises them — using the on-disk queue above when the cap binds, and
  interleaving workers across domains as slots allow.
- Domain-level integration review goes back to the same owner where the surface can
  resume an agent, otherwise to a fresh agent carrying the owner's plan and acceptance
  criteria; the orchestrator remains the sole final integrator and the only voice the
  user hears.

Responsibility composes exactly as the user would expect: each owner answers for its
domain, the orchestrator answers for everything — delegation transfers effort, never
responsibility, at every level.

**The escape hatch, and its price.** Where one domain genuinely exceeds its owner's
context even for *planning*, the owner may split the domain and return two plans — or
run `claude -p` children itself, which on Claude Code is a last resort (it forfeits the
harness's supervision) and on Cursor is simply the ordinary primitive one level deeper.
Either way `subagent-liveness.mdc` binds the owner as the orchestrator of those
children: disjoint paths, findings to disk as they are produced, liveness by side
effects, children scoped to finish in minutes. Prefer the split wherever structure can
be flattened.

## Loop mode — working a list unattended

Everything above assumes you are present. This mode does not: it works a list over
successive rounds, committing as it goes, typically overnight, and the user reads one report
when they wake. **Invoking this mode is itself the explicit opt-in** that
`subagent-orchestration.mdc` requires for autonomous list-draining — that rule names this
mode as the exception rather than being silently overridden by it. Nothing else is relaxed:
branch only, and never a merge, deploy, send, spend, or write to a live system.

Phrase everything here as a **role, not a path**. A rule that only parses if you already know
this repo's directory names has not been generalised; name local vocabulary as an example, never
as the definition.

### How much to do

Read the scale off the prompt. "Fix everything" drains the list; "sort these two things out"
does two. There is no round count, and asking for one misses the point — the prompt already
said how much.

**The list** is whatever already-identified work the run is meant to drain: an explicit list
the user just gave, a backlog or issue tracker the repo keeps, code-level TODOs. Where none of
those exist, the user's prompt is the whole list.

Where the list is broad, unordered, or thin enough that *choosing* is part of the job, hand
that choice to whatever work-selection capability the environment offers rather than ranking
by feel — in this repo that is the `next` skill, but ask for the capability, not the name. If
none exists, rank inline by the same things one would: what the user pointed at, what is
already broken, what is cheapest to finish, and what sits closest to the code just touched.
Selection happens **once per round**, against the state the previous round left behind — not
once up front, or the ordering is stale by round three.

### Build or plan — in this order, stopping at the first that answers

1. **The user said which.** "Plan this" plans, "build this" builds. Nothing below overrides it.
2. **Is this a surface someone already flagged as needing a human?** A lookup, not a judgment
   call: a compliance or audit document naming an open gap, the authorization/permission
   registry, payment and billing paths, anything on the always-on rules' explicit-authorization
   list. If the surface is named there, **plan** — no matter how small the diff.
3. **The footprint tests.** Any one firing means plan:
   - **Reachability** — does this change the behaviour or availability of something already
     live in the deployed product, as against docs, tests, or code with no entry point?
   - **Undo** — does reversing it need more than dropping the branch? Calling a provider API,
     writing outside a local database, changing a data contract other merged code relies on.
   - **Coupling** — does it span more than one ownership boundary *and* leave the feature
     broken if only half ships? Multi-file is not multi-surface. A deletion of code every site
     already marks dead is not multi-surface either, however many files it touches.
4. **Otherwise build.** Budget is fine unless the user said otherwise; they will say.

Steps 2 and 3 are in that order deliberately, and the order is the whole point. **The footprint
tests measure the blast radius of the diff; step 2 measures the blast radius of being wrong.**
A one-line change can carry unbounded consequence, and no amount of counting files or tracing
imports will ever recover that — which is why a lookup against what the repo has already
recorded as consequential has to come first. Where a repo keeps no such records the list is
empty and footprint decides alone.

### What is not the user's question

Almost nothing about *how* to build is. They asked for the feature; you choose the approach,
the library, the shape. If your chosen library then fights you, that is your problem to solve,
not theirs to arbitrate — unless it was the obviously correct choice and the problem is
inherent to it, which is a finding worth reporting. **Do not treat as fixed anything the user
did not fix.** An unstated preference is not a constraint, and inventing constraints to be safe
is its own failure.

Build it even when you are only half sure you have understood. A half-match at breakfast that
can be tested and refined beats a perfect question slept through — that trade is the entire
reason this mode exists.

### Pushing back, when nobody is awake to hear it

Push back on unavoidable consequences the user has not priced in. But "push back" presupposes
someone to push back at, and there is nobody, so it cannot mean stalling — a pushback that
builds nothing is a banked question wearing a louder label, and it costs the night.

It means **build it in its least destructive available form, and put the warning first**:
additive rather than destructive, a parallel path rather than an in-place overwrite, off by
default where a switch genuinely applies. Both halves, always — a warning attached to something
already irreversible is theatre, and a careful construction nobody is told about is a trap.
Where no reversible construction exists, build everything else and bank only the irreducible
part.

Fire this only when **both** hold: the consequence reaches something genuinely serious (real
users, real money, a security boundary, something hard to undo), **and** it is not already
implied by the user's own words. "Delete X" prices in destruction — the word is the outcome.
"Add field Y" that happens to lock a live table does not. Requiring both is what stops this
becoming a licence to second-guess every instruction.

### Five times a half-build is worse than an empty branch

The half-match argument holds nearly everywhere. These are the exceptions, and all five are
detectable from the diff or the path — none needs the user woken.

- **A half-wired permission boundary reads as protected and is not.** Where a gate spans a
  backend check, a registry, and a frontend placement, finishing some of them ships a hole that
  looks like a feature. Verify every piece is present, or leave the surface unreachable.
- **Work that writes data is not undone by dropping the branch.** A migration that mutates rows
  has already mutated them. Prove it round-trips, or write it and leave it unrun.
- **Files that must move together.** A generated file and its source, a constant and its mirror
  in another language, a document and the values it describes. Update the pair in the same
  round or bank the other half explicitly.
- **Unhandled branches stay green.** Implement one arm of a dispatch table or state machine and
  every existing test still passes — the strongest possible false signal. Enumerate which
  branches you implemented and which you did not.
- **Bulk generated content.** A large batch of plausible-looking material costs a human line-by-line
  review to trust. Label what was verified against a source and what was not, so the review
  time lands where it is needed.

### Stopping

The absence of a round count is not an absence of termination.

- **A round may split an item; it may never add a sibling.** Splitting a task into its parts
  converges. Admitting newly-discovered work as fresh top-level items does not — finding work
  becomes the work, and the run never ends. A genuinely separate discovery is *banked verbatim,
  not attempted*.
- **A broken tree pre-empts everything.** Check health at the start of each round, before
  consulting the list. If the last round left it red, fixing that is this round's job.
- **Two rounds on one item without landing it banks the item** — one pass to find the problem,
  one to fix it, then it is a next step with a diagnostic, not a loop.
- **A round that commits nothing and changes no item's state is a failed attempt**, counted the
  same way. Two of those with nothing else actionable ends the run.
- **When the list drains, stop and report.** Do not go hunting for more. The user set the scale
  in the prompt; an agent that invents its own scope at 4am is the hardest failure to undo.
- **Keep one wall-clock backstop** as insurance against bugs in the logic above, sized off the
  run's own context. It is not a target and never binds on a healthy run — it guarantees the
  report exists by morning even if the stop conditions fail.

### Your own liveness

`subagent-liveness.mdc` binds you harder here than anywhere, because the thing most likely to
die unnoticed is *this session*. Write the list state, the last commit, and the tree-health
result to disk **before** each round's risky work, not after — one commit per round bounds what
a death costs, but only the on-disk record explains why it stopped.

**Do not read liveness off a transcript's size or modification time.** Measured here, in the
session that wrote this rule: an agent with a 119-byte transcript, untouched for four and a half
minutes while five siblings had finished, was declared dead and relaunched. It was alive, and
returned a full report from twenty-nine tool calls minutes later. Transcripts in this harness
are not written incrementally, so their mtime says nothing at all about the agent. Judge by
side effects in the work itself, and where a duplicate would be harmless — a read-only
agent — prefer waiting anyway.

### The report

Per `reporting-to-the-user.mdc`: what was built, where to look, what is needed. Two additions
specific to running unattended. **Anything built in reduced form appears twice** — in what was
built, flagged, and again under what is needed, with your recommendation and how to revert.
**Banked questions come last and together**, so one pass answers all of them. Order what needs
the user by consequence, not by the order the loop happened to hit them.

Every loop-mode run also ends by writing a run diagnostic per the `debrief` skill — the
deviations, the friction with this skill's own text, the proposed edits. The report mentions
in one line that the diagnostic exists; it does not restate it.

## On Codex

There is no subagent primitive. Do the work inline from the first step — do not attempt
fan-out, do not keep a subagent registry, and do not treat yourself as a silent orchestrator
talking only to yourself. Apply the falsification step to your own output as a deliberate
second pass (claim + evidence, then try to kill it), prefer executable verifiers, and say
that is what you did. You are the user-facing session here; address the user normally.
