import { payload } from "./union-owner.js";

payload.choice = true;
payload.maybe = false;
const booleanChoice: boolean = payload.choice;
const requiredMaybe: number = payload.maybe;
void [booleanChoice, requiredMaybe];
