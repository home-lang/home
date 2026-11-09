import { packageValue } from "home-tool-smoke-package";
import "./comparison_bounds";

if (packageValue !== 42) {
  throw new Error("Home did not resolve the nearest node_modules package");
}
