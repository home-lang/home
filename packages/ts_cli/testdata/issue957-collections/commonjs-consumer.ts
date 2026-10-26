import collections from "./commonjs.js";

collections.map.set("ready", "wrong");
collections.readonlyMap.set("ready", 2);
collections.set.add("wrong");
collections.readonlySet.add(2);
collections.weakMap.set({ id: 2 }, "wrong");
collections.weakSet.add("wrong");
