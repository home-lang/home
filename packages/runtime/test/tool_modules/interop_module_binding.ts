import module from "./interop_commonjs.cjs";
const __home_module_0 = 1;
function nested() {
  const __home_module_1 = 2;
  return __home_module_0 + __home_module_1;
}
if (nested() !== 3) throw new Error("host module binding shadowed source identifiers");
export default module.value;
export const named = module.value;
