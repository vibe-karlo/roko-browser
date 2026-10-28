import { LaunchProps, showHUD, showToast, Toast } from "@raycast/api";
import { pageToSend } from "./frontTab";
import { laterID, now, put, readAll, write } from "./sync";

/** The tab in front (or a link) onto roko's Read Later. roko on the iPhone reads its text when it arrives, for Summarize all. */
export default async function Command(props: LaunchProps<{ arguments: { link?: string } }>) {
  try {
    const page = await pageToSend(props.arguments.link);
    const { later } = await readAll();
    if (later.some((saved) => saved.data.url === page.url)) {
      await showHUD("Already in Read Later");
      return;
    }
    await write([put("later", laterID(), { url: page.url, title: page.title || page.host, site: page.host, saved: now() })]);
    await showHUD(`Saved to Read Later: ${page.title || page.host}`);
  } catch (error) {
    await showToast({ style: Toast.Style.Failure, title: "Not saved", message: error instanceof Error ? error.message : String(error) });
  }
}
