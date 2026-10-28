import type { TodoData } from "./sync";

/** A day from today as roko writes it: "2026-10-28". */
export function dayString(offset: number) {
  const date = new Date();
  date.setDate(date.getDate() + offset);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

/**
 * A to-do as typed: "call the dentist tomorrow at 15" is for tomorrow at 15:00,
 * "pay rent someday" for someday, anything else for today. English and Croatian.
 */
export function parseTodo(typed: string): Omit<TodoData, "created"> {
  let title = typed.trim();
  let day: string | null = dayString(0);
  let time: string | null = null;

  const clock = /\s+(?:at|u)\s+(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm)?\s*$/i.exec(title);
  if (clock) {
    let hour = Number(clock[1]);
    if (clock[3]?.toLowerCase() === "pm" && hour < 12) hour += 12;
    if (clock[3]?.toLowerCase() === "am" && hour === 12) hour = 0;
    if (hour < 24) {
      time = `${String(hour).padStart(2, "0")}:${clock[2] ?? "00"}`;
      title = title.slice(0, clock.index).trim();
    }
  }
  const when = /(?:^|\s+)(today|danas|tomorrow|sutra|someday|jednom)$/i.exec(title) ?? /^(today|danas|tomorrow|sutra|someday|jednom)\s+/i.exec(title);
  if (when) {
    const word = when[1].toLowerCase();
    if (word === "tomorrow" || word === "sutra") day = dayString(1);
    if (word === "someday" || word === "jednom") {
      day = null;
      time = null;
    }
    title = (title.slice(0, when.index) + title.slice(when.index + when[0].length)).trim();
  }
  title = title.charAt(0).toLocaleUpperCase() + title.slice(1);
  return { title, day, week: false, time, done: false };
}
