/**
 * Typed client for the Vista API.
 *
 * The Ark bearer token never reaches this code — the Vista server holds it
 * and this client authenticates with its own session token.
 */

/**
 * Where the API lives.
 *
 * With no explicit VITE_API_BASE, the address is derived from the host the
 * page was loaded from. That way a single build works whether the client is
 * opened over loopback, a LAN address, or a Tailscale name — a baked-in
 * 127.0.0.1 would break the moment the page is opened from another device.
 */
function resolveApiBase(): string {
  const explicit = (import.meta.env.VITE_API_BASE as string | undefined)?.trim();
  if (explicit) return explicit.replace(/\/$/, "");

  const port = (import.meta.env.VITE_API_PORT as string | undefined)?.trim() || "8800";
  const { protocol, hostname } = window.location;
  return `${protocol}//${hostname}:${port}`;
}

const API_BASE: string = resolveApiBase();

const TOKEN_KEY = "vista.session";

export type User = {
  id: number;
  email: string;
  display_name: string;
  configured: boolean;
  ark_agent: string | null;
  notes_dir: string;
  briefings: Briefing[];
};

export type Briefing = { id: number; name: string; path: string };

export type Brief = {
  key: string;
  title: string;
  folder: string;
  date: string;
  date_source: "filename" | "mtime";
  modified: string;
  size: number;
  annotated: boolean;
  pdf_path: string | null;
  text_path: string | null;
  annotated_path: string | null;
  primary_path: string | null;
  primary_kind: "pdf" | "text";
};

export type Note = {
  name: string;
  title: string;
  path: string;
  size: number;
  modified: string;
  preview: string;
};

export type SortField = "date" | "name";
export type SortOrder = "asc" | "desc";

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export function getToken(): string | null {
  return localStorage.getItem(TOKEN_KEY);
}

export function setToken(token: string | null): void {
  if (token) localStorage.setItem(TOKEN_KEY, token);
  else localStorage.removeItem(TOKEN_KEY);
}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers);
  const token = getToken();
  if (token) headers.set("Authorization", `Bearer ${token}`);
  if (init.body && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }

  let response: Response;
  try {
    response = await fetch(`${API_BASE}${path}`, { ...init, headers });
  } catch {
    throw new ApiError(0, "Could not reach the Vista server.");
  }

  if (response.status === 401) {
    setToken(null);
    throw new ApiError(401, "Your session has expired. Sign in again.");
  }
  if (!response.ok) {
    let detail = `Request failed (${response.status})`;
    try {
      const body = await response.json();
      if (body?.detail) detail = String(body.detail);
    } catch {
      /* keep the default */
    }
    throw new ApiError(response.status, detail);
  }
  if (response.status === 204) return undefined as T;
  return (await response.json()) as T;
}

export async function login(email: string, password: string): Promise<User> {
  const body = await request<{ token: string; user: User }>("/api/auth/login", {
    method: "POST",
    body: JSON.stringify({ email, password }),
  });
  setToken(body.token);
  return me();
}

export function logout(): void {
  setToken(null);
}

export const me = () => request<User>("/api/me");

export const listBriefs = (briefingId: number, sort: SortField, order: SortOrder) =>
  request<{ briefing: Briefing; briefs: Brief[] }>(
    `/api/briefings/${briefingId}/briefs?sort=${sort}&order=${order}`,
  );

/**
 * Fetch a brief's bytes as an object URL.
 *
 * The API needs an Authorization header, which `<embed src>` cannot send, so
 * the file is fetched here and handed to the viewer as a blob. Callers must
 * revoke the URL when done.
 */
export async function fetchBriefFile(
  briefingId: number,
  path: string,
): Promise<{ url: string; blob: Blob }> {
  const headers = new Headers();
  const token = getToken();
  if (token) headers.set("Authorization", `Bearer ${token}`);

  const response = await fetch(
    `${API_BASE}/api/briefings/${briefingId}/file?path=${encodeURIComponent(path)}`,
    { headers },
  );
  if (!response.ok) {
    throw new ApiError(response.status, `Could not open this brief (${response.status})`);
  }
  const blob = await response.blob();
  return { url: URL.createObjectURL(blob), blob };
}

export const listNotes = (sort: SortField, order: SortOrder) =>
  request<{ notes: Note[]; notes_dir: string }>(
    `/api/notes?sort=${sort}&order=${order}&preview=true`,
  );

export const readNote = (name: string) =>
  request<{ name: string; title: string; content: string }>(
    `/api/notes/item?name=${encodeURIComponent(name)}`,
  );

export const createNote = (title: string, content: string) =>
  request<{ name: string; title: string }>("/api/notes", {
    method: "POST",
    body: JSON.stringify({ title, content }),
  });

export const saveNote = (name: string, content: string) =>
  request<{ ok: boolean }>(`/api/notes/item?name=${encodeURIComponent(name)}`, {
    method: "PUT",
    body: JSON.stringify({ content }),
  });

export const renameNote = (name: string, title: string) =>
  request<{ name: string; title: string }>(
    `/api/notes/item/rename?name=${encodeURIComponent(name)}`,
    { method: "POST", body: JSON.stringify({ title }) },
  );

export const deleteNote = (name: string) =>
  request<{ ok: boolean }>(`/api/notes/item?name=${encodeURIComponent(name)}`, {
    method: "DELETE",
  });

// --- settings --------------------------------------------------------------

export type Settings = {
  ark: {
    base_url: string;
    agent: string;
    /** The token itself is never sent to a client — only whether one exists. */
    token_set: boolean;
  };
  notes_dir: string;
  briefings: Briefing[];
};

export type ConnectionResult = { connected: boolean; detail: string };

export type WorkspaceListing = {
  path: string;
  parent: string | null;
  directories: { name: string; path: string }[];
  file_count: number;
  pdf_count: number;
};

export const getSettings = () => request<Settings>("/api/settings");

type ArkPayload = { base_url: string; agent: string; token?: string };

export const testArkConnection = (payload: ArkPayload) =>
  request<ConnectionResult>("/api/settings/ark/test", {
    method: "POST",
    body: JSON.stringify(payload),
  });

export const saveArkConnection = (payload: ArkPayload) =>
  request<ConnectionResult & { ok: boolean }>("/api/settings/ark", {
    method: "PUT",
    body: JSON.stringify(payload),
  });

export const saveNotesDir = (notes_dir: string) =>
  request<{ notes_dir: string }>("/api/settings/notes", {
    method: "PUT",
    body: JSON.stringify({ notes_dir }),
  });

export const browseWorkspace = (path: string) =>
  request<WorkspaceListing>(`/api/settings/workspace?path=${encodeURIComponent(path)}`);

export const addBriefing = (name: string, path: string) =>
  request<Briefing>("/api/briefings", {
    method: "POST",
    body: JSON.stringify({ name, path }),
  });

export const updateBriefing = (id: number, name: string, path: string) =>
  request<Briefing>(`/api/briefings/${id}`, {
    method: "PUT",
    body: JSON.stringify({ name, path }),
  });

export const removeBriefing = (id: number) =>
  request<{ ok: boolean }>(`/api/briefings/${id}`, { method: "DELETE" });

export const reorderBriefings = (ids: number[]) =>
  request<{ briefings: Briefing[] }>("/api/briefings/reorder", {
    method: "POST",
    body: JSON.stringify({ ids }),
  });
