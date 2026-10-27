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

/**
 * @template T
 * @param {T} value
 */
export function inferred(value) {
  return value;
}

/**
 * @template T
 * @param {T} value
 */
export function boxed(value) {
  return { value };
}

/**
 * @template T
 * @param {T} value
 */
export function listed(value) {
  return [value];
}
