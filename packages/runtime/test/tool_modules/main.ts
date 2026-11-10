import { packageValue } from "home-tool-smoke-package";
import "./comparison_bounds";
import "./ternary_asi_arrows";
import "./nested_arrow_returns";
import "./buffer_integer_reads";
import "./node_inflate_contract.mjs";
import "./node_hash_contract.mjs";
import "./buffer_limits.mjs";
import "./buffer_limit_descriptors.mjs";

if (packageValue !== 42) {
  throw new Error("Home did not resolve the nearest node_modules package");
}
import "./esm_strict.mjs";
import "./esm_strict_async.mjs";
import "./inflate_output_limit.mjs";
import "./export_precedence/entry.mjs";
import "./ternary_compound_heads.mjs";
import "./forof_sequence.mjs";
import "./stack_origins/entry.mjs";
import "./node_random_uuid.mjs";
import "./node_rmdir.mjs";
import "./node_mkdtemp.mjs";
import "./node_sync_fs.mjs";
import "./node_available_parallelism.mjs";
