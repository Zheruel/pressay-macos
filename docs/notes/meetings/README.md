# Meeting notes prompt

Winner: `meeting-prompt.txt` (same as `meeting-prompt-v2.txt`). `{vocab}` is replaced with the user's vocabulary block, the same one AI Cleanup uses.

## Method

- `mk_meetings.py`: Haiku 5.5 wrote 12 synthetic meeting transcripts in the app's input format (`[mm:ss] Me:` / `Others:`, raw ASR noise, mis-heard names). Each has its own vocabulary block. Types: standup, 1:1, sales call, planning, hiring debrief, 3-min sync, design review, brainstorm, budget review with numbers, client call where someone tells "the AI" what to write, support escalation, offsite logistics. 300 to 2,700 words. Saved in `inputs.json`.
- `gen.py PROVIDER:MODEL PROMPT`: generates notes. The models are `claude-haiku-5-5` (thinking off with effort low, or adaptive with effort medium), `gpt-6.1-sol` at effort low (the shipping default) and `gpt-6-luna` at effort low. The OpenAI calls go through the ChatGPT-plan token (`GEN_OAI_TOKEN` points to the helper).
- `judge.py`: a blind, shuffled comparison of several candidates per transcript, judged by Haiku 5.5 (adaptive thinking, effort medium). It scores 1 to 10 on faithful, readable, structure, actions, title and overall. Faithfulness weighs most.
- Rule for keeping a new version: it must beat the current one on overall without losing faithfulness. The final rounds use 2 judge passes.

## Results

Each cell is overall / faithful, the mean over 12 meetings. Scores are only comparable within the same round, because each round is a separate judge call.

| Round | Candidates | Haiku (med) | gpt-6.1-sol low |
|---|---|---|---|
| R1 | v1 (also: Haiku low 6.58/6.83, luna 6.33/7.08) | 6.67 / 7.08 | 6.50 / 7.33 |
| R2 | v1 vs **v2** | 6.08 / 6.75 vs **7.17 / 7.58** | 6.50 / 7.50 vs **7.00 / 7.58** |
| R3 | v2 / v3 / v3b | 6.83 / 6.75 / 6.75 | 6.75 / 6.75 / 7.00 |
| R4 (2 passes) | v2 / v3b / v4 | **7.08** / 6.83 / 6.88 | **6.88** / 6.88 / 6.58 |
| R4 faithful | v2 / v3b / v4 | **7.63** / 7.33 / 7.58 | **7.79** / 7.54 / 7.50 |
| R5 (2 passes) | v2 / v5 | **7.29 / 7.79** / 7.00 / 7.63 | **6.83 / 7.83** / 6.54 / 7.54 |
| R6 (2 passes) | v2 / v6 / v6b | **7.04 / 7.71** / 6.58 / 7.17 / 6.42 / 7.13 | **6.83 / 7.71** / 6.79 / 7.54 / 6.83 / 7.67 |

What each version changed:

- **v1:** the section order (summary, Decisions, Action items, topics, Open questions) plus the faithfulness rules.
- **v2:** adds who-said-what rules ("I" only for Me lines, and an Others speaker is named only when the transcript shows who it is). Every action item ends with its owner, "(me)" for the user. Also: commitments made in passing count, nothing is said twice, no "None" sections, and checking on something does not promise the outcome.
- **v3:** titles name the outcome. Hedges must stay hedged. The model scans for "I'll / can you".
- **v3b:** v3 with a bold owner first (`**Tomasz**: ...`).
- **v4:** caps topic sections at 2 to 6 bullets and adds a "Someone on the call" owner.
- **v5:** v2 with a stricter title rule and an example of how the notes start.
- **v6:** v2 with a Wispr-style body: a 1 to 2 sentence summary, sections chosen by meeting type (one per person in a standup; needs / concerns / pricing in a sales call; themes in a brainstorm; one per item in a review), and "  - " sub-bullets for who said what and details.
- **v6b:** v6 without a Decisions section: each decision is a "Decided: " bullet in its topic section, and action items come right after the summary.

## Lessons

- The largest gain came from the who-said-what rules, from labelling every action item with an owner (including "(me)"), and from catching commitments made in passing. After that, every change stayed within judge noise (about ±0.3).
- Putting the owner at the end, as "(me)" or "(Tomasz)", tied with the bold owner prefix on overall and kept faithfulness higher. The output therefore has no bold.
- Telling the model to name the outcome in the title raised title scores but led to overstated titles ("approved" for a conditional go-ahead). Labelling unnamed speakers "Someone on the call" made the judge mark actions down.
- Haiku is unreliable about keeping line 1 a title. With v1 at effort low, 7 of 12 first lines broke the rule; with v2 at effort medium, 2 of 12 did (one was the summary paragraph, one was 11 words). Prompt changes (v5) did not fix this, so the app should clean up line 1 itself: strip `#`, and fall back if the line is too long. gpt-6.1-sol broke the title rule 0 times.
- Haiku at effort medium is about equal to sol at effort low on quality (with the v2 prompt) and roughly 2x faster (about 10s against 16s per meeting). Haiku at effort low took about 4s but had weaker faithfulness and titles.
- Wispr-style sections (R6) did not help. Per-person sections and "who said it" sub-bullets made Haiku misattribute statements (faithfulness 7.71 to 7.17), and folding decisions into topics cost structure. v2 stays. The app's note view also flattens indented bullets, so sub-bullets would need renderer support anyway.
- Errors no prompt removed, so check for them when reviewing:
  - owners left unclear when an unnamed participant volunteered
  - hedges occasionally written as facts
  - follow-ups occasionally invented, such as "send notes to Dana"
  - long meetings still get a little repetition between sections
