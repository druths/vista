import { useEffect, useState } from "react";
import { type WorkspaceListing, browseWorkspace } from "./api";

/**
 * Browse the agent's workspace to choose a directory.
 *
 * Configuration paths are easy to mistype and a wrong one just yields an
 * empty screen with no explanation, so picking beats typing.
 */
export function PathPicker({
  initialPath,
  onPick,
  onCancel,
}: {
  initialPath: string;
  onPick: (path: string) => void;
  onCancel: () => void;
}) {
  const [path, setPath] = useState(initialPath);
  const [listing, setListing] = useState<WorkspaceListing | null>(null);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError("");
    browseWorkspace(path)
      .then((body) => !cancelled && setListing(body))
      .catch((err) => {
        if (cancelled) return;
        setError((err as Error).message);
        setListing(null);
      })
      .finally(() => !cancelled && setLoading(false));
    return () => {
      cancelled = true;
    };
  }, [path]);

  return (
    <div className="modal-backdrop" onClick={onCancel}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <h3>Choose a folder</h3>
          <div className="spacer" />
          <button className="btn-outline" onClick={onCancel}>
            Cancel
          </button>
          <button className="btn-primary" onClick={() => onPick(path)} disabled={!path}>
            Use this folder
          </button>
        </div>

        <div className="modal-path">
          <code>{path || "(workspace root)"}</code>
          {listing && (
            <span className="row-meta">
              {listing.pdf_count > 0
                ? `${listing.pdf_count} PDF${listing.pdf_count === 1 ? "" : "s"}`
                : `${listing.file_count} file${listing.file_count === 1 ? "" : "s"}`}
            </span>
          )}
        </div>

        <div className="modal-body scroll">
          {error && <div className="empty">{error}</div>}
          {loading && <div className="empty">Loading…</div>}
          {listing && !loading && (
            <>
              {listing.parent !== null && (
                <button className="picker-row" onClick={() => setPath(listing.parent!)}>
                  ↰ up one level
                </button>
              )}
              {listing.directories.map((dir) => (
                <button
                  key={dir.path}
                  className="picker-row"
                  onClick={() => setPath(dir.path)}
                >
                  {dir.name}
                </button>
              ))}
              {listing.directories.length === 0 && (
                <div className="empty">
                  <span>No subfolders here.</span>
                </div>
              )}
            </>
          )}
        </div>
      </div>
    </div>
  );
}
