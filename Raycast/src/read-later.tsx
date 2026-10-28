import { Action, ActionPanel, Color, Icon, Keyboard, List, open } from "@raycast/api";
import { getFavicon } from "@raycast/utils";
import { LaterData, newID, now, put, remove, Thing } from "./sync";
import { useSpace } from "./useSpace";

/** roko's Read Later, as on the iPhone: what's still to read, newest first, then what's been read. */
export default function Command() {
  const { space, error, isLoading, change } = useSpace();

  const pages = [...(space?.later ?? [])].sort((a, b) => (b.data.saved ?? 0) - (a.data.saved ?? 0));
  const unread = pages.filter((page) => !page.data.read);
  const read = pages.filter((page) => page.data.read);

  const set = (page: Thing<LaterData>, data: LaterData) =>
    change([put("later", page.id, data)], (current) => ({
      ...current,
      later: current.later.map((thing) => (thing.id === page.id ? { ...thing, data } : thing)),
    }));

  const row = (page: Thing<LaterData>) => (
    <List.Item
      key={page.id}
      title={page.data.title}
      subtitle={page.data.site}
      icon={getFavicon(page.data.url, { fallback: Icon.Bookmark })}
      accessories={page.data.saved ? [{ date: new Date(page.data.saved), tooltip: "Saved" }] : []}
      actions={
        <ActionPanel>
          <Action
            title="Open"
            icon={Icon.Globe}
            onAction={async () => {
              await open(page.data.url);
              if (!page.data.read) await set(page, { ...page.data, read: now() });
            }}
          />
          <Action
            title={page.data.read ? "Mark Unread" : "Mark Read"}
            icon={page.data.read ? Icon.Circle : Icon.CheckCircle}
            shortcut={{ modifiers: ["cmd"], key: "u" }}
            onAction={() => set(page, { ...page.data, read: page.data.read ? null : now() })}
          />
          <Action
            title="Open in roko on iPhone"
            icon={Icon.Mobile}
            shortcut={{ modifiers: ["cmd"], key: "o" }}
            onAction={() => change([put("link", newID(), { url: page.data.url, title: page.data.title })], (current) => current)}
          />
          <Action.CopyToClipboard title="Copy Link" content={page.data.url} shortcut={Keyboard.Shortcut.Common.Copy} />
          <Action
            title="Remove"
            icon={Icon.Trash}
            style={Action.Style.Destructive}
            shortcut={Keyboard.Shortcut.Common.Remove}
            onAction={() =>
              change([remove("later", page.id)], (current) => ({ ...current, later: current.later.filter((thing) => thing.id !== page.id) }))
            }
          />
        </ActionPanel>
      }
    />
  );

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search what you saved">
      {error && !space ? (
        <List.EmptyView icon={Icon.WifiDisabled} title="Can't reach roko" description={error} />
      ) : (
        <>
          <List.EmptyView
            icon={{ source: Icon.Bookmark, tintColor: Color.SecondaryText }}
            title="Nothing saved yet"
            description="Save for Later saves the tab in front; on the iPhone, a page's tools or typing read later."
          />
          {unread.length > 0 && <List.Section title="To read" subtitle={String(unread.length)}>{unread.map(row)}</List.Section>}
          {read.length > 0 && <List.Section title="Read">{read.map(row)}</List.Section>}
        </>
      )}
    </List>
  );
}
