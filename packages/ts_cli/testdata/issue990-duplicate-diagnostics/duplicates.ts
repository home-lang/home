// A tuple-typed target behind an object-literal property or an array literal
// element is reached by more than one traversal, so the same mismatch was
// reported once per path — and the paths double with each nesting level.
const property: { v: [string, number] } = { v: [1, 2] };
const nested: { v: { w: [string, number] } } = { v: { w: [1, 2] } };
const element: [string, number][] = [[1, 2]];
const deepElement: [string, number][][] = [[[1, 2]]];

// An array-typed property is reported once either way: the control that
// shows the duplication is specific to a tuple target.
const arrayProperty: { v: number[] } = { v: ["x"] };

// Clean controls.
const okProperty: { v: [string, number] } = { v: ["x", 2] };
const okElement: [string, number][] = [["x", 2]];
const okNested: { v: { w: [string, number] } } = { v: { w: ["x", 2] } };

void property;
void nested;
void element;
void deepElement;
void arrayProperty;
void okProperty;
void okElement;
void okNested;
