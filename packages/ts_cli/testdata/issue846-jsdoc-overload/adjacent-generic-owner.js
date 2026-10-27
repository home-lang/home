/**
 * @template T
 * @overload
 * @param {T[]} value
 * @returns {T}
 */
/**
 * @template {string} U
 * @overload
 * @param {U} value
 * @returns {U}
 */
/**
 * @param {any} value
 * @returns {any}
 */
export function unwrap(value) {
  return Array.isArray(value) ? value[0] : value;
}
