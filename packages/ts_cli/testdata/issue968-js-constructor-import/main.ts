import { Box, Plain, StringBox } from './owner.js';

const numberValue: number = new Box(1).value;
const wrongString: string = new Box(1).value;
const wrongNumber: number = new StringBox(1).value;

// A JavaScript function's prototype is dynamic even when its constructed
// instances have inferred and instantiated members.
const genericPrototype: string = Box.prototype.value;
const inferredPrototype: number = StringBox.prototype.value;
const ordinaryPrototype: string = Plain.prototype.value;
const missingPrototypeMember: number = Plain.prototype.missing;

void [numberValue, wrongString, wrongNumber, genericPrototype, inferredPrototype, ordinaryPrototype, missingPrototypeMember];
