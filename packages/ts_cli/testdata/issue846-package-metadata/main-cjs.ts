import { box } from "pkg-cjs";

const good: number = box.count;
const bad: string = box.count;
box.count = "wrong";

void [good, bad];
