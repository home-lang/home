import { readonlyStrings, readonlyNumbers } from "./owner.js";

readonlyStrings["new"] = 2;
readonlyStrings[0] = 2;
readonlyStrings["0"] = 2;
readonlyNumbers["new"] = 2;
readonlyNumbers[0] = 2;
readonlyNumbers["0"] = 2;
const stringRead: number = readonlyStrings["new"];
const numberRead: number = readonlyNumbers[0];
void stringRead;
void numberRead;
