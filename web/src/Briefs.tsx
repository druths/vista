import { useCallback, useEffect, useRef, useState } from "react";
import {
  type Brief,
  type Briefing,
  type SortField,
  type SortOrder,
  fetchBriefFile,
  listBriefs,
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

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    listBriefs(briefing.id, sort, order)
      .then((body) => {
        if (cancelled) return;
        setBriefs(body.briefs);
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

  // Selecting a different briefing should not leave the previous brief open.
  useEffect(() => setSelected(null), [briefing.id]);

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
          {loading ? "Loading…" : `${briefs.length} brief${briefs.length === 1 ? "" : "s"}`}
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
      </div>

      <div className="content">
        <BriefList briefs={briefs} loading={loading} briefing={briefing} onOpen={setSelected} />
      </div>
    </>
  );
}

function BriefList({
  briefs,
  loading,
  briefing,
  onOpen,
}: {
  briefs: Brief[];
  loading: boolean;
  briefing: Briefing;
  onOpen: (brief: Brief) => void;
}) {
  if (loading) return <div className="empty">Loading briefs…</div>;
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

  // A briefing is usually one recurring document, so every row carries the
  // same title and the date is what actually distinguishes them. Detect that
  // and promote the date rather than printing the title ten times.
  const seriesTitle =
    briefs.length > 1 && new Set(briefs.map((b) => b.title)).size === 1
      ? briefs[0].title
      : null;

  return (
    <div className="brief-list scroll">
      {briefs.map((brief) => (
        <button key={brief.key} className="row" onClick={() => onOpen(brief)}>
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
