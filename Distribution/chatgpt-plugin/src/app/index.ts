import { App, applyDocumentTheme, applyHostStyleVariables } from "@modelcontextprotocol/ext-apps";
import { OpenAIExtensions } from "@openai/mcp-extensions/app";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";

const app = new App({ name: "lokalbot-library", version: "0.1.0" });
const extensions = new OpenAIExtensions(app);
const content = document.querySelector<HTMLElement>("#content")!;
const status = document.querySelector<HTMLElement>("#status")!;
const input = document.querySelector<HTMLInputElement>("#query")!;
let activeView = "meetings";
let requestVersion = 0;

type Row = Record<string, unknown>;
const record = (value: unknown): Row => value && typeof value === "object" && !Array.isArray(value) ? value as Row : {};
const rows = (value: unknown): Row[] => Array.isArray(value) ? value.map(record) : [];
const text = (value: unknown): string => typeof value === "string" || typeof value === "number" ? String(value) : "";
const date = (value: unknown) => {
  const parsed = new Date(text(value));
  return Number.isNaN(parsed.valueOf()) ? text(value) : parsed.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
};
function element<K extends keyof HTMLElementTagNameMap>(tag: K, value = "", className = "") {
  const node = document.createElement(tag);
  node.textContent = value;
  node.className = className;
  return node;
}
function message(value: string, error = false) {
  status.textContent = value;
  status.setAttribute("role", error ? "alert" : "status");
}
function theme(context: ReturnType<App["getHostContext"]>) {
  if (context?.theme) applyDocumentTheme(context.theme);
  if (context?.styles?.variables) applyHostStyleVariables(context.styles.variables);
}
function button(label: string, action: () => void | Promise<void>) {
  const node = element("button", label, "btn btn-secondary");
  node.type = "button";
  node.onclick = () => { void Promise.resolve(action()).catch(() => message("Could not complete that action. Try again.", true)); };
  return node;
}
function row(title: string, subtitle: string, detail?: string, action?: () => void) {
  const node = action ? element("button", "", "row") : element("article", "", "row");
  if (node instanceof HTMLButtonElement) { node.type = "button"; node.onclick = action!; }
  node.append(element("strong", title), element("p", subtitle, "muted"));
  if (detail) node.append(element("p", detail));
  return node;
}
function readMeeting(id: unknown) { void run("get_meeting", { id: text(id) }); }
function renderActions(items: Row[], target: HTMLElement = content) {
  if (!items.length) target.append(element("p", "No commitments in this selection.", "empty muted"));
  for (const item of items) {
    const sources = rows(item.meetings);
    const source = sources[0];
    const due = item.due_date ? date(item.due_date) : text(item.due);
    const node = row(text(item.text), [text(item.owner) || "Unassigned", text(item.status), due ? `Due ${due}` : "", item.overdue ? "Overdue" : ""].filter(Boolean).join(" · "));
    // Each source remains selectable, including commitments repeated across meetings.
    for (const reference of sources) {
      node.append(button(`${text(reference.title)} · ${date(reference.date)}`, () => readMeeting(reference.id)));
    }
    if (!source) node.append(element("p", "No source meeting provided", "muted"));
    target.append(node);
  }
}
function render(result: CallToolResult) {
  content.replaceChildren();
  if (result.isError) {
    message(result.content.filter(item => item.type === "text").map(item => item.text).join("\n") || "The library is unavailable.", true);
    return;
  }
  const data = record(result.structuredContent);
  const view = text(data.view);
  activeView = view === "person" ? "people" : view === "meeting" || view === "search" ? "meetings" : view;
  document.querySelectorAll<HTMLButtonElement>("[data-view]").forEach(node => {
    node.setAttribute("aria-pressed", String(node.dataset.view === activeView));
  });
  document.querySelector<HTMLElement>("#search")!.hidden = activeView !== "meetings";
  message("");
  if (view === "meeting") {
    const actions = element("div", "", "detail-actions");
    actions.append(button("Back to meetings", () => run("list_meetings")));
    actions.append(button("Use meeting in chat", async () => {
      const context = { content: [{ type: "text" as const, text: `Selected LokalBot meeting: ${text(data.resource_uri)} (id ${text(data.id)}). Read this source when answering about the meeting.` }] };
      if (extensions.modelContext) await extensions.modelContext.update(context);
      else await app.updateModelContext(context);
      message("Meeting selected as context for this conversation.");
    }));
    content.append(actions);
    const documentView = element("article", "", "document");
    // Render source text as text nodes. Meeting HTML, images, and scripts never execute.
    for (const line of text(data.markdown).split("\n")) {
      if (!line.trim()) continue;
      const heading = /^(#{1,3})\s+(.+)$/.exec(line);
      documentView.append(heading ? element(heading[1] === "#" ? "h2" : "h3", heading[2]) : element("p", line));
    }
    content.append(documentView);
    return;
  }
  if (view === "person") {
    const person = record(data.data);
    content.append(button("Back to people", () => run("list_people")), element("h2", text(person.name), "section-heading"));
    content.append(element("h3", "You owe", "section-heading"));
    renderActions(rows(person.you_owe));
    content.append(element("h3", "They owe", "section-heading"));
    renderActions(rows(person.they_owe));
    content.append(element("h3", "Recent decisions", "section-heading"));
    for (const decision of rows(person.decisions)) {
      content.append(row(text(decision.text), `${text(decision.meeting_title)} · ${date(decision.date)}`, undefined, () => readMeeting(decision.meeting_id)));
    }
    content.append(element("h3", "Shared meetings", "section-heading"));
    for (const meeting of rows(person.meetings)) {
      content.append(row(text(meeting.title), date(meeting.date), undefined, () => readMeeting(meeting.id)));
    }
    return;
  }
  const items = rows(data.data);
  if (view === "actions") { renderActions(items); return; }
  message(`${items.length} ${view === "search" ? "matching excerpts" : view === "people" ? "people" : "recent meetings"}`);
  if (!items.length) content.append(element("p", view === "search" ? "No matching meetings. Try a project name or a phrase you remember." : "Nothing here yet. Refresh after saving meetings in LokalBot.", "empty muted"));
  for (const item of items) {
    if (view === "meetings") content.append(row(text(item.title), `${date(item.date)} · ${Math.round(Number(item.duration_seconds) / 60)} min`, undefined, () => readMeeting(item.uuid)));
    if (view === "search") content.append(row(text(item.meeting_title), [text(item.match_kind), text(item.timestamp)].filter(Boolean).join(" · "), text(item.snippet), () => readMeeting(item.meeting_id)));
    if (view === "people") content.append(row(text(item.name), `${text(item.meeting_count)} meetings · You owe ${text(item.you_owe)} · They owe ${text(item.they_owe)}`, undefined, () => { void run("get_person", { person: text(item.id) }); }));
  }
}

async function run(name: string, args: Record<string, unknown> = {}) {
  const version = ++requestVersion;
  content.replaceChildren();
  message("Loading…");
  try {
    const result = await app.callServerTool({ name, arguments: args });
    if (version === requestVersion) render(result);
  } catch {
    if (version === requestVersion) message("Could not reach LokalBot. Check that your Mac and plugin connection are available, then refresh.", true);
  }
}
const toolForView = () => activeView === "actions" ? "get_action_items" : activeView === "people" ? "list_people" : "list_meetings";
document.querySelector<HTMLFormElement>("#search")!.onsubmit = event => {
  event.preventDefault();
  void run(input.value.trim() ? "search_meetings" : "list_meetings", input.value.trim() ? { query: input.value.trim() } : {});
};
document.querySelector<HTMLButtonElement>("#refresh")!.onclick = () => { void run(toolForView()); };
document.querySelectorAll<HTMLButtonElement>("[data-view]").forEach(node => {
  node.onclick = () => { activeView = node.dataset.view!; void run(toolForView()); };
});
app.ontoolresult = result => { ++requestVersion; render(result); };
app.addEventListener("hostcontextchanged", theme);
try {
  await app.connect();
  theme(app.getHostContext());
} catch {
  message("Open this panel from the LokalBot plugin in a compatible MCP Apps client.", true);
}
