import { local, nested } from "m1";

const localNumber: number = local;
const localString: string = local;
const nestedNumber: number = nested;
const nestedString: string = nested;
void [localNumber, localString, nestedNumber, nestedString];
