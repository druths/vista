import { useCallback, useEffect, useRef, useState } from "react";
import { marked } from "marked";
import {
  type Note,
  type SortField,
  type SortOrder,
  createNote,
  deleteNote,
  listNotes,
  readNote,
  renameNote,
  saveNote,
  setStarred,
} from "./api";
import { formatRelative } from "./format";
import { SortControls } from "./SortControls";

const AUTOSAVE_MS = 900;
/** Backoff ceiling for retrying a failed save. */
const RETRY_CAP_MS = 300_000;

type SaveState = "saved" | "dirty" | "saving" | "error";

export function NotesScreen({ onError }: { onError: (message: string) => void }) {
  const [notes, setNotes] = useState<Note[]>([]);
  const [sort, setSort] = useState<SortField>("date");
  const [order, setOrder] = useState<SortOrder>("desc");
  const [openName, setOpenName] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const body = await listNotes(sort, order);
      setNotes(body.notes);
      return body.notes;
    } catch (error) {
      onError((error as Error).message);
      return [];
    } finally {
      setLoading(false);
    }
  }, [sort, order, onError]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  async function handleNew() {
    try {
      const created = await createNote("", "");
      await refresh();
      setOpenName(created.name);
    } catch (error) {
      onError((error as Error).message);
    }
  }

  /// Starring is about reach, so starred notes lead regardless of the sort.
  const ordered = [...notes.filter((n) => n.starred), ...notes.filter((n) => !n.starred)];

  async function toggleStar(name: string) {
    const previous = notes;
    const next = notes.map((n) => (n.name === name ? { ...n, starred: !n.starred } : n));
    setNotes(next); // optimistic; the set is small and the call is cheap
    try {
      await setStarred(next.filter((n) => n.starred).map((n) => n.name));
    } catch (error) {
      setNotes(previous);
      onError((error as Error).message);
    }
  }

  return (
    <>
      <div className="topbar">
        <h1>Notes</h1>
        <span className="row-meta">
          {loading && notes.length === 0
            ? "Loading…"
            : `${notes.length} note${notes.length === 1 ? "" : "s"}`}
        </span>
        <div className="spacer" />
        <SortControls
          sort={sort}
          order={order}
          onChange={(nextSort, nextOrder) => {
            setSort(nextSort);
            setOrder(nextOrder);
          }}
        />
        <button className="btn-primary" onClick={handleNew}>
          New note
        </button>
      </div>

      <div className="content">
        <div className={`note-list scroll ${openName ? "hidden" : ""}`}>
          {loading && notes.length === 0 ? (
            <div className="empty">Loading…</div>
          ) : notes.length === 0 ? (
            <div className="empty">
              <strong>No notes yet</strong>
              <span>Capture something with “New note”.</span>
            </div>
          ) : (
            ordered.map((note) => (
              <div
                key={note.name}
                className={`note-row ${note.name === openName ? "selected" : ""}`}
              >
                <button
                  className={`note-star ${note.starred ? "on" : ""}`}
                  aria-pressed={note.starred ?? false}
                  title={note.starred ? "Unstar" : "Star"}
                  onClick={() => void toggleStar(note.name)}
                >
                  {note.starred ? "★" : "☆"}
                </button>
                <button className="note-row-main" onClick={() => setOpenName(note.name)}>
                  <span className="note-row-head">
                    <span className="note-row-title">{note.title}</span>
                    <span className="note-row-date">{formatRelative(note.modified)}</span>
                  </span>
                  {/* A starred note is pinned for reach; a preview would cost a
                      line without helping anyone find it. */}
                  {!note.starred && note.preview && (
                    <span className="note-row-preview">{note.preview}</span>
                  )}
                </button>
              </div>
            ))
          )}
        </div>

        {openName ? (
          <NoteEditor
            key={openName}
            name={openName}
            onClose={() => setOpenName(null)}
            onChanged={refresh}
            onRenamed={setOpenName}
            onError={onError}
          />
        ) : (
          <div className="pane hidden-narrow">
            <div className="empty">
              <strong>Nothing open</strong>
              <span>Pick a note, or create one.</span>
            </div>
          </div>
        )}
      </div>
    </>
  );
}

function NoteEditor({
  name,
  onClose,
  onChanged,
  onRenamed,
  onError,
}: {
  name: string;
  onClose: () => void;
  onChanged: () => Promise<Note[]>;
  onRenamed: (name: string) => void;
  onError: (message: string) => void;
}) {
  const [content, setContent] = useState("");
  const [title, setTitle] = useState("");
  const [state, setState] = useState<SaveState>("saved");
  const [preview, setPreview] = useState(false);
  const [ready, setReady] = useState(false);
  const timer = useRef<number | null>(null);
  // Tracks what's on the server so autosave can skip no-op writes.
  const persisted = useRef("");
  // Latest text, so a retry fired from a timer saves what's on screen now
  // rather than whatever failed earlier.
  const latest = useRef("");
  const retry = useRef<number | null>(null);
  const attempt = useRef(0);

  latest.current = content;

  useEffect(() => {
    let cancelled = false;
    readNote(name)
      .then((note) => {
        if (cancelled) return;
        setContent(note.content);
        setTitle(note.title);
        persisted.current = note.content;
        setState("saved");
        setReady(true);
      })
      .catch((error) => !cancelled && onError(error.message));
    return () => {
      cancelled = true;
    };
  }, [name, onError]);

  const flush = useCallback(
    async (next: string) => {
      if (next === persisted.current) return;
      setState("saving");
      try {
        await saveNote(name, next);
        persisted.current = next;
        setState("saved");
        attempt.current = 0;
        if (retry.current) {
          window.clearTimeout(retry.current);
          retry.current = null;
        }
        void onChanged();
      } catch (error) {
        setState("error");
        // Report the first failure only; a retry loop shouldn't keep raising
        // the same banner.
        if (attempt.current === 0) onError((error as Error).message);
        // Keep trying on a backing-off schedule — 10s, 20s, 40s, up to five
        // minutes — rather than waiting to be noticed.
        attempt.current = Math.min(attempt.current + 1, 6);
        const delay = Math.min(2 ** attempt.current * 5000, RETRY_CAP_MS);
        if (retry.current) window.clearTimeout(retry.current);
        retry.current = window.setTimeout(() => void flush(latest.current), delay);
      }
    },
    [name, onChanged, onError],
  );

  function handleChange(next: string) {
    setContent(next);
    setState("dirty");
    if (timer.current) window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => void flush(next), AUTOSAVE_MS);
  }

  // Save immediately when switching away rather than losing the pending edit.
  useEffect(() => {
    return () => {
      if (timer.current) window.clearTimeout(timer.current);
      if (retry.current) window.clearTimeout(retry.current);
    };
  }, []);

  useEffect(() => {
    return () => {
      if (ready && latest.current !== persisted.current) void flush(latest.current);
    };
  }, [ready, flush]);

  async function handleRename() {
    const next = window.prompt("Rename note", title);
    if (!next || next === title) return;
    try {
      const renamed = await renameNote(name, next);
      setTitle(renamed.title);
      await onChanged();
      onRenamed(renamed.name);
    } catch (error) {
      onError((error as Error).message);
    }
  }

  async function handleDelete() {
    if (!window.confirm(`Delete “${title}”? This removes the file from the workspace.`)) return;
    try {
      await deleteNote(name);
      await onChanged();
      onClose();
    } catch (error) {
      onError((error as Error).message);
    }
  }

  const label =
    state === "saving"
      ? "Saving…"
      : state === "dirty"
        ? "Unsaved"
        : state === "error"
          ? "Save failed — retrying"
          : "Saved";

  return (
    <div className="pane">
      <div className="pane-head">
        <button className="btn-outline" onClick={onClose}>
          ← Notes
        </button>
        <h2>{title}</h2>
        <span className={`save-state ${state === "dirty" || state === "error" ? "dirty" : ""}`}>
          {label}
        </span>
        <div className="spacer" />
        <button
          className="btn-outline"
          onClick={() => void flush(content)}
          disabled={state === "saving" || state === "saved"}
        >
          Save
        </button>
        <button className="btn-outline" onClick={() => setPreview((v) => !v)}>
          {preview ? "Edit" : "Preview"}
        </button>
        <button className="btn-outline" onClick={handleRename}>
          Rename
        </button>
        <button className="btn-danger" onClick={handleDelete}>
          Delete
        </button>
      </div>

      {preview ? (
        <div
          className="preview"
          dangerouslySetInnerHTML={{ __html: marked.parse(content, { async: false }) as string }}
        />
      ) : (
        <textarea
          className="editor"
          value={content}
          placeholder="Start writing…"
          spellCheck
          autoFocus
          onChange={(e) => handleChange(e.target.value)}
        />
      )}
    </div>
  );
}
