/** @template T @param {T} value */
export function Box(value) { this.value = value; }

/** @template T @param {T} value */
export function StringBox(value) { this.value = String(value); }

/** @param {number} value */
export function Plain(value) { this.value = value; }
