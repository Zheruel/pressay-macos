# Prompt polish

> Hold one key, speak, get faithful text. Hold the other key, ramble, get an engineered prompt.

Prompt polish is Pressay's deliberate second workflow for AI-agent instructions. It does not replace standard dictation and it never runs invisibly. The separate shortcut exists because faithful transcription and useful rewriting are different jobs with different trust and latency requirements.

## The workflow

1. Hold the prompt-polish shortcut—Right Command by default.
2. Pressay records while the key is held and captures the destination field without taking focus.
3. On release, audio is resampled, trimmed, and transcribed locally with the selected speech model.
4. Deterministic cleanup removes speech artifacts and applies curated and learned vocabulary.
5. Pressay sends only that cleaned transcript to Kimi using the API key in the macOS login keychain.
6. Kimi returns the rewritten prompt; Pressay inserts it at the original cursor and stores both versions in local History.

The prompt-polish overlay uses the app's amber-to-pink treatment and displays **Polishing…** during the cloud request. Its separate visual and sound language makes the slower, generative step intentional rather than surprising.

## Rewrite contract

The shipping template tells Kimi to:

- lead with the direct instruction or question;
- keep every fact, constraint, number, URL, name, and technical identifier;
- group related requirements and use short bullets only for genuinely multi-part requests;
- remove fillers, false starts, and superseded corrections;
- preserve uncertainty, hedges, and negations;
- retain requested output format, length, and audience;
- return a lone term or fragment verbatim;
- never answer the prompt or invent requirements, details, or acceptance criteria.

Pressay runs the result through its protected-token validator and records a faithfulness note in local logs when needed. Because this is an explicitly requested rewrite, that check is diagnostic rather than an automatic rejection gate. Review critical commands before an agent performs destructive work.

## Before and after

These are real examples from the private calibration set, published here with the project owner's approval. Line wrapping has been adjusted for readability; the substance is unchanged.

### 1. Rambling specification → clean brief

**You said**

> I want you to change this prompt instead of a backrooms game with raycaster and all that stuff. I'm just going to be making it as a technical impressive demo. It doesn't have to be procedurally generated with the seed. It should align to prompt engineering best practices. I will use this to test the capabilities of different models. And I would just want to get a result in HTML. can use whatever they want, HTML, CSS, JS, any frameworks, whatever, libraries, etc. to create the backroom's experience that is true to the movie and looks visually impressive. Output, just the prompt.

**It typed**

> Create a visually impressive, movie-faithful Backrooms technical demo in HTML. This is not a game, so it does not need a raycaster or procedural generation from a seed.
>
> Requirements:
>
> - Deliver the final result as HTML.
> - You may use HTML, CSS, JavaScript, and any frameworks or libraries you choose.
> - The Backrooms experience must be true to the movie and look visually impressive.
> - Follow prompt-engineering best practices and implement the highest-quality version possible, because this demo will be used to test and compare the capabilities of different models.

### 2. A mumbled boundary becomes an explicit rule

**You said**

> In the downloads folder we have some new blog posts that we want to put into the FR website. We already put in some articles before. The main goal here is to be nicely written, to follow the patterns that we have in the code, and to also be SEO optimal. So take a look at that zip in the downloads folder, look at all the articles we have there, and help me put them into the system. pull request with the changes so we can just approve it or merge it and then it's gonna deploy leave that step to me you just do the pull request

**It typed**

> Add the new blog posts from the zip file in the downloads folder to the FR website. Review the articles already added to understand the existing patterns, then integrate all articles from the zip into the system according to these requirements:
>
> - Follow the existing code patterns used for previously added articles.
> - Ensure the posts are nicely written.
> - Optimize them for SEO.
>
> Open a pull request with the changes. Do not deploy or merge the pull request—leave the deployment step to me.

### 3. Stream of consciousness → context and task

**You said**

> Is it possible to increase the performance of the bot or the transcription process we currently have? I want you to take a good look, possibly run some evaluations and then give me a report whether we can actually increase the performance of this or not. I think we already ran some batch marks before. And normally it works really well, but when the transcriptions are very big, then you then notice the weakness. We also have a bunch of historical data that this application saves, which you could use for this purpose…

**It typed**

> Analyze whether the performance of the bot/transcription process can be increased, and produce a report on whether it is actually possible.
>
> Context:
>
> - The process normally works well, but shows weaknesses when transcriptions are very large.
> - The application saves a bunch of historical data that can be used for this purpose.
>
> Task:
>
> - Run new evaluations to identify which part of the process takes the longest time.
> - Determine whether that part can be made faster while keeping the same level of quality.
> - Provide a report stating whether performance can be increased.

### 4. The speaker's uncertainty survives

**You said**

> One thing I would like to note is that I already had the Bumpar plan once. So it would be very cool if you could add exclusions or something so that we don't run into the limit with lines of code, because I think we really shouldn't with the amount of projects we have, considering the fact that not all these lines of codes are important, right? So it might be that it's scanning some stuff it shouldn't be looking at…

**It typed**

> Update the Bumpar plan to add exclusions or something so we don't hit the line-of-code limit.
>
> - With the number of projects we have, I think we shouldn't be reaching that limit.
> - Not all lines of code are important, so it might be scanning files or directories it shouldn't be looking at.
> - Handle this as part of the plan.
> - Note: I already had the Bumpar plan once.

### 5. It knows when not to polish

**You said**

> SwiftData

**It typed**

> SwiftData

This last case is important. An earlier automatic polish experiment expanded the same fragment into an invented paragraph about building an application. Pressay 1.0 treats a fragment as a fragment.

## Privacy and failure behavior

| Stage | Location | What leaves the Mac? |
| --- | --- | --- |
| Recording and audio preparation | Local | Nothing |
| Speech transcription | Local | Nothing |
| Deterministic cleanup and vocabulary | Local | Nothing |
| Prompt rewrite | Kimi, only when this shortcut is used | Cleaned transcript text |
| Insertion and History | Local | Nothing |

The surrounding cursor context and microphone audio are not included in the Kimi request. The API key is stored in Keychain, not preferences or history.

The cloud request has a 45-second timeout. If the key is missing, the request times out, Kimi refuses, or the result is empty, Pressay inserts nothing. The locally generated transcript remains available in History, and the overlay reports that polish failed.

## Enabling prompt polish

1. Open **Settings → General**.
2. Add a Kimi API key under **Kimi cloud features** and test the connection.
3. Confirm or change the prompt-polish shortcut.
4. Hold the shortcut, speak naturally, and release.

Standard dictation remains fully local and works without a Kimi key.
