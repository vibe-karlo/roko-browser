# roko for Raycast

Your roko to-dos, shopping lists and Read Later on the Mac, kept the same as on the iPhone,
and links sent to roko to open there.

| Command | What it does |
| --- | --- |
| Shopping List | The three lists (Groceries, Drugstore, Pharmacy), by aisle. Type to add ("milk, eggs and bread" is three); Return ticks off; ⌘M moves to another shop; ⌃X deletes. |
| Add to Shopping | From the root search: things go on the list roko would put them on. |
| To-dos | Overdue, Today, Tomorrow, This week, Later, Someday. Type to add ("call the dentist tomorrow at 15"); Return ticks off; ⌘M moves to another day. |
| Add To-do | From the root search, the same phrasing. |
| Read Later | What you saved, to read first, then read. Return opens it and marks it read; ⌘U marks it read or not; ⌘O opens it in roko on the iPhone; ⌃X removes it. |
| Save for Later | The front tab (or a link you give) onto Read Later. roko on the iPhone reads its text when it arrives, for its summaries. |
| Send to roko | The front tab in Safari, Chrome, Arc, Brave or Edge (or a link you give) opens as a tab in roko on the iPhone, next time roko is open. |

Things added here have no aisle until roko on the iPhone sorts them, a few seconds after
it next syncs. Both sides ask every four seconds while open.

## Set up

1. On the iPhone: roko → Settings → Sync with your Mac → Turn On → Copy Key.
2. Here: `npm install && npm run dev`. Raycast opens the extension; paste the key into its
   preferences, and set Server to roko's server (the one in `SHARE_SERVER`).

Sync goes through roko's server (`Server/share`, `src/sync.js`). See the main README.
