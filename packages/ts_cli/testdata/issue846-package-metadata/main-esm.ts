import { box } from "pkg-esm";

const good: number = box.count;
const bad: string = box.count;
box.count = "wrong";

void [good, bad];
