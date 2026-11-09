function require() { return 1; }
function exports() { return 2; }
function __filename() { return 3; }
function __dirname() { return 4; }
export const result = [require(), exports(), __filename(), __dirname()];
