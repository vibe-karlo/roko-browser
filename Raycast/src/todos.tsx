import { Action, ActionPanel, Color, Icon, Keyboard, List } from "@raycast/api";
import { useState } from "react";
import { newID, now, put, remove, Thing, TodoData } from "./sync";
import { dayString, parseTodo } from "./when";
import { useSpace } from "./useSpace";

/** The to-dos in the sections roko shows: Overdue, Today, Tomorrow, This week, Later, Someday. */
export default function Command() {
  const { space, error, isLoading, change } = useSpace();
  const [search, setSearch] = useState("");

  const today = dayString(0);
  const tomorrow = dayString(1);
  const open = (space?.todos ?? []).filter((todo) => !todo.data.done).sort(byTime);
  const sections: [string, Thing<TodoData>[]][] = [
    ["Overdue", open.filter((todo) => todo.data.day && todo.data.day < today)],
    ["Today", open.filter((todo) => todo.data.day === today && !todo.data.week)],
    ["Tomorrow", open.filter((todo) => todo.data.day === tomorrow && !todo.data.week)],
    ["This week", open.filter((todo) => todo.data.week && todo.data.day && todo.data.day >= today)],
    ["Later", open.filter((todo) => todo.data.day && todo.data.day > tomorrow && !todo.data.week)],
    ["Someday", open.filter((todo) => !todo.data.day)],
  ];
  const doneToday = (space?.todos ?? []).filter((todo) => todo.data.done && dayOf(todo.data.doneAt) === today);
  const typed = search.trim() ? parseTodo(search) : undefined;

  const set = (todo: Thing<TodoData>, data: TodoData) =>
    change([put("todo", todo.id, data)], (current) => ({
      ...current,
      todos: current.todos.map((thing) => (thing.id === todo.id ? { ...thing, data } : thing)),
    }));

  const add = async () => {
    if (!typed) return;
    const id = newID();
    const data: TodoData = { ...typed, created: now() };
    setSearch("");
    await change([put("todo", id, data)], (current) => ({ ...current, todos: [...current.todos, { id, updated: now(), data }] }));
  };

  const row = (todo: Thing<TodoData>) => (
    <List.Item
      key={todo.id}
      title={todo.data.title}
      icon={todo.data.done ? { source: Icon.CheckCircle, tintColor: Color.SecondaryText } : Icon.Circle}
      accessories={[
        ...(todo.data.time && !todo.data.done ? [{ text: todo.data.time }] : []),
        ...(todo.data.day && todo.data.day < today && !todo.data.done ? [{ text: shortDay(todo.data.day) }] : []),
      ]}
      actions={
        <ActionPanel>
          <Action
            title={todo.data.done ? "Not Done" : "Done"}
            icon={Icon.Check}
            onAction={() => set(todo, { ...todo.data, done: !todo.data.done, doneAt: todo.data.done ? null : now() })}
          />
          {typed && <Action title={`Add "${typed.title}"`} icon={Icon.Plus} onAction={add} />}
          <ActionPanel.Submenu title="Move to" icon={Icon.Calendar} shortcut={{ modifiers: ["cmd"], key: "m" }}>
            <Action title="Today" onAction={() => set(todo, { ...todo.data, day: today, week: false })} />
            <Action title="Tomorrow" onAction={() => set(todo, { ...todo.data, day: tomorrow, week: false })} />
            <Action title="Someday" onAction={() => set(todo, { ...todo.data, day: null, week: false, time: null })} />
          </ActionPanel.Submenu>
          <Action
            title="Delete"
            icon={Icon.Trash}
            style={Action.Style.Destructive}
            shortcut={Keyboard.Shortcut.Common.Remove}
            onAction={() =>
              change([remove("todo", todo.id)], (current) => ({ ...current, todos: current.todos.filter((thing) => thing.id !== todo.id) }))
            }
          />
        </ActionPanel>
      }
    />
  );

  return (
    <List isLoading={isLoading} searchText={search} onSearchTextChange={setSearch} filtering={false} searchBarPlaceholder="Add a to-do: call the dentist tomorrow at 15">
      {error && !space ? (
        <List.EmptyView icon={Icon.WifiDisabled} title="Can't reach roko" description={error} />
      ) : typed ? (
        <List.Item
          title={`Add "${typed.title}"`}
          subtitle={typed.day ? (typed.day === today ? "Today" : typed.day === tomorrow ? "Tomorrow" : shortDay(typed.day)) : "Someday"}
          accessories={typed.time ? [{ text: typed.time }] : []}
          icon={Icon.Plus}
          actions={
            <ActionPanel>
              <Action title="Add" icon={Icon.Plus} onAction={add} />
            </ActionPanel>
          }
        />
      ) : (
        <>
          <List.EmptyView icon={Icon.CheckList} title="Nothing to do" description="Type to add a to-do." />
          {sections.map(([title, todos]) =>
            todos.length ? (
              <List.Section key={title} title={title}>
                {todos.map(row)}
              </List.Section>
            ) : null,
          )}
          {doneToday.length > 0 && <List.Section title="Done today">{doneToday.map(row)}</List.Section>}
        </>
      )}
    </List>
  );
}

function byTime(a: Thing<TodoData>, b: Thing<TodoData>) {
  return (
    (a.data.time ?? "99").localeCompare(b.data.time ?? "99") ||
    (a.data.order ?? 0) - (b.data.order ?? 0) ||
    (a.data.created ?? 0) - (b.data.created ?? 0)
  );
}

function dayOf(milliseconds?: number | null) {
  if (!milliseconds) return undefined;
  const date = new Date(milliseconds);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

function shortDay(day: string) {
  const [year, month, date] = day.split("-").map(Number);
  return new Date(year, month - 1, date).toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" });
}
