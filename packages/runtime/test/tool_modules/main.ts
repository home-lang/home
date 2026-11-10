import { packageValue } from "home-tool-smoke-package";
import "./comparison_bounds";
import "./ternary_asi_arrows";
import "./nested_arrow_returns";
import "./buffer_integer_reads";
import "./node_inflate_contract.mjs";

if (packageValue !== 42) {
  throw new Error("Home did not resolve the nearest node_modules package");
}
