export class Counter {
  /** @type {number} */
  value = 0;

  /** @param {number} delta */
  add(delta) {
    this.value += delta;
    return this.value;
  }
}
