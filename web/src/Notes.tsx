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
} from "./api";
import { formatRelative } from "./format";
import { SortControls } from "./SortControls";

const AUTOSAVE_MS = 900;

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

  return (
    <>
      <div className="topbar">
        <h1>Notes</h1>
        <span className="row-meta">
          {loading ? "Loading…" : `${notes.length} note${notes.length === 1 ? "" : "s"}`}
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
          {loading ? (
            <div className="empty">Loading…</div>
          ) : notes.length === 0 ? (
            <div className="empty">
              <strong>No notes yet</strong>
              <span>Capture something with “New note”.</span>
            </div>
          ) : (
            notes.map((note) => (
              <button
                key={note.name}
                className={`note-row ${note.name === openName ? "selected" : ""}`}
                onClick={() => setOpenName(note.name)}
              >
                <span className="note-row-title">{note.title}</span>
                {note.preview && <span className="note-row-preview">{note.preview}</span>}
                <span className="note-row-date">{formatRelative(note.modified)}</span>
              </button>
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
        void onChanged();
      } catch (error) {
        setState("error");
        onError((error as Error).message);
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
    };
  }, []);

  const latest = useRef(content);
  latest.current = content;
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
    state === "saving" ? "Saving…" : state === "dirty" ? "Unsaved" : state === "error" ? "Save failed" : "Saved";

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
