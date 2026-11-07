"use strict";
// Ask: a chat about your meetings that lives at the bottom of Notetaker.
// The bar is always there; it opens into a conversation above itself. Each
// scope (one meeting, or all meetings) keeps its own conversation while the
// app is open. Answers cite their meetings, and citations open them.
(function () {
  const $ = (id) => document.getElementById(id);
  const el = (tag, text, className) => {
    const node = document.createElement(tag);
    if (text !== undefined) node.textContent = text;
    if (className) node.className = className;
    return node;
  };
  const COPY =
    '<svg viewBox="0 0 20 20" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" aria-hidden="true"><rect x="7" y="7" width="9.5" height="10" rx="2"/><path d="M13 7V5a2 2 0 0 0-2-2H5.5a2 2 0 0 0-2 2v6.5a2 2 0 0 0 2 2H7"/></svg>';

  const threads = new Map(); // scope key -> [{ question, answer, sources, error, pending }]
  let scope = "this", // what the person picked when a meeting is open
    note = null, // the open meeting, if any
    open = false,
    busy = null, // { key, epoch } while an answer is on its way
    epoch = 0,
    available = false,
    renderedKey = null;

  const key = () => (scope === "this" && note ? note.id : "all");
  const thread = () => {
    if (!threads.has(key())) threads.set(key(), []);
    return threads.get(key());
  };
  const shortDate = (seconds) =>
    new Date(seconds * 1000).toLocaleDateString(
      typeof formattingLocale === "function" ? formattingLocale() : undefined,
      { month: "short", day: "numeric" },
    );

  function setOpen(next, focus = true) {
    open = next;
    $("ask").dataset.state = open ? "open" : "closed";
    $("ask-input").setAttribute("aria-expanded", String(open));
    closeScopeMenu();
    if (open) {
      renderThread(true);
      if (focus) $("ask-input").focus();
    }
  }

  function closeScopeMenu() {
    $("ask-scope-menu").hidden = true;
    $("ask-scope").setAttribute("aria-expanded", "false");
  }

  function renderBar() {
    const meeting = scope === "this" && note;
    $("ask-scope-label").textContent = meeting
      ? "This meeting"
      : "All meetings";
    $("ask-scope").disabled = !note;
    $("ask-scope").title = note
      ? "Choose what to ask about"
      : "Open a meeting to ask about just that one";
    for (const item of $("ask-scope-menu").querySelectorAll("[data-scope]"))
      item.setAttribute(
        "aria-checked",
        String((item.dataset.scope === "this") === !!meeting),
      );
    $("ask-scope-this-title").textContent = note?.title || "This meeting";
    const waiting = busy && busy.key === key();
    $("ask-input").disabled = !available;
    $("ask-input").placeholder = !available
      ? "Connect Claude or OpenAI in Settings to ask about your meetings"
      : thread().length
        ? "Ask a follow-up…"
        : meeting
          ? "Ask about this meeting…"
          : "Ask about all your meetings…";
    $("ask-setup").hidden = available;
    $("ask-send").hidden = !!waiting || !available;
    $("ask-send").disabled = !$("ask-input").value.trim() || !!busy;
    $("ask-stop").hidden = !waiting;
    $("ask-new").disabled = !thread().length || !!waiting;
  }

  function citeInto(container, sources) {
    // Turn [n] markers into small numbered links to their meetings.
    const byNumber = new Map(sources.map((s) => [s.n, s]));
    const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT);
    const texts = [];
    while (walker.nextNode()) texts.push(walker.currentNode);
    for (const text of texts) {
      const parts = text.nodeValue.split(/(\[\d+(?:\s*,\s*\d+)*\])/u);
      if (parts.length === 1) continue;
      const fragment = document.createDocumentFragment();
      for (const part of parts) {
        const match = part.match(/^\[([\d,\s]+)\]$/u);
        if (!match) {
          if (part) fragment.append(part);
          continue;
        }
        for (const n of match[1].split(",").map((v) => Number(v.trim()))) {
          const source = byNumber.get(n);
          if (!source) continue;
          const order = sources.indexOf(source) + 1;
          const cite = el("button", String(order), "ask-cite");
          cite.type = "button";
          cite.title = `${source.title}, ${shortDate(source.created_at)}`;
          cite.setAttribute("aria-label", `Source: ${cite.title}`);
          cite.onclick = () => openMeeting(source.id);
          fragment.append(cite);
        }
      }
      text.replaceWith(fragment);
    }
  }

  function openMeeting(id) {
    if (typeof selectNote === "function") selectNote(id);
  }

  function plainAnswer(text) {
    return text.replace(/\s?\[\d+(?:\s*,\s*\d+)*\]/gu, "");
  }

  function messageNodes(item, index, list) {
    const nodes = [el("div", item.question, "ask-msg ask-question")];
    if (item.pending) {
      const pending = el("div", undefined, "ask-msg ask-answer ask-pending");
      pending.setAttribute("role", "status");
      pending.append(
        el("span", undefined, "ask-dots"),
        el(
          "span",
          note && scope === "this"
            ? `Reading ${note.title || "this meeting"}…`
            : "Searching your meetings…",
        ),
      );
      pending.querySelector(".ask-dots").append(el("i"), el("i"), el("i"));
      nodes.push(pending);
      return nodes;
    }
    if (item.error) {
      const failure = el(
        "div",
        undefined,
        `ask-msg ask-answer ask-error${item.stopped ? " ask-stopped" : ""}`,
      );
      failure.append(el("p", item.error));
      if (index === list.length - 1) {
        const retry = el("button", "Try again", "ask-chip");
        retry.type = "button";
        retry.disabled = !available || !!busy;
        retry.onclick = () => {
          if (!available || busy) return;
          list.splice(index, 1);
          send(item.question);
        };
        failure.append(retry);
      }
      nodes.push(failure);
      return nodes;
    }
    const answer = el("div", undefined, "ask-msg ask-answer");
    const body = el("div", undefined, "ask-answer-body");
    window.renderNoteMarkdown(item.answer, body);
    citeInto(body, item.sources || []);
    answer.append(body);
    const footer = el("div", undefined, "ask-answer-footer");
    if (item.sources?.length) {
      const sources = el("div", undefined, "ask-sources");
      item.sources.forEach((source, i) => {
        const chip = el("button", undefined, "ask-source");
        chip.type = "button";
        chip.append(
          el("span", String(i + 1), "ask-source-n"),
          el("span", source.title || "Untitled", "ask-source-title"),
          el("span", shortDate(source.created_at), "ask-source-date"),
        );
        chip.onclick = () => openMeeting(source.id);
        sources.append(chip);
      });
      footer.append(sources);
    }
    const actions = el("div", undefined, "ask-actions");
    const copy = el("button", undefined, "ask-action");
    copy.type = "button";
    copy.innerHTML = COPY;
    copy.append(el("span", "Copy"));
    copy.onclick = async () => {
      try {
        await window.__TAURI__.core.invoke("copy_text", {
          text: plainAnswer(item.answer),
        });
        copy.lastChild.textContent = "Copied";
        setTimeout(() => (copy.lastChild.textContent = "Copy"), 1400);
      } catch {}
    };
    actions.append(copy);
    if (note && scope === "this") {
      const keep = el("button", undefined, "ask-action");
      keep.type = "button";
      keep.append(
        el("span", item.kept ? "Added to My notes" : "Add to My notes"),
      );
      keep.disabled = !!item.kept;
      keep.onclick = async () => {
        const id = note.id;
        keep.disabled = true;
        try {
          // Save anything still being typed, then add to the latest My notes.
          await flushNoteSave();
          const target = current.view.notes.find((n) => n.id === id) || note;
          const existing = (target.myNotes || "").trim();
          const addition = plainAnswer(item.answer).trim();
          const myNotes = existing ? `${existing}\n\n${addition}` : addition;
          await window.__TAURI__.core.invoke("edit_note", {
            id,
            patch: { myNotes },
          });
          target.myNotes = myNotes;
          noteVersion = "";
          renderNotes(current.view);
          item.kept = true;
          keep.firstChild.textContent = "Added to My notes";
        } catch (error) {
          keep.disabled = false;
          keep.firstChild.textContent = "Couldn’t add. Try again";
        }
      };
      actions.append(keep);
    }
    footer.append(actions);
    answer.append(footer);
    nodes.push(answer);
    return nodes;
  }

  // Before the first question: a few plain starting points, nothing more.
  function emptyState() {
    const meeting = scope === "this" && note;
    const prompts = meeting
      ? [
          "What did we decide?",
          "What are my action items?",
          "Draft a follow-up email",
        ]
      : ["What do I owe people?", "Recap this week", "What’s still open?"];
    const list = el("div", undefined, "ask-suggestions");
    for (const prompt of prompts) {
      const row = el("button", prompt, "ask-suggestion");
      row.type = "button";
      row.disabled = !available || !!busy;
      row.onclick = () => send(prompt);
      list.append(row);
    }
    return list;
  }

  function renderThread(force = false) {
    const items = thread();
    const signature = JSON.stringify([
      key(),
      items.map((i) => [i.pending, i.error, i.answer?.length, i.kept]),
      available,
      !!busy,
      note?.title,
    ]);
    if (!force && signature === renderedKey) return;
    renderedKey = signature;
    const container = $("ask-thread");
    const nearBottom =
      container.scrollHeight - container.scrollTop - container.clientHeight <
      80;
    container.replaceChildren(
      ...(items.length
        ? items.flatMap((item, i) => messageNodes(item, i, items))
        : [emptyState()]),
    );
    $("ask").dataset.empty = String(!items.length);
    $("ask-title").textContent =
      scope === "this" && note ? note.title || "This meeting" : "All meetings";
    if (force || nearBottom) container.scrollTop = container.scrollHeight;
  }

  async function send(question) {
    question = question.trim();
    if (!question || !available || busy) return;
    if (!note) scope = "all";
    const k = key(),
      list = thread(),
      ids = k === "all" ? [] : [k];
    const item = { question, pending: true };
    list.push(item);
    const mine = { key: k, epoch: ++epoch };
    busy = mine;
    $("ask-input").value = "";
    autosize();
    if (!open) setOpen(true);
    renderBar();
    renderThread(true);
    try {
      const reply = await window.__TAURI__.core.invoke("ask_notes", {
        question,
        ids,
        history: list
          .filter((i) => i !== item && i.answer)
          .slice(-20)
          .map((i) => ({ question: i.question, answer: i.answer })),
      });
      item.answer = reply.text;
      item.sources = reply.sources || [];
    } catch (error) {
      item.stopped =
        busy?.epoch === mine.epoch && String(error) === "Cancelled";
      item.error = item.stopped ? "Stopped." : String(error);
    } finally {
      item.pending = false;
      if (busy?.epoch === mine.epoch) busy = null;
      renderBar();
      renderThread(key() === k);
    }
  }

  function autosize() {
    const input = $("ask-input");
    input.style.height = "auto";
    input.style.height = `${Math.min(input.scrollHeight, 120)}px`;
  }

  function setup() {
    $("ask-form").onsubmit = (event) => {
      event.preventDefault();
      send($("ask-input").value);
    };
    $("ask-input").addEventListener("input", () => {
      autosize();
      renderBar();
    });
    $("ask-input").addEventListener("focus", () => {
      if (!open) setOpen(true, false);
    });
    $("ask-input").addEventListener("keydown", (event) => {
      if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
        event.preventDefault();
        send($("ask-input").value);
      }
    });
    $("ask").addEventListener("keydown", (event) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      if (!$("ask-scope-menu").hidden) {
        closeScopeMenu();
        $("ask-scope").focus();
      } else {
        setOpen(false);
        $("ask-input").blur();
      }
    });
    $("ask-collapse").onclick = () => setOpen(false);
    $("ask-new").onclick = () => {
      threads.set(key(), []);
      renderBar();
      renderThread(true);
      $("ask-input").focus();
    };
    $("ask-stop").onclick = () =>
      window.__TAURI__.core
        .invoke("cancel_note_job", { id: "ask" })
        .catch(() => {});
    $("ask-setup").onclick = () => openSettings("ai");
    $("ask-scope").onclick = () => {
      const menu = $("ask-scope-menu");
      menu.hidden = !menu.hidden;
      $("ask-scope").setAttribute("aria-expanded", String(!menu.hidden));
      if (!menu.hidden) menu.querySelector('[aria-checked="true"]')?.focus();
    };
    for (const item of $("ask-scope-menu").querySelectorAll("[data-scope]"))
      item.onclick = () => {
        scope = item.dataset.scope;
        closeScopeMenu();
        renderBar();
        renderThread(true);
        $("ask-input").focus();
      };
    // Clicking the note behind closes the conversation; the bar stays.
    document.addEventListener("pointerdown", (event) => {
      if (!$("ask").contains(event.target)) {
        closeScopeMenu();
        if (open && !event.target.closest?.(".ask-cite, .ask-source"))
          setOpen(false, false);
      }
    });
  }

  window.pressayAsk = {
    setup,
    // Called on every Notetaker render with the current state.
    sync({ meeting, recording, hasNotes, canAsk }) {
      const changed =
        note?.id !== meeting?.id || note?.title !== meeting?.title;
      note = meeting || null;
      available = canAsk;
      $("ask").hidden = recording || !hasNotes;
      if (recording && open) setOpen(false, false);
      renderBar();
      if (open) renderThread(changed);
    },
    toggle() {
      if ($("ask").hidden) return;
      if (open && document.activeElement === $("ask-input")) setOpen(false);
      else setOpen(true);
    },
    close() {
      if (open) setOpen(false, false);
    },
  };
})();
