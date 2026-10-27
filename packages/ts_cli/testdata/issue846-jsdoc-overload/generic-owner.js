/**
 * @template T
 * @overload
 * @param {T[]} value
 * @returns {T}
 *
 * @overload
 * @param {string} value
 * @returns {string}
 *
 * @param {any} value
 * @returns {any}
 */
export function first(value) {
  return Array.isArray(value) ? value[0] : value;
}
