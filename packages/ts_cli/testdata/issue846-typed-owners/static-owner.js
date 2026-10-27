export class Factory {
  /** @type {boolean} */
  static ready = true;
  /** @param {number} value */
  static create(value) {
    return { value };
  }
}
