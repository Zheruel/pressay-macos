# Vibe Mode

> **Ramble in. Brief out.**

Vibe Mode is Pressay's deliberate second gear for AI-agent instructions. Standard dictation answers “what did I say?” as quickly and faithfully as possible. Vibe Mode answers “what work order was I trying to give?”

Hold Right Command by default and speak naturally—ramble, self-correct, think out loud. Pressay packages the same intent into a concise first-person brief without silently changing the normal dictation path.

## How it works

1. Pressay records only while the Vibe Mode key is held and remembers the destination field without taking focus.
2. On release, it prepares the audio and transcribes it entirely on-device with the selected speech model.
3. Deterministic cleanup removes fillers and stutters, applies the curated and self-teaching dictionary, and preserves terminal casing.
4. Only the cleaned transcript is sent to the selected Kimi model using the API key in the macOS login keychain.
5. Kimi rewrites it as a work order: direct instruction first, then goal, boundaries, and requested deliverable.
6. The amber-to-pink overlay shows **Vibing…** while the cloud model works; the finished brief is inserted at the original cursor.

The generative wait is intentional. Standard dictation remains the instant, local gear.

## Model picker

The v1.1 model matrix produced one focused setting rather than multiple prompt knobs:

| Model | Shipping description | Use it when |
| --- | --- | --- |
| **Kimi K3** | Best briefs · about 8 seconds · recommended | Intent comprehension and brief quality matter most |
| Kimi K2.7 | Balanced · about 10 seconds | You prefer the established K2.7 behavior |
| Kimi K2.7 HighSpeed | Fast · uses 3× plan quota | Lower latency is worth the quota cost |

K3 is the default. Its request timeout is 60 seconds; the K2.7 variants use 45 seconds. Actual cloud latency varies with service conditions and prompt length.

## The brief contract

The calibrated shipping instruction tells Kimi to:

- write in the speaker's first-person voice;
- lead with the direct instruction or question;
- follow with the goal or motivation, constraints and boundaries, then the requested result or verification;
- keep every constraint, negation, number, URL, name, and technical identifier;
- make a clearly implied deliverable explicit without inventing requirements;
- merge redundant restatements and keep the brief as short as clarity allows;
- use bullets for genuinely multi-part requests and prose otherwise;
- avoid invented personas, acceptance criteria, technical details, or step-by-step reasoning demands;
- return a lone term or fragment verbatim;
- output the brief only—never answer it.

Pressay runs the result through its protected-token validator and records a local diagnostic note when needed. Because Vibe Mode is an explicitly requested rewrite, the validator is not a hard rejection gate. Review critical commands before an agent performs destructive work.

## Four shipped before-and-afters

These are real v1.1 calibration outputs published with the project owner's approval. Longer source and result passages are excerpted where marked; wording inside the excerpts is unchanged.

### 1. Forty seconds of thinking out loud → an analyst's brief

**Said — excerpt**

> I'm talking about the shadow strategy that we have for TWC… I think we have in the Markkamp file already where we logged some things… I want you to take a look at how we're performing. we're fast enough if we could potentially be getting even better entries like maybe compare us to him see what he bought and what his performance is versus what we bought… but I'm not sure how we match against him, which is very important… Take a good look at this, then give me a concise and clear report.

**Typed — excerpt**

> Analyze how our shadow strategy for TWC is performing and report back with a concise and clear report.
>
> Context: this is a strategy where we're trying to win against high temptation, and it's inspired by Markkamp. We've already logged what we did over time in the Markkamp file—start there.
>
> Specifically, I want to know:
>
> - Whether we're fast enough, or whether we could be getting even better entries.
> - How we match against him: compare what he bought and his performance versus what we bought and ours. This is the most important part…
> - How other people are doing in this market…
>
> My current read is that the strategy is making money seldom… assess that and tell me where we can improve.

This demonstrates the intended structure: request, context, questions, current hypothesis, deliverable.

### 2. A boundary at the end becomes an explicit rule

**Said — excerpt**

> …help me put them into the system. pull request with the changes so we can just approve it or merge it and then it's gonna deploy leave that step to me you just do the pull request

**Typed — excerpt**

> …Open a pull request with the changes so I can approve or merge it. Deployment happens after merge—leave that step to me; just do the pull request.

The packaging changes; ownership of deployment does not.

### 3. It understands the requested operation

**Said — excerpt**

> I want you to change this prompt instead of a backrooms game with raycaster and all that stuff…

**Typed — excerpt**

> Rewrite the attached prompt. Instead of describing a backrooms game with a raycaster and procedural generation from a seed, turn it into a prompt for a technically impressive demo. My goal: I'll use this prompt to test the capabilities of different models…

The important nuance is that the agent should rewrite the prompt, not build the demo.

### 4. Rambling product feedback → a ticket list

**Said — excerpt**

> This application is working great. I think we should now try to turn this into like a real app I can actually install on my Mac… I noticed that when we approve the second item, sometimes it doesn't immediately refresh, which it should do. Like, best practice approach, same as all the other apps do…

**Typed — excerpt**

> Turn this application into a real, installable Mac app, and polish the UX along the way. The app already works great and I plan to actually use it, so I want it production-ready.
>
> Specific items to address:
>
> - Package it as a proper app I can install on my Mac.
> - Fix a refresh bug: when we approve the second item, sometimes the UI doesn't immediately refresh—it should.
> - Rework the permissions flow to follow best practice…
> - Look over the general UX and polish anything that feels rough.

## The safety net: knowing when not to rewrite

**Said**

> SwiftData

**Typed**

> SwiftData

An earlier automatic-polish experiment expanded this lone term into an invented paragraph about building an application. Vibe Mode's calibrated instruction treats a fragment as a fragment, and standard dictation never invokes a generative rewrite at all.

## Privacy and failure behavior

| Stage | Location | What leaves the Mac? |
| --- | --- | --- |
| Recording and audio preparation | Local | Nothing |
| Whisper or Parakeet transcription | Local | Nothing |
| Deterministic cleanup and vocabulary | Local | Nothing |
| Vibe Mode rewrite | Kimi, only when this shortcut is used | Cleaned transcript text |
| Insertion and History | Local | Nothing |

Microphone audio and surrounding cursor context are never included in the Kimi request. The API key lives in Keychain, not preferences or history. Optional vocabulary review can separately send candidate terms and short transcript excerpts when a key is configured.

If the key is missing, the request times out, Kimi refuses, or the result is empty, Pressay inserts nothing. The local transcript remains recoverable from History and the overlay reports that Vibe Mode failed.

## Enabling Vibe Mode

1. Open **Settings → General**.
2. Add a Kimi API key under **Kimi cloud features** and test the connection.
3. Choose K3, K2.7, or K2.7 HighSpeed.
4. Confirm or change the Vibe Mode shortcut.
5. Hold the shortcut, speak naturally, and release.

Everything outside the explicitly labeled Kimi features continues to work locally without an API key.
