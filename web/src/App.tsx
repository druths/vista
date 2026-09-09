import { useCallback, useEffect, useState } from "react";
import { type User, getToken, logout, me } from "./api";
import { BriefsScreen } from "./Briefs";
import { Login } from "./Login";
import { NotesScreen } from "./Notes";
import { SettingsScreen } from "./Settings";

type View =
  | { screen: "briefs"; briefingId: number }
  | { screen: "notes" }
  | { screen: "settings" };

export function App() {
  const [user, setUser] = useState<User | null>(null);
  const [booting, setBooting] = useState(true);
  const [view, setView] = useState<View>({ screen: "notes" });
  const [error, setError] = useState("");

  // Restore a stored session on load so a refresh doesn't sign you out.
  useEffect(() => {
    if (!getToken()) {
      setBooting(false);
      return;
    }
    me()
      .then(signIn)
      .catch(() => setUser(null))
      .finally(() => setBooting(false));
  }, []);

  function signIn(next: User) {
    setUser(next);
    // A brand-new account has nowhere to go but Settings.
    setView(
      !next.configured
        ? { screen: "settings" }
        : next.briefings.length > 0
          ? { screen: "briefs", briefingId: next.briefings[0].id }
          : { screen: "notes" },
    );
  }

  // Settings changes the nav and the Ark connection, so reload the user
  // without disturbing the screen the person is on.
  const reloadUser = useCallback(async () => {
    try {
      setUser(await me());
    } catch (error) {
      setError((error as Error).message);
    }
  }, []);

  const handleError = useCallback((message: string) => setError(message), []);

  if (booting) return <div className="empty">Loading…</div>;
  if (!user) return <Login onSignedIn={signIn} />;

  const briefing =
    view.screen === "briefs"
      ? user.briefings.find((b) => b.id === view.briefingId) ?? null
      : null;

  return (
    <div className="shell">
      <nav className="sidebar">
        <div className="brand">
          <img className="brand-mark" src="/logo-512.png" alt="" width={26} height={26} />
          <div>
            Vista
            <span>{user.ark_agent ? `agent · ${user.ark_agent}` : "not connected"}</span>
          </div>
        </div>

        <div className="nav">
          <div className="nav-group-label">Briefs</div>
          {user.briefings.length === 0 ? (
            <div className="nav-item" style={{ fontSize: 13 }}>
              None configured
            </div>
          ) : (
            user.briefings.map((item) => (
              <button
                key={item.id}
                className={`nav-item nav-sub ${
                  view.screen === "briefs" && view.briefingId === item.id ? "active" : ""
                }`}
                onClick={() => {
                  setError("");
                  setView({ screen: "briefs", briefingId: item.id });
                }}
              >
                {item.name}
              </button>
            ))
          )}
        </div>

        <div className="nav">
          <button
            className={`nav-item ${view.screen === "notes" ? "active" : ""}`}
            onClick={() => {
              setError("");
              setView({ screen: "notes" });
            }}
          >
            Notes
          </button>
        </div>

        <div className="sidebar-foot">
          <button
            className={`nav-item ${view.screen === "settings" ? "active" : ""}`}
            onClick={() => {
              setError("");
              setView({ screen: "settings" });
            }}
          >
            Settings
          </button>
          <span>{user.display_name}</span>
          <button
            onClick={() => {
              logout();
              setUser(null);
            }}
          >
            Sign out
          </button>
        </div>
      </nav>

      <main className="main">
        {error && (
          <div className="error-bar">
            <span>{error}</span>
            <span className="spacer" />
            <button onClick={() => setError("")}>Dismiss</button>
          </div>
        )}

        {view.screen === "settings" ? (
          <SettingsScreen onChanged={reloadUser} onError={handleError} />
        ) : !user.configured ? (
          <div className="empty">
            <strong>This account isn’t connected to an Ark server yet</strong>
            <span>Add the server URL, agent, and token in Settings.</span>
            <button className="btn-primary" onClick={() => setView({ screen: "settings" })}>
              Open Settings
            </button>
          </div>
        ) : view.screen === "notes" ? (
          <NotesScreen onError={handleError} />
        ) : briefing ? (
          <BriefsScreen briefing={briefing} onError={handleError} />
        ) : (
          <div className="empty">
            <strong>No brief locations configured</strong>
            <span>Add one in Settings to start reading briefs.</span>
            <button className="btn-primary" onClick={() => setView({ screen: "settings" })}>
              Open Settings
            </button>
          </div>
        )}
      </main>
    </div>
  );
}
