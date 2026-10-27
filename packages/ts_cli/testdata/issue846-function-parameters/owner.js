/**
 * @param {number} count
 * @param {string} [suffix]
 * @returns {string}
 */
export function label(count, suffix = '') {
  return `${count}${suffix}`;
}

/**
 * @param {number} count
 * @param {...string} parts
 * @returns {string}
 */
export function join(count, ...parts) {
  return `${count}${parts.join('')}`;
}
