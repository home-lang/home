const s = "x";

// Each member TypeScript declares, called as declared.
const anchored: string = s.anchor("name");
const big: string = s.big();
const blink: string = s.blink();
const bold: string = s.bold();
const fixed: string = s.fixed();
const colored: string = s.fontcolor("red");
const sizedByNumber: string = s.fontsize(3);
const sizedByString: string = s.fontsize("3");
const italic: string = s.italics();
const linked: string = s.link("https://example.com");
const small: string = s.small();
const struck: string = s.strike();
const sub: string = s.sub();
const sup: string = s.sup();
const left: string = s.trimLeft();
const right: string = s.trimRight();

// Wrong arguments are still rejected.
const badAnchor = s.anchor(1);
const badColor = s.fontcolor(true);
const badSize = s.fontsize(false);
const badLink = s.link({});
const extra = s.bold(1);

// The results are strings, not `any`.
const notANumber: number = s.bold();

void anchored; void big; void blink; void bold; void fixed; void colored;
void sizedByNumber; void sizedByString; void italic; void linked; void small;
void struck; void sub; void sup; void left; void right; void badAnchor;
void badColor; void badSize; void badLink; void extra; void notANumber;
