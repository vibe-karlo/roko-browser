import { LaunchProps, showHUD, showToast, Toast } from "@raycast/api";
import { newID, now, put, write } from "./sync";
import { dayString, parseTodo } from "./when";

/** "call the dentist tomorrow at 15" from the root search. */
export default async function Command(props: LaunchProps<{ arguments: { title: string } }>) {
  const todo = parseTodo(props.arguments.title);
  if (!todo.title) return;
  try {
    await write([put("todo", newID(), { ...todo, created: now() })]);
    const when = todo.day === dayString(0) ? "today" : todo.day === dayString(1) ? "tomorrow" : todo.day ? todo.day : "someday";
    await showHUD(`${todo.title}, ${when}${todo.time ? ` at ${todo.time}` : ""}`);
  } catch (error) {
    await showToast({ style: Toast.Style.Failure, title: "Not added", message: error instanceof Error ? error.message : String(error) });
  }
}
