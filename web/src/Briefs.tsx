import { useCallback, useEffect, useRef, useState } from "react";
import {
  type Brief,
  type Briefing,
  type SortField,
  type SortOrder,
  fetchBriefFile,
  listBriefs,
  markBriefsRead,
} from "./api";
import { formatDate, formatSize } from "./format";
import { SortControls } from "./SortControls";

type Props = {
  briefing: Briefing;
  onError: (message: string) => void;
};

export function BriefsScreen({ briefing, onError }: Props) {
  const [briefs, setBriefs] = useState<Brief[]>([]);
  const [selected, setSelected] = useState<Brief | null>(null);
  const [sort, setSort] = useState<SortField>("date");
  const [order, setOrder] = useState<SortOrder>("desc");
  const [loading, setLoading] = useState(true);
  const [unread, setUnread] = useState(0);
  // Unread by default: a briefing is a stream you work through, so what's
  // left to read is the useful view.
  const [filter, setFilter] = useState<"unread" | "all">("unread");

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    listBriefs(briefing.id, sort, order)
      .then((body) => {
        if (cancelled) return;
        setBriefs(body.briefs);
        setUnread(body.unread ?? 0);
        // Keep the open brief selected across a re-sort or refresh.
        setSelected((current) =>
          current ? body.briefs.find((b) => b.key === current.key) ?? null : null,
        );
      })
      .catch((error) => !cancelled && onError(error.message))
      .finally(() => !cancelled && setLoading(false));
    return () => {
      cancelled = true;
    };
  }, [briefing.id, sort, order, onError]);

  // A briefing is usually one recurring document, so every row carries the
  // same title and the date is what distinguishes them. Decided from the full
  // set, not the filtered view — one unread brief is still part of a series.
  const seriesTitle =
    briefs.length > 1 && new Set(briefs.map((b) => b.title)).size === 1
      ? briefs[0].title
      : null;

  // Selecting a different briefing should not leave the previous brief open.
  useEffect(() => setSelected(null), [briefing.id]);

  /// Clear a whole briefing at once — everything starts unread, so a new
  /// briefing arrives as a wall of dots.
  async function markAllRead() {
    const keys = briefs.filter((b) => !b.read).map((b) => b.key);
    if (keys.length === 0) return;
    const previousBriefs = briefs;
    const previousUnread = unread;
    setBriefs((current) => current.map((b) => ({ ...b, read: true })));
    setUnread(0);
    try {
      await markBriefsRead(briefing.id, keys, true);
    } catch (error) {
      // Put the dots back rather than leave the list claiming something the
      // server doesn't agree with.
      setBriefs(previousBriefs);
      setUnread(previousUnread);
      onError((error as Error).message);
    }
  }

  /// Toggle one brief, from clicking its dot.
  async function toggleRead(brief: Brief) {
    const next = !brief.read;
    const previousBriefs = briefs;
    const previousUnread = unread;
    setBriefs((current) =>
      current.map((b) => (b.key === brief.key ? { ...b, read: next } : b)),
    );
    setUnread((count) => Math.max(0, count + (next ? -1 : 1)));
    try {
      await markBriefsRead(briefing.id, [brief.key], next);
    } catch (error) {
      setBriefs(previousBriefs);
      setUnread(previousUnread);
      onError((error as Error).message);
    }
  }

  /// Opening a brief marks it read, the way a mail client does. Applied
  /// locally first so the dot clears immediately; read state is held on the
  /// server so it matches on every device.
  async function open(brief: Brief) {
    setSelected(brief);
    if (brief.read) return;
    setBriefs((current) =>
      current.map((b) => (b.key === brief.key ? { ...b, read: true } : b)),
    );
    setUnread((count) => Math.max(0, count - 1));
    try {
      await markBriefsRead(briefing.id, [brief.key], true);
    } catch {
      // Not worth interrupting a read for; the next open marks it again.
    }
  }

  // Reading a brief takes over the whole pane — stacking the list header
  // above the reader header just eats vertical space.
  if (selected) {
    return (
      <div className="content">
        <BriefReader
          brief={selected}
          briefingId={briefing.id}
          onClose={() => setSelected(null)}
          onError={onError}
        />
      </div>
    );
  }

  return (
    <>
      <div className="topbar">
        <h1>{briefing.name}</h1>
        <span className="row-meta">
          {loading
            ? "Loading…"
            : `${briefs.length} brief${briefs.length === 1 ? "" : "s"}` +
              (unread > 0 ? ` · ${unread} unread` : "")}
        </span>
        <div className="spacer" />
        <div className="segmented" role="group" aria-label="Which briefs to show">
          {(["unread", "all"] as const).map((value) => (
            <button
              key={value}
              className={filter === value ? "segment active" : "segment"}
              aria-pressed={filter === value}
              onClick={() => setFilter(value)}
            >
              {value === "unread" ? "Unread" : "All"}
            </button>
          ))}
        </div>
        <SortControls
          sort={sort}
          order={order}
          onChange={(nextSort, nextOrder) => {
            setSort(nextSort);
            setOrder(nextOrder);
          }}
        />
        {unread > 0 && (
          <button className="btn-outline" onClick={() => void markAllRead()}>
            Mark all read
          </button>
        )}
      </div>

      <div className="content">
        <BriefList
          briefs={filter === "unread" ? briefs.filter((b) => !b.read) : briefs}
          loading={loading}
          briefing={briefing}
          onOpen={open}
          onToggleRead={toggleRead}
          filteredToUnread={filter === "unread"}
          onShowAll={() => setFilter("all")}
          seriesTitle={seriesTitle}
        />
      </div>
    </>
  );
}

function BriefList({
  briefs,
  loading,
  briefing,
  onOpen,
  onToggleRead,
  filteredToUnread,
  onShowAll,
  seriesTitle,
}: {
  briefs: Brief[];
  loading: boolean;
  briefing: Briefing;
  onOpen: (brief: Brief) => void;
  onToggleRead: (brief: Brief) => void;
  filteredToUnread: boolean;
  onShowAll: () => void;
  seriesTitle: string | null;
}) {
  if (loading) return <div className="empty">Loading briefs…</div>;
  if (briefs.length === 0 && filteredToUnread) {
    // Nothing unread isn't the same as nothing here — say which it is, and
    // offer the way out of the filter.
    return (
      <div className="empty">
        <strong>Nothing unread</strong>
        <span>You're up to date in {briefing.name}.</span>
        <button className="btn-outline" onClick={onShowAll}>
          Show all briefs
        </button>
      </div>
    );
  }
  if (briefs.length === 0) {
    return (
      <div className="empty">
        <strong>No briefs here yet</strong>
        <span>
          Vista is looking in <code>{briefing.path}</code> in the agent’s workspace.
        </span>
      </div>
    );
  }

  return (
    <div className="brief-list scroll">
      {briefs.map((brief) => (
        <div key={brief.key} className="row">
          {/* Mail's convention: a dot on the left, and clicking it toggles
              read. The space stays reserved once read so titles don't shift. */}
          <button
            className={`row-dot ${brief.read ? "" : "unread"}`}
            title={brief.read ? "Mark as unread" : "Mark as read"}
            aria-label={brief.read ? "Mark as unread" : "Mark as read"}
            onClick={() => onToggleRead(brief)}
          />
          <button className="row-main" onClick={() => onOpen(brief)}>
          {seriesTitle ? (
            <span
              className="row-date-lead"
              title={
                brief.date_source === "mtime"
                  ? "Date taken from the file's last-modified time"
                  : "Date taken from the filename"
              }
            >
              {formatDate(brief.date)}
              {brief.date_source === "mtime" && " ~"}
            </span>
          ) : (
            <span className="row-title">{brief.title}</span>
          )}
          {brief.folder && <span className="row-folder">{brief.folder}</span>}
          {brief.annotated && <span className="badge">Marked up</span>}
          <span className="spacer" />
          <span className="row-meta">{formatSize(brief.size)}</span>
          {!seriesTitle && (
            <span
              className="row-meta"
              title={
                brief.date_source === "mtime"
                  ? "Date taken from the file's last-modified time"
                  : "Date taken from the filename"
              }
            >
              {formatDate(brief.date)}
              {brief.date_source === "mtime" && " ~"}
            </span>
          )}
          </button>
        </div>
      ))}
    </div>
  );
}

function BriefReader({
  brief,
  briefingId,
  onClose,
  onError,
}: {
  brief: Brief;
  briefingId: number;
  onClose: () => void;
  onError: (message: string) => void;
}) {
  const [url, setUrl] = useState<string | null>(null);
  const [text, setText] = useState<string | null>(null);
  const [showOriginal, setShowOriginal] = useState(false);
  const objectUrl = useRef<string | null>(null);

  const path =
    showOriginal && brief.pdf_path ? brief.pdf_path : brief.primary_path ?? brief.pdf_path;

  const release = useCallback(() => {
    if (objectUrl.current) {
      URL.revokeObjectURL(objectUrl.current);
      objectUrl.current = null;
    }
  }, []);

  useEffect(() => {
    if (!path) return;
    let cancelled = false;
    setUrl(null);
    setText(null);

    fetchBriefFile(briefingId, path)
      .then(async ({ url: next, blob }) => {
        if (cancelled) {
          URL.revokeObjectURL(next);
          return;
        }
        release();
        if (path.toLowerCase().endsWith(".pdf")) {
          objectUrl.current = next;
          setUrl(next);
        } else {
          // Markdown/text briefs render inline rather than in a PDF viewer.
          URL.revokeObjectURL(next);
          setText(await blob.text());
        }
      })
      .catch((error) => !cancelled && onError(error.message));

    return () => {
      cancelled = true;
    };
  }, [briefingId, path, release, onError]);

  // Revoke the blob when the reader unmounts, not just when the path changes.
  useEffect(() => release, [release]);

  return (
    <div className="pane">
      <div className="pane-head">
        <button className="btn-outline" onClick={onClose}>
          ← Briefs
        </button>
        <h2>{brief.title}</h2>
        <span className="row-meta">{formatDate(brief.date)}</span>
        <div className="spacer" />
        {brief.annotated && brief.pdf_path && (
          <button className="btn-outline" onClick={() => setShowOriginal((v) => !v)}>
            {showOriginal ? "Show markup" : "Show original"}
          </button>
        )}
      </div>

      {text !== null ? (
        <div className="text-brief scroll">
          <pre style={{ whiteSpace: "pre-wrap", fontFamily: "inherit", margin: 0 }}>{text}</pre>
        </div>
      ) : url ? (
        <iframe className="viewer" src={url} title={brief.title} />
      ) : (
        <div className="empty">Opening…</div>
      )}
    </div>
  );
}
