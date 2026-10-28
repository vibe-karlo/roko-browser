import { showToast, Toast } from "@raycast/api";
import { useCallback, useEffect, useRef, useState } from "react";
import { readAll, write } from "./sync";

type Space = Awaited<ReturnType<typeof readAll>>;
type Changes = Parameters<typeof write>[0];

/** While open, as often as roko on the iPhone asks: changes there show here within seconds. */
const POLL_MS = 4000;

/**
 * The space, kept fresh while the command is open. `change` shows a change at
 * once (as `preview` says it will look) and writes it; if writing fails, the
 * list goes back to what the server has.
 */
export function useSpace() {
  const [space, setSpace] = useState<Space>();
  const [error, setError] = useState<string>();
  const writing = useRef(0);

  const reload = useCallback(async () => {
    try {
      const read = await readAll();
      // A read that started before a write finished would undo it on screen.
      if (writing.current === 0) setSpace(read);
      setError(undefined);
    } catch (thrown) {
      setError(thrown instanceof Error ? thrown.message : String(thrown));
    }
  }, []);

  useEffect(() => {
    reload();
    const timer = setInterval(reload, POLL_MS);
    return () => clearInterval(timer);
  }, [reload]);

  const change = useCallback(
    async (changes: Changes, preview: (space: Space) => Space) => {
      writing.current += 1;
      setSpace((current) => (current ? preview(current) : current));
      try {
        await write(changes);
      } catch (thrown) {
        await showToast({ style: Toast.Style.Failure, title: "Not saved", message: thrown instanceof Error ? thrown.message : String(thrown) });
      } finally {
        writing.current -= 1;
        await reload();
      }
    },
    [reload],
  );

  return { space, error, isLoading: !space && !error, reload, change };
}
