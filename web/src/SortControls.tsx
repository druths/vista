import type { SortField, SortOrder } from "./api";

type Props = {
  sort: SortField;
  order: SortOrder;
  onChange: (sort: SortField, order: SortOrder) => void;
};

/** Sort picker shared by the Briefs and Notes screens. */
export function SortControls({ sort, order, onChange }: Props) {
  return (
    <div className="sort-controls">
      <label htmlFor="sort-field">Sort</label>
      <select
        id="sort-field"
        value={sort}
        onChange={(e) => onChange(e.target.value as SortField, order)}
      >
        <option value="date">Date</option>
        <option value="name">Name</option>
      </select>
      <button
        className="btn-outline"
        onClick={() => onChange(sort, order === "asc" ? "desc" : "asc")}
        title={order === "asc" ? "Ascending — click for descending" : "Descending — click for ascending"}
      >
        {order === "asc" ? "↑" : "↓"}
      </button>
    </div>
  );
}
