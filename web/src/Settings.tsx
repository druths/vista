import { useCallback, useEffect, useState } from "react";
import {
  type Briefing,
  type ConnectionResult,
  type Settings,
  addBriefing,
  getSettings,
  removeBriefing,
  reorderBriefings,
  saveArkConnection,
  saveNotesDir,
  testArkConnection,
  updateBriefing,
} from "./api";
import { PathPicker } from "./PathPicker";

/** Folder names that describe a build step rather than the briefing itself. */
const GENERIC_SEGMENTS = new Set(["output", "outputs", "pdf", "pdfs", "files", "docs", "dist", "build"]);

/**
 * Suggest a briefing name from its path: `briefs/ai_policy/output` reads as
 * "Ai Policy", not "Output".
 */
export function suggestBriefingName(path: string): string {
  const segments = path.split("/").filter(Boolean);
  const meaningful = [...segments].reverse().find((s) => !GENERIC_SEGMENTS.has(s.toLowerCase()));
  const base = meaningful ?? segments[segments.length - 1] ?? "";
  const words = base.replace(/[_-]+/g, " ").trim();
  return words ? words.replace(/\b\w/g, (c) => c.toUpperCase()) : "New briefing";
}

type Picking =
  | { kind: "notes" }
  | { kind: "briefing"; id: number }
  | { kind: "new-briefing" }
  | null;

export function SettingsScreen({
  onChanged,
  onError,
}: {
  /** Settings change the nav and the Ark connection, so the app reloads the
   *  user after every save. */
  onChanged: () => Promise<void>;
  onError: (message: string) => void;
}) {
  const [settings, setSettings] = useState<Settings | null>(null);
  const [picking, setPicking] = useState<Picking>(null);

  const load = useCallback(async () => {
    try {
      setSettings(await getSettings());
    } catch (error) {
      onError((error as Error).message);
    }
  }, [onError]);

  useEffect(() => {
    void load();
  }, [load]);

  const refresh = useCallback(async () => {
    await load();
    await onChanged();
  }, [load, onChanged]);

  if (!settings) return <div className="empty">Loading settings…</div>;

  return (
    <>
      <div className="topbar">
        <h1>Settings</h1>
      </div>

      <div className="settings scroll">
        <ArkSection settings={settings} onSaved={refresh} onError={onError} />

        <NotesSection
          settings={settings}
          onBrowse={() => setPicking({ kind: "notes" })}
          onSaved={refresh}
          onError={onError}
        />

        <BriefingsSection
          settings={settings}
          onBrowse={(id) =>
            setPicking(id === null ? { kind: "new-briefing" } : { kind: "briefing", id })
          }
          onSaved={refresh}
          onError={onError}
        />
      </div>

      {picking && (
        <PathPicker
          initialPath={
            picking.kind === "notes"
              ? settings.notes_dir
              : picking.kind === "briefing"
                ? settings.briefings.find((b) => b.id === picking.id)?.path ?? ""
                : ""
          }
          onCancel={() => setPicking(null)}
          onPick={async (path) => {
            setPicking(null);
            try {
              if (picking.kind === "notes") {
                await saveNotesDir(path);
              } else if (picking.kind === "briefing") {
                const briefing = settings.briefings.find((b) => b.id === picking.id);
                if (briefing) await updateBriefing(briefing.id, briefing.name, path);
              } else {
                const suggested = suggestBriefingName(path);
                const name = window.prompt("Name this briefing", suggested);
                if (!name) return;
                await addBriefing(name, path);
              }
              await refresh();
            } catch (error) {
              onError((error as Error).message);
            }
          }}
        />
      )}
    </>
  );
}

// --- Ark connection --------------------------------------------------------

function ArkSection({
  settings,
  onSaved,
  onError,
}: {
  settings: Settings;
  onSaved: () => Promise<void>;
  onError: (message: string) => void;
}) {
  const [baseUrl, setBaseUrl] = useState(settings.ark.base_url);
  const [agent, setAgent] = useState(settings.ark.agent);
  const [token, setToken] = useState("");
  const [result, setResult] = useState<ConnectionResult | null>(null);
  const [busy, setBusy] = useState(false);

  async function run(action: "test" | "save") {
    setBusy(true);
    setResult(null);
    // A blank token means "keep the stored one" — the server never sends it
    // back, so there is nothing to re-submit.
    const payload = { base_url: baseUrl, agent, ...(token ? { token } : {}) };
    try {
      const outcome =
        action === "test" ? await testArkConnection(payload) : await saveArkConnection(payload);
      setResult(outcome);
      if (action === "save") {
        setToken("");
        await onSaved();
      }
    } catch (error) {
      onError((error as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="card">
      <h2>Ark server</h2>
      <p className="hint">
        Where Vista reads and writes. The token grants full access to the agent’s
        workspace, so it is stored encrypted and never sent back to this page.
      </p>

      <label htmlFor="ark-url">Server URL</label>
      <input
        id="ark-url"
        value={baseUrl}
        placeholder="http://ark:7777"
        onChange={(e) => setBaseUrl(e.target.value)}
      />

      <label htmlFor="ark-agent">Agent</label>
      <input
        id="ark-agent"
        value={agent}
        placeholder="scribe"
        onChange={(e) => setAgent(e.target.value)}
      />

      <label htmlFor="ark-token">Auth token</label>
      <input
        id="ark-token"
        type="password"
        value={token}
        autoComplete="new-password"
        placeholder={settings.ark.token_set ? "•••••••• stored — type to replace" : "Ark auth_secret"}
        onChange={(e) => setToken(e.target.value)}
      />

      <div className="actions">
        <button className="btn-outline" onClick={() => run("test")} disabled={busy || !baseUrl || !agent}>
          Test connection
        </button>
        <button className="btn-primary" onClick={() => run("save")} disabled={busy || !baseUrl || !agent}>
          Save
        </button>
        {result && (
          <span className={result.connected ? "ok" : "bad"}>
            {result.connected ? "✓ " : "✕ "}
            {result.detail}
          </span>
        )}
      </div>
    </section>
  );
}

// --- notes -----------------------------------------------------------------

function NotesSection({
  settings,
  onBrowse,
  onSaved,
  onError,
}: {
  settings: Settings;
  onBrowse: () => void;
  onSaved: () => Promise<void>;
  onError: (message: string) => void;
}) {
  const [dir, setDir] = useState(settings.notes_dir);
  const [busy, setBusy] = useState(false);

  useEffect(() => setDir(settings.notes_dir), [settings.notes_dir]);

  async function save() {
    setBusy(true);
    try {
      await saveNotesDir(dir);
      await onSaved();
    } catch (error) {
      onError((error as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="card">
      <h2>Notes folder</h2>
      <p className="hint">
        Where notes are read and written, relative to the agent’s workspace root.
        Changing this points Vista at a different set of notes; it doesn’t move
        any files.
      </p>
      <div className="path-row">
        <input value={dir} onChange={(e) => setDir(e.target.value)} placeholder="notes" />
        <button className="btn-outline" onClick={onBrowse}>
          Browse…
        </button>
        <button className="btn-primary" onClick={save} disabled={busy || !dir.trim()}>
          Save
        </button>
      </div>
    </section>
  );
}

// --- briefings -------------------------------------------------------------

function BriefingsSection({
  settings,
  onBrowse,
  onSaved,
  onError,
}: {
  settings: Settings;
  onBrowse: (id: number | null) => void;
  onSaved: () => Promise<void>;
  onError: (message: string) => void;
}) {
  return (
    <section className="card">
      <h2>Brief locations</h2>
      <p className="hint">
        Each one becomes its own screen. Briefs are found in the folder and
        anything nested beneath it. Removing a location only unconfigures it —
        no files are deleted.
      </p>

      {settings.briefings.length === 0 && (
        <div className="empty" style={{ padding: "18px 0" }}>
          <span>No brief locations yet.</span>
        </div>
      )}

      {settings.briefings.map((briefing, index) => (
        <BriefingRow
          key={briefing.id}
          briefing={briefing}
          isFirst={index === 0}
          isLast={index === settings.briefings.length - 1}
          onBrowse={() => onBrowse(briefing.id)}
          onSaved={onSaved}
          onError={onError}
          onMove={async (direction) => {
            const ids = settings.briefings.map((b) => b.id);
            const target = index + direction;
            [ids[index], ids[target]] = [ids[target], ids[index]];
            try {
              await reorderBriefings(ids);
              await onSaved();
            } catch (error) {
              onError((error as Error).message);
            }
          }}
        />
      ))}

      <div className="actions">
        <button className="btn-outline" onClick={() => onBrowse(null)}>
          Add brief location…
        </button>
      </div>
    </section>
  );
}

function BriefingRow({
  briefing,
  isFirst,
  isLast,
  onBrowse,
  onSaved,
  onError,
  onMove,
}: {
  briefing: Briefing;
  isFirst: boolean;
  isLast: boolean;
  onBrowse: () => void;
  onSaved: () => Promise<void>;
  onError: (message: string) => void;
  onMove: (direction: 1 | -1) => Promise<void>;
}) {
  const [name, setName] = useState(briefing.name);
  const [path, setPath] = useState(briefing.path);
  const dirty = name !== briefing.name || path !== briefing.path;

  useEffect(() => {
    setName(briefing.name);
    setPath(briefing.path);
  }, [briefing.name, briefing.path]);

  async function save() {
    try {
      await updateBriefing(briefing.id, name, path);
      await onSaved();
    } catch (error) {
      onError((error as Error).message);
    }
  }

  async function remove() {
    if (!window.confirm(`Remove “${briefing.name}” from Vista? No files are deleted.`)) return;
    try {
      await removeBriefing(briefing.id);
      await onSaved();
    } catch (error) {
      onError((error as Error).message);
    }
  }

  return (
    <div className="briefing-row">
      <input
        className="briefing-name"
        value={name}
        placeholder="Policy Briefs"
        onChange={(e) => setName(e.target.value)}
      />
      <input
        className="briefing-path"
        value={path}
        placeholder="briefs/ai_policy/output"
        onChange={(e) => setPath(e.target.value)}
      />
      <button className="btn-outline" onClick={onBrowse} title="Browse the workspace">
        …
      </button>
      <button className="btn-outline" onClick={() => onMove(-1)} disabled={isFirst} title="Move up">
        ↑
      </button>
      <button className="btn-outline" onClick={() => onMove(1)} disabled={isLast} title="Move down">
        ↓
      </button>
      <button className="btn-primary" onClick={save} disabled={!dirty || !name.trim() || !path.trim()}>
        Save
      </button>
      <button className="btn-danger" onClick={remove}>
        Remove
      </button>
    </div>
  );
}
