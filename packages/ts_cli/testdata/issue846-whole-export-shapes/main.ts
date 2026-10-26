import text from "./text.js";
import list from "./list.js";
import increment from "./increment.js";
import values from "./map.js";

const wrongText: number = text;
const wrongItem: string = list[0];
const wrongResult: string = increment(1);
increment("wrong");
list.push("wrong");
values.set("ready", "wrong");
void [wrongText, wrongItem, wrongResult];
