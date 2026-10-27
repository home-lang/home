export class Counter {
  /** @type {string} */
  value = '';
  /** @param {string} delta */
  add(delta) {
    this.value += delta;
    return this.value;
  }
}
