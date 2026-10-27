import { record } from "./owner.js";

const id: number = record.id;
record.id = 2;
record.label = 1;
record.optional = "bad";
const required: boolean = record.optional;
record.extra = 1;
void [id, required];
