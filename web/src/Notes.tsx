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
const PREVIEW_CHARS = 200;

/**
 * The note's first markdown heading, or "" if it has none.
 *
 * Renaming a note almost always means making the filename match the heading
 * already written at the top of it, so that's the better default than the
 * name being replaced.
 */
function headingOf(content: string): string {
  for (const raw of content.split("\n")) {
    const line = raw.trim();
    if (!line.startsWith("#")) continue;
    const heading = line.replace(/^#+\s*/, "").trim();
    if (heading) return heading;
  }
  return "";
}

/**
 * Mirrors the server's `preview_of`.
 *
 * The server builds previews by opening every note, which is why a full
 * listing is slow. After an edit the content is already here, so the row can
 * be kept honest without asking for the whole list again.
 */
function previewOf(content: string, title: string): string {
  const lines: string[] = [];
  for (const raw of content.split("\n")) {
    let line = raw.trim();
    if (!line) continue;
    line = line
      .replace(/^#{1,6}\s*/, "")
      .replace(/^[-*+]\s+/, "")
      .replace(/^>\s*/, "")
      .replace(/[*_`]/g, "");
    if (!line) continue;
    // A heading that only restates the title is shown beside it already.
    if (lines.length === 0 && line.toLowerCase() === title.trim().toLowerCase()) continue;
    lines.push(line);
    if (lines.join(" ").length > PREVIEW_CHARS) break;
  }
  const joined = lines.join(" ");
  return joined.length > PREVIEW_CHARS
    ? `${joined.slice(0, PREVIEW_CHARS).trimEnd()}…`
    : joined;
}
/** Backoff ceiling for retrying a failed save. */
const RETRY_CAP_MS = 300_000;

type SaveState = "saved" | "dirty" | "saving" | "error";

/** Inline so they inherit the theme's colour and need no icon dependency. */
const icons = {
  back: "M15 18l-6-6 6-6",
  expand: "M8 3H3v5M16 3h5v5M21 16v5h-5M3 16v5h5",
  collapse: "M8 3v5H3M16 3v5h5M21 16h-5v5M3 16h5v5",
  preview: "M1 12s4-7 11-7 11 7 11 7-4 7-11 7-11-7-11-7zM12 15a3 3 0 100-6 3 3 0 000 6z",
  edit: "M12 20h9M16.5 3.5a2.1 2.1 0 013 3L7 19l-4 1 1-4z",
  rename: "M4 7V5h16v2M9 19h6M12 5v14",
  save: "M19 21H5a2 2 0 01-2-2V5a2 2 0 012-2h11l5 5v11a2 2 0 01-2 2zM17 21v-8H7v8M7 3v5h8",
  trash: "M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6M10 11v6M14 11v6",
} as const;

function Icon({ path }: { path: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8"
         strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d={path} />
    </svg>
  );
}

function IconButton({
  label,
  path,
  onClick,
  disabled,
  danger,
}: {
  label: string;
  path: string;
  onClick: () => void;
  disabled?: boolean;
  danger?: boolean;
}) {
  return (
    <button
      className={`icon-button ${danger ? "danger" : ""}`}
      // Hover text and the accessible name are the same thing here: the icon
      // alone doesn't say what it does.
      title={label}
      aria-label={label}
      onClick={onClick}
      disabled={disabled}
    >
      <Icon path={path} />
    </button>
  );
}

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

  /// Every mutation below updates the list in place. Each response already
  /// says exactly what changed, and re-pulling the list means the server
  /// reopening every note to rebuild previews.
  const applySaved = useCallback((noteName: string, content: string) => {
    setNotes((current) =>
      current.map((note) =>
        note.name === noteName
          ? { ...note, modified: new Date().toISOString(), preview: previewOf(content, note.title) }
          : note,
      ),
    );
  }, []);

  const applyRenamed = useCallback(
    (previousName: string, renamed: { name: string; title: string }) => {
      setNotes((current) =>
        current.map((note) =>
          note.name === previousName
            ? { ...note, name: renamed.name, title: renamed.title }
            : note,
        ),
      );
      setOpenName(renamed.name);
    },
    [],
  );

  const applyDeleted = useCallback((noteName: string) => {
    setNotes((current) => current.filter((note) => note.name !== noteName));
  }, []);

  async function handleNew() {
    try {
      const created = await createNote("", "");
      // Insert the row rather than re-listing; the response says all the list
      // needs to know.
      setNotes((current) => [
        {
          name: created.name,
          title: created.title,
          path: "",
          size: 0,
          modified: new Date().toISOString(),
          preview: "",
          starred: false,
        },
        ...current,
      ]);
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
            onSaved={applySaved}
            onRenamed={applyRenamed}
            onDeleted={applyDeleted}
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
  onSaved,
  onRenamed,
  onDeleted,
  onError,
}: {
  name: string;
  onClose: () => void;
  onSaved: (name: string, content: string) => void;
  onRenamed: (previousName: string, renamed: { name: string; title: string }) => void;
  onDeleted: (name: string) => void;
  onError: (message: string) => void;
}) {
  const [content, setContent] = useState("");
  const [title, setTitle] = useState("");
  const [state, setState] = useState<SaveState>("saved");
  const [preview, setPreview] = useState(false);
  const [expanded, setExpanded] = useState(false);
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
        onSaved(name, next);
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
    [name, onSaved, onError],
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

  // Escape is what people reach for to leave a full-window view.
  useEffect(() => {
    if (!expanded) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") setExpanded(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [expanded]);

  async function handleRename() {
    const next = window.prompt("Rename note", headingOf(content) || title);
    if (!next || next === title) return;
    try {
      const renamed = await renameNote(name, next);
      setTitle(renamed.title);
      onRenamed(name, renamed);
    } catch (error) {
      onError((error as Error).message);
    }
  }

  async function handleDelete() {
    if (!window.confirm(`Delete “${title}”? This removes the file from the workspace.`)) return;
    try {
      await deleteNote(name);
      onDeleted(name);
      onClose();
    } catch (error) {
      onError((error as Error).message);
    }
  }

  // Short text that doesn't change the header's size as it cycles; the full
  // wording is on hover.
  const status = {
    saved: { short: "Saved", full: "Saved", tone: "" },
    dirty: { short: "Unsaved", full: "Unsaved changes", tone: "pending" },
    saving: { short: "Saving", full: "Saving…", tone: "pending" },
    error: { short: "Retrying", full: "Save failed — retrying", tone: "failed" },
  }[state];

  return (
    <div className={`pane ${expanded ? "expanded" : ""}`}>
      <div className="editor-head">
        {/* Its own line, never wrapping. Sharing a row with the status text
            meant either one changing length reflowed the header and bumped
            the whole pane. */}
        <h2 className="editor-title" title={title}>
          {title}
        </h2>
        <div className="editor-toolbar">
          <IconButton label="Back to notes" path={icons.back} onClick={onClose} />
          <IconButton
            label={expanded ? "Collapse (Esc)" : "Expand to fill the window"}
            path={expanded ? icons.collapse : icons.expand}
            onClick={() => setExpanded((v) => !v)}
          />
          <IconButton
            label={preview ? "Edit" : "Preview"}
            path={preview ? icons.edit : icons.preview}
            onClick={() => setPreview((v) => !v)}
          />
          <IconButton label="Rename note" path={icons.rename} onClick={handleRename} />
          <IconButton
            label="Save now"
            path={icons.save}
            onClick={() => void flush(content)}
            disabled={state === "saving" || state === "saved"}
          />
          <IconButton label="Delete note" path={icons.trash} onClick={handleDelete} danger />
          {/* Last and right-aligned, so its text growing pushes nothing. */}
          <span className={`editor-state ${status.tone}`} title={status.full}>
            <span className="dot" />
            {status.short}
          </span>
        </div>
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
