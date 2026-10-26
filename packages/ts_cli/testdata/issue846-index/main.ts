import { counts, labels } from "./owner.js";

const known: number = counts.known;
const dynamic: number = counts["other"];
counts["other"] = "wrong";
counts.known = "wrong";
const label: string = labels[0];
labels[1] = 42;
void known;
void dynamic;
void label;
