import { getFrontmostApplication } from "@raycast/api";
import { runAppleScript } from "@raycast/utils";

/** Browsers whose front tab can be read, and how. */
const FRONT_TAB: Record<string, string> = {
  "com.apple.Safari": 'tell application "Safari" to return (URL of front document) & "\\n" & (name of front document)',
  "com.google.Chrome": 'tell application "Google Chrome" to return (URL of active tab of front window) & "\\n" & (title of active tab of front window)',
  "company.thebrowser.Browser": 'tell application "Arc" to return (URL of active tab of front window) & "\\n" & (title of active tab of front window)',
  "com.brave.Browser": 'tell application "Brave Browser" to return (URL of active tab of front window) & "\\n" & (title of active tab of front window)',
  "com.microsoft.edgemac": 'tell application "Microsoft Edge" to return (URL of active tab of front window) & "\\n" & (title of active tab of front window)',
};

/** The link given, or the tab in front, with its title when the browser says it. */
export async function pageToSend(link?: string) {
  let url = link?.trim() ?? "";
  let title = "";
  if (!url) {
    const front = await getFrontmostApplication();
    const script = front.bundleId ? FRONT_TAB[front.bundleId] : undefined;
    if (!script) throw new Error(`Open a page in Safari, Chrome, Arc, Brave or Edge first, or give a link.`);
    [url, title = ""] = (await runAppleScript(script)).split("\n");
  }
  if (!/^https?:\/\//i.test(url)) url = `https://${url}`;
  const parsed = new URL(url);
  return { url: parsed.href, title, host: parsed.hostname.replace(/^www\./, "") };
}
