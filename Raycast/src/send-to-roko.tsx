import { LaunchProps, showHUD, showToast, Toast } from "@raycast/api";
import { pageToSend } from "./frontTab";
import { newID, put, write } from "./sync";

/** A link, or the tab in front, waiting for roko on the iPhone: it opens as a tab next time roko is open. */
export default async function Command(props: LaunchProps<{ arguments: { link?: string } }>) {
  try {
    const page = await pageToSend(props.arguments.link);
    await write([put("link", newID(), { url: page.url, title: page.title || page.host })]);
    await showHUD(`Sent to roko: ${page.title || page.host}`);
  } catch (error) {
    await showToast({ style: Toast.Style.Failure, title: "Not sent", message: error instanceof Error ? error.message : String(error) });
  }
}
