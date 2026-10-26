import { map, readonlyMap, set, readonlySet, weakMap, weakSet } from "./esm.js";

map.set("ready", "wrong");
readonlyMap.set("ready", 2);
set.add("wrong");
readonlySet.add(2);
weakMap.set({ id: 2 }, "wrong");
weakSet.add("wrong");
