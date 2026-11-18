/**
 * @template T
 * @param {T} value
 */
function Box(value) { this.value = value; }
new Box(1);
/** @extends {Box<{ claim: "no" | "yes" }>} */
class ClaimedBox extends Box {}
const valid = new ClaimedBox({ claim: "yes" });
valid.value.claim;
new ClaimedBox(0);
