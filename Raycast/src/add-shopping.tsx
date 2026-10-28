import { LaunchProps, showHUD, showToast, Toast } from "@raycast/api";
import { addShopping, readAll, splitItems } from "./sync";

/** "milk, eggs and bread" from the root search: each thing onto the list roko would put it on. */
export default async function Command(props: LaunchProps<{ arguments: { items: string } }>) {
  try {
    const titles = splitItems(props.arguments.items);
    const { shopping } = await readAll();
    const { added, already } = await addShopping(titles, shopping);
    await showHUD(added.length ? `Added ${added.join(", ")}` : already ? "Already on the list" : "Nothing to add");
  } catch (error) {
    await showToast({ style: Toast.Style.Failure, title: "Not added", message: error instanceof Error ? error.message : String(error) });
  }
}
