/**
 * Light/dark preference for the web client.
 *
 * Three-way rather than a toggle: "system" doesn't pick a side, it declines to
 * override, so the page follows the OS — including its automatic switch in the
 * evening. That's the default.
 *
 * The choice is per-browser rather than per-account: a laptop in light and a
 * phone in dark is a normal way to work, and appearance is a property of the
 * device you're reading on, not of who you are.
 */

export type Theme = "system" | "light" | "dark";

const STORAGE_KEY = "vista.theme";

export const THEMES: { value: Theme; label: string }[] = [
  { value: "system", label: "System" },
  { value: "light", label: "Light" },
  { value: "dark", label: "Dark" },
];

export function loadTheme(): Theme {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored === "light" || stored === "dark" || stored === "system") return stored;
  } catch {
    // Private browsing and blocked site data both throw here; the default is fine.
  }
  return "system";
}

/**
 * Apply a theme by stamping the root element. CSS keys off `data-theme`, and
 * its absence means "follow prefers-color-scheme".
 */
export function applyTheme(theme: Theme): void {
  const root = document.documentElement;
  if (theme === "system") root.removeAttribute("data-theme");
  else root.setAttribute("data-theme", theme);
}

export function saveTheme(theme: Theme): void {
  try {
    if (theme === "system") localStorage.removeItem(STORAGE_KEY);
    else localStorage.setItem(STORAGE_KEY, theme);
  } catch {
    // Not being able to remember the choice shouldn't stop it applying now.
  }
  applyTheme(theme);
}

/** What "system" currently resolves to, for labelling the setting. */
export function systemTheme(): "light" | "dark" {
  return window.matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}
