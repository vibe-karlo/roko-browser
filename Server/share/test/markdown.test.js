import assert from "node:assert/strict";
import { test } from "node:test";
import { inline, parseAnswer, plain } from "../src/markdown.js";
import { answerPage, PICTURE_SCRIPT } from "../src/page.js";

const sample = `# Oktoberfest 2026
> It runs from **19 September** to 4 October.
## [date] When it runs
- **Start:** Saturday, 19 September
- **End:** Sunday, 4 October
## Where to go
Theresienwiese in Munich.`;

test("reads the answer's parts as the app does", () => {
  const page = parseAnswer(sample);
  assert.equal(page.title, "Oktoberfest 2026");
  assert.deepEqual(page.lead, ["It runs from **19 September** to 4 October."]);
  assert.equal(page.sections.length, 2);
  assert.equal(page.sections[0].topic, "date");
  assert.equal(page.sections[0].heading, "When it runs");
  assert.equal(page.sections[0].lines.length, 2);
  // Untagged: an icon from the heading's words.
  assert.equal(page.sections[1].topic, "place");
});

test("escapes everything that reaches the page", () => {
  assert.equal(inline("<script>alert(1)</script>"), "&lt;script&gt;alert(1)&lt;/script&gt;");
  assert.equal(inline(`"quoted" & 'single'`), "&quot;quoted&quot; &amp; &#39;single&#39;");
  assert.equal(inline("**bold** and *it*"), "<strong>bold</strong> and <em>it</em>");
});

test("links only to http(s)", () => {
  assert.equal(inline("[x](javascript:alert(1))"), "[x](javascript:alert(1))");
  assert.match(inline("[site](https://example.com/a?b=1&c=2)"), /href="https:\/\/example\.com\/a\?b=1&amp;c=2"/);
  assert.match(inline("[<b>](https://example.com)"), />&lt;b&gt;</);
});

test("an attribute can't be broken out of", () => {
  const html = inline(`[a](https://example.com/"onmouseover="x)`);
  assert.doesNotMatch(html, /" onmouseover/);
  assert.doesNotMatch(html, /href="[^"]*"onmouseover/);
});

test("the page escapes questions, titles and sources", () => {
  const html = answerPage({
    lang: "en", created: 0, updated: 0,
    turns: [{
      question: `<img src=x onerror=alert(1)>`,
      answer: `# <i>Title</i>\n> gist`,
      sources: [{ url: "https://example.com/", title: "</strong><script>x</script>" }],
      images: [],
    }],
  }, { url: "https://roko.test/a/abcdefghij", appURL: "/", reportEmail: "" });
  // The one script is the page's own picture tidy-up; nothing from the answer runs.
  assert.equal(html.match(/<script>/g).length, 1);
  assert.doesNotMatch(html, /<script>x<\/script>/);
  assert.doesNotMatch(html, /<img src=x/);
  assert.match(html, /&lt;i&gt;Title&lt;\/i&gt;/);
  assert.match(html, /<title>&lt;i&gt;Title&lt;\/i&gt;<\/title>/);
});

test("the page's script is exactly the allowed one", () => {
  const html = answerPage({ lang: "", created: 0, updated: 0, turns: [{ question: "q", answer: "> a", sources: [], images: [] }] },
    { url: "https://roko.test/a/abcdefghij", appURL: "/" });
  assert.ok(html.includes(`<script>${PICTURE_SCRIPT}</script>`));
});

test("plain text for previews", () => {
  assert.equal(plain("It runs **from** [here](https://a.b)"), "It runs from here");
});
