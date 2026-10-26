import { counts, labels, symbolCounts } from "./owner.js";

const known: number = counts.known;
const dynamic: number = counts["other"];
counts["other"] = "wrong";
counts.known = "wrong";
const label: string = labels[0];
labels[1] = 42;
declare const key: symbol;
const symbolRead: number = symbolCounts[key];
symbolCounts[key] = "wrong";
void known;
void dynamic;
void label;
void symbolRead;
