import { Action, ActionPanel, Color, Icon, Keyboard, List, showToast, Toast } from "@raycast/api";
import { useState } from "react";
import {
  addShopping, AISLE_ORDER, aisleName, language, now, put, remove, Shop, shopName, SHOPS, ShoppingData, splitItems, Thing,
} from "./sync";
import { useSpace } from "./useSpace";

/** The three lists, as on the iPhone: one shop at a time, in aisle order, bought at the bottom. */
export default function Command() {
  const { space, error, isLoading, change, reload } = useSpace();
  const [shop, setShop] = useState<Shop>("grocery");
  const [search, setSearch] = useState("");

  const items = (space?.shopping ?? []).filter((item) => listOf(item) === shop);
  const open = items.filter((item) => !item.data.done).sort(byAisle);
  const bought = items
    .filter((item) => item.data.done)
    .sort((a, b) => (b.data.doneAt ?? 0) - (a.data.doneAt ?? 0))
    .slice(0, 30);
  const aisles = AISLE_ORDER.map((aisle) => ({ aisle, items: open.filter((item) => (item.data.aisle ?? "other") === aisle) }));
  const sorting = open.filter((item) => !item.data.aisle);
  const typed = splitItems(search);
  const left = (name: Shop) => (space?.shopping ?? []).filter((item) => listOf(item) === name && !item.data.done).length;

  const add = async () => {
    if (!space || typed.length === 0) return;
    const { added, already } = await addShopping(typed, space.shopping, shop);
    setSearch("");
    await reload();
    await showToast({
      style: added.length ? Toast.Style.Success : Toast.Style.Failure,
      title: added.length ? `Added ${added.join(", ")}` : "Already on the list",
      message: already && added.length ? `${already} already on the list` : undefined,
    });
  };

  const toggle = (item: Thing<ShoppingData>) => {
    const done = !item.data.done;
    const data = { ...item.data, done, doneAt: done ? now() : null };
    return change([put("shopping", item.id, data)], (current) => ({
      ...current,
      shopping: current.shopping.map((thing) => (thing.id === item.id ? { ...thing, data } : thing)),
    }));
  };

  const move = (item: Thing<ShoppingData>, to: Shop) => {
    const data = { ...item.data, shop: to, pinned: to };
    return change([put("shopping", item.id, data)], (current) => ({
      ...current,
      shopping: current.shopping.map((thing) => (thing.id === item.id ? { ...thing, data } : thing)),
    }));
  };

  const drop = (ids: string[]) =>
    change(ids.map((id) => remove("shopping", id)), (current) => ({
      ...current,
      shopping: current.shopping.filter((thing) => !ids.includes(thing.id)),
    }));

  const row = (item: Thing<ShoppingData>) => (
    <List.Item
      key={item.id}
      title={item.data.title}
      icon={item.data.done ? { source: Icon.CheckCircle, tintColor: Color.SecondaryText } : Icon.Circle}
      actions={
        <ActionPanel>
          <Action title={item.data.done ? "Put Back on the List" : "Bought"} icon={Icon.Check} onAction={() => toggle(item)} />
          {typed.length > 0 && <Action title={`Add ${typed.join(", ")}`} icon={Icon.Plus} onAction={add} />}
          <ActionPanel.Submenu title="Move to Shop" icon={Icon.ArrowRight} shortcut={{ modifiers: ["cmd"], key: "m" }}>
            {SHOPS.filter((name) => name !== shop).map((name) => (
              <Action key={name} title={shopName(name)} onAction={() => move(item, name)} />
            ))}
          </ActionPanel.Submenu>
          <Action title="Delete" icon={Icon.Trash} style={Action.Style.Destructive} shortcut={Keyboard.Shortcut.Common.Remove} onAction={() => drop([item.id])} />
          {bought.length > 0 && (
            <Action title="Clear Bought" icon={Icon.Eraser} shortcut={Keyboard.Shortcut.Common.RemoveAll} onAction={() => drop(bought.map((thing) => thing.id))} />
          )}
        </ActionPanel>
      }
    />
  );

  return (
    <List
      isLoading={isLoading}
      searchText={search}
      onSearchTextChange={setSearch}
      filtering={false}
      searchBarPlaceholder={`Add to ${shopName(shop)}: milk, eggs and bread`}
      searchBarAccessory={
        <List.Dropdown tooltip="Shop" value={shop} onChange={(value) => setShop(value as Shop)}>
          {SHOPS.map((name) => (
            <List.Dropdown.Item key={name} value={name} title={`${shopName(name)}  ${left(name) || ""}`.trim()} />
          ))}
        </List.Dropdown>
      }
    >
      {error && !space ? (
        <List.EmptyView icon={Icon.WifiDisabled} title="Can't reach roko" description={error} />
      ) : typed.length > 0 ? (
        <List.Item
          title={`Add ${typed.join(", ")}`}
          subtitle={`to ${shopName(shop)}`}
          icon={Icon.Plus}
          actions={
            <ActionPanel>
              <Action title="Add" icon={Icon.Plus} onAction={add} />
            </ActionPanel>
          }
        />
      ) : (
        <>
          <List.EmptyView icon={Icon.Cart} title={`Nothing on ${shopName(shop)}`} description="Type to add things." />
          {sorting.length > 0 && <List.Section title={aisleName(undefined)}>{sorting.map(row)}</List.Section>}
          {aisles.map(({ aisle, items }) =>
            items.length && items.some((item) => item.data.aisle) ? (
              <List.Section key={aisle} title={aisleName(aisle)}>
                {items.filter((item) => item.data.aisle).map(row)}
              </List.Section>
            ) : null,
          )}
          {bought.length > 0 && <List.Section title={language() === "hr" ? "Kupljeno" : "Bought"}>{bought.map(row)}</List.Section>}
        </>
      )}
    </List>
  );
}

/** The list a thing is on; just added here, before roko has sorted it, the one it was added to. */
function listOf(item: Thing<ShoppingData>) {
  return item.data.shop || item.data.pinned || "grocery";
}

function byAisle(a: Thing<ShoppingData>, b: Thing<ShoppingData>) {
  return (a.data.order ?? 0) - (b.data.order ?? 0) || (a.data.created ?? 0) - (b.data.created ?? 0);
}
