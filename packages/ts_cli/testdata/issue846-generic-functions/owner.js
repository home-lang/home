/**
 * @template T
 * @param {T} value
 * @returns {T}
 */
export function identity(value) {
  return value;
}

/**
 * @template {string | number} T
 * @param {T} value
 * @returns {T}
 */
export function constrained(value) {
  return value;
}

/** @type {number} */
export const ownerBad = identity('one');
