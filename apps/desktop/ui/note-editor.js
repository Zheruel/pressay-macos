"use strict";
// A small Markdown document editor: notes are edited as formatted text and
// saved back as Markdown. Supports headings, paragraphs, bullet, numbered and
// task lists, quotes, code blocks, bold, italic and inline code, which covers
// what Pressay writes up. Content is built with DOM nodes, never innerHTML.
(function () {
  const TASK = /^\s*[-*]\s+\[([ xX])\]\s+(.*)$/u;
  const BULLET = /^\s*[-*+]\s+(.*)$/u;
  const NUMBER = /^\s*(\d+)[.)]\s+(.*)$/u;
  const HEADING = /^(#{1,4})\s+(.*)$/u;

  function inline(target, text) {
    const parts = text.split(
      /(\*\*[^*]+\*\*|`[^`]+`|(?<![\p{L}\p{N}*])\*[^*\s][^*]*\*(?![\p{L}\p{N}*])|(?<![\p{L}\p{N}_])_[^_\s][^_]*_(?![\p{L}\p{N}_]))/gu,
    );
    for (const part of parts) {
      if (!part) continue;
      let node;
      if (part.startsWith("**") && part.endsWith("**") && part.length > 4)
        (node = document.createElement("strong")).textContent = part.slice(2, -2);
      else if (part.startsWith("`") && part.endsWith("`") && part.length > 2)
        (node = document.createElement("code")).textContent = part.slice(1, -1);
      else if (
        part.length > 2 &&
        ((part.startsWith("*") && part.endsWith("*")) ||
          (part.startsWith("_") && part.endsWith("_")))
      )
        ((node = document.createElement("em")).textContent = part.slice(1, -1)),
          (node.dataset.md = part[0]);
      else node = document.createTextNode(part);
      target.append(node);
    }
  }

  function taskItem(done, text) {
    const li = document.createElement("li");
    li.className = "task";
    li.append(checkbox(done));
    const span = document.createElement("span");
    inline(span, text);
    li.append(span);
    if (done) li.classList.add("done");
    return li;
  }

  function checkbox(done) {
    const box = document.createElement("input");
    box.type = "checkbox";
    box.checked = done;
    box.contentEditable = "false";
    box.tabIndex = -1;
    box.setAttribute("aria-label", "Done");
    return box;
  }

  function toDom(source, root) {
    root.replaceChildren();
    let list = null,
      code = null;
    const close = () => (list = null);
    for (const line of source.replace(/\r\n?/gu, "\n").split("\n")) {
      if (line.trimStart().startsWith("```")) {
        close();
        if (code) code = null;
        else {
          root.append((code = document.createElement("pre")));
          code.dataset.lang = line.trim().slice(3);
          code.dataset.lines = "0";
        }
        continue;
      }
      if (code) {
        code.append(document.createTextNode((code.dataset.lines++ > 0 ? "\n" : "") + line));
        continue;
      }
      const indent = line.match(/^\s*/u)[0];
      let match;
      if ((match = line.match(TASK))) {
        if (!list || list.tagName !== "UL" || !list.classList.contains("tasks")) {
          list = document.createElement("ul");
          list.className = "tasks";
          root.append(list);
        }
        const item = taskItem(match[1] !== " ", match[2]);
        if (indent) item.dataset.indent = indent;
        list.append(item);
        continue;
      }
      if ((match = line.match(BULLET)) || (match = line.match(NUMBER))) {
        const tag = BULLET.test(line) ? "UL" : "OL";
        if (!list || list.tagName !== tag || list.classList.contains("tasks")) {
          list = document.createElement(tag);
          if (tag === "OL" && match[1] !== "1") list.start = Number(match[1]);
          root.append(list);
        }
        const li = document.createElement("li");
        if (indent) li.dataset.indent = indent;
        inline(li, match[match.length - 1]);
        list.append(li);
        continue;
      }
      if (!line.trim()) continue;
      close();
      if ((match = line.match(HEADING))) {
        const h = document.createElement(`h${match[1].length}`);
        inline(h, match[2]);
        root.append(h);
      } else if (line.startsWith(">")) {
        const quote = document.createElement("blockquote");
        inline(quote, line.replace(/^>\s?/u, ""));
        root.append(quote);
      } else {
        const p = document.createElement("p");
        inline(p, line);
        root.append(p);
      }
    }
    if (!root.firstChild) root.append(emptyParagraph());
  }

  function emptyParagraph() {
    const p = document.createElement("p");
    p.append(document.createElement("br"));
    return p;
  }

  function inlineMd(node) {
    let out = "";
    for (const child of node.childNodes) {
      if (child.nodeType === Node.TEXT_NODE) out += child.nodeValue;
      else if (child.nodeType !== Node.ELEMENT_NODE) continue;
      else if (child.tagName === "INPUT") continue;
      else if (child.tagName === "BR") out += child.nextSibling ? "\n" : "";
      else {
        const text = inlineMd(child);
        if (!text.trim()) out += text;
        else if (["STRONG", "B"].includes(child.tagName)) out += `**${text}**`;
        else if (["EM", "I"].includes(child.tagName)) {
          const mark = child.dataset.md || "*";
          out += `${mark}${text}${mark}`;
        }
        else if (child.tagName === "CODE") out += `\`${text}\``;
        else out += text;
      }
    }
    return out.replace(/ /gu, " ");
  }

  function toMarkdown(root) {
    const blocks = [];
    const push = (text, tight) => blocks.push({ text, tight });
    for (const node of root.childNodes) {
      if (node.nodeType === Node.TEXT_NODE) {
        if (node.nodeValue.trim()) push(node.nodeValue.trim());
        continue;
      }
      if (node.nodeType !== Node.ELEMENT_NODE) continue;
      const tag = node.tagName;
      if (/^H[1-6]$/u.test(tag)) {
        const text = inlineMd(node).trim().replace(/\s*\n\s*/gu, " ");
        if (text) push(`${"#".repeat(Math.min(4, Number(tag[1])))} ${text}`, true);
      } else if (tag === "UL" || tag === "OL") {
        const lines = [];
        let n = tag === "OL" ? node.start || 1 : 1;
        for (const li of node.children) {
          const text = inlineMd(li).trim().replace(/\s*\n\s*/gu, " ");
          const indent = li.dataset.indent || "";
          const box = li.querySelector(":scope > input[type=checkbox]");
          if (box) lines.push(`${indent}- [${box.checked ? "x" : " "}] ${text}`);
          else if (text) lines.push(`${indent}${tag === "OL" ? `${n++}.` : "-"} ${text}`);
        }
        if (lines.length) push(lines.join("\n"));
      } else if (tag === "PRE")
        push("```" + (node.dataset.lang || "") + "\n" + node.textContent + "\n```");
      else if (tag === "BLOCKQUOTE") {
        const text = inlineMd(node).trim();
        if (text) push(`> ${text}`);
      } else {
        // P, DIV and anything pasted: one paragraph per visual line.
        const text = inlineMd(node).trim();
        if (text) push(text);
      }
    }
    // A heading sits directly on top of the block it introduces.
    return blocks
      .map((b, i) => (i ? (blocks[i - 1].tight ? "\n" : "\n\n") : "") + b.text)
      .join("");
  }

  function currentBlock(root) {
    const selection = getSelection();
    if (!selection.rangeCount) return null;
    let node = selection.anchorNode;
    while (node && node.parentNode !== root) {
      if (node.tagName === "LI") return node;
      node = node.parentNode;
    }
    return node && node.parentNode === root ? node : null;
  }

  function caretToEnd(node) {
    const range = document.createRange();
    range.selectNodeContents(node);
    range.collapse(false);
    const selection = getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  }

  // Typing a Markdown prefix at the start of a line turns it into that block.
  function applyShortcut(root) {
    const block = currentBlock(root);
    if (!block) return false;
    const text = block.textContent.replace(/ /gu, " ");
    const replace = (element) => {
      block.replaceWith(element);
      caretToEnd(element.querySelector("span") || element.lastElementChild || element);
      return true;
    };
    if (block.tagName === "LI") {
      if (/^\[\s?\]\s$/u.test(text) && !block.querySelector("input")) {
        const list = block.parentNode;
        const tasks = document.createElement("ul");
        tasks.className = "tasks";
        const item = taskItem(false, "");
        item.querySelector("span").append(document.createElement("br"));
        tasks.append(item);
        if (list.children.length === 1) list.replaceWith(tasks);
        else {
          block.remove();
          list.after(tasks);
        }
        caretToEnd(item.querySelector("span"));
        return true;
      }
      return false;
    }
    let match;
    if ((match = text.match(/^(#{1,3})\s$/u))) {
      const h = document.createElement(`h${match[1].length}`);
      h.append(document.createElement("br"));
      return replace(h);
    }
    if (/^([-*+]|\d+[.)])\s$/u.test(text)) {
      const list = document.createElement(/^\d/u.test(text) ? "ol" : "ul");
      const li = document.createElement("li");
      li.append(document.createElement("br"));
      list.append(li);
      return replace(list);
    }
    if (/^(\[\s?\]|[-*]\s\[\s?\])\s$/u.test(text)) {
      const list = document.createElement("ul");
      list.className = "tasks";
      const item = taskItem(false, "");
      item.querySelector("span").append(document.createElement("br"));
      list.append(item);
      return replace(list);
    }
    if (/^>\s$/u.test(text)) {
      const quote = document.createElement("blockquote");
      quote.append(document.createElement("br"));
      return replace(quote);
    }
    return false;
  }

  // Read-only Markdown rendering for chat answers, using the same rules.
  window.renderNoteMarkdown = function (source, root) {
    toDom(source, root);
    for (const box of root.querySelectorAll("input[type=checkbox]")) box.disabled = true;
  };

  window.createNoteEditor = function ({
    value = "",
    placeholder = "",
    readOnly = false,
    label = "Note",
    onChange,
    onFocusChange,
  }) {
    const root = document.createElement("div");
    root.className = "note-editor-doc";
    root.contentEditable = readOnly ? "false" : "true";
    root.spellcheck = true;
    root.setAttribute("role", "textbox");
    root.setAttribute("aria-multiline", "true");
    root.setAttribute("aria-label", label);
    root.dataset.placeholder = placeholder;
    toDom(value, root);
    if (readOnly)
      for (const box of root.querySelectorAll("input[type=checkbox]")) box.disabled = true;
    let last = toMarkdown(root);
    const empty = () =>
      root.classList.toggle("is-empty", !root.textContent.trim() && !root.querySelector("input"));
    empty();
    const changed = () => {
      empty();
      const markdown = toMarkdown(root);
      if (markdown === last) return;
      last = markdown;
      onChange?.(markdown);
    };
    root.addEventListener("focus", () => {
      document.execCommand("defaultParagraphSeparator", false, "p");
      onFocusChange?.(true);
    });
    root.addEventListener("blur", () => onFocusChange?.(false));
    root.addEventListener("input", (event) => {
      if (event.inputType === "insertText" && event.data === " ") applyShortcut(root);
      // A list item that loses its text and checkbox becomes a paragraph again.
      for (const li of root.querySelectorAll("ul.tasks > li")) {
        if (!li.querySelector("input")) li.prepend(checkbox(false));
      }
      changed();
    });
    root.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && !event.shiftKey) {
        const block = currentBlock(root);
        // Enter inside a task starts a new unchecked task.
        if (block?.tagName === "LI" && block.classList.contains("task")) {
          event.preventDefault();
          if (!block.textContent.trim()) {
            const p = emptyParagraph();
            const list = block.parentNode;
            block.remove();
            list.after(p);
            if (!list.children.length) list.remove();
            caretToEnd(p);
          } else {
            const item = taskItem(false, "");
            item.querySelector("span").append(document.createElement("br"));
            block.after(item);
            caretToEnd(item.querySelector("span"));
          }
          changed();
        }
        // Enter at the end of a heading continues with a paragraph.
        else if (block && /^H[1-4]$/u.test(block.tagName)) {
          const selection = getSelection();
          const range = selection.getRangeAt(0);
          const tail = document.createRange();
          tail.selectNodeContents(block);
          tail.setStart(range.endContainer, range.endOffset);
          if (!tail.toString()) {
            event.preventDefault();
            const p = emptyParagraph();
            block.after(p);
            caretToEnd(p);
            changed();
          }
        }
      }
      if ((event.metaKey || event.ctrlKey) && !event.altKey) {
        const key = event.key.toLowerCase();
        if (key === "b" || key === "i") {
          event.preventDefault();
          document.execCommand(key === "b" ? "bold" : "italic");
          changed();
        }
      }
    });
    root.addEventListener("paste", (event) => {
      event.preventDefault();
      const text = event.clipboardData.getData("text/plain");
      document.execCommand("insertText", false, text);
      if (!text.includes("\n")) return;
      // Pasted Markdown (lists, headings, tasks) becomes real blocks. Blocks
      // below the paste are untouched, so the caret lands after the paste.
      let block = currentBlock(root);
      if (block?.tagName === "LI") block = block.parentNode;
      let below = 0;
      for (let next = block?.nextSibling; next; next = next.nextSibling) below++;
      toDom(toMarkdown(root), root);
      const target = root.childNodes[root.childNodes.length - 1 - below];
      if (target) caretToEnd(target.tagName === "UL" || target.tagName === "OL" ? target.lastChild : target);
      changed();
    });
    root.addEventListener("change", (event) => {
      if (event.target.matches("input[type=checkbox]")) {
        event.target.closest("li")?.classList.toggle("done", event.target.checked);
        changed();
      }
    });
    root.addEventListener("mousedown", (event) => {
      // Clicking a checkbox shouldn't move the caret into the list.
      if (event.target.matches("input[type=checkbox]")) event.stopPropagation();
    });
    return {
      element: root,
      get value() {
        return toMarkdown(root);
      },
      setReadOnly(flag) {
        root.contentEditable = flag ? "false" : "true";
        for (const box of root.querySelectorAll("input[type=checkbox]")) box.disabled = flag;
      },
    };
  };
})();
