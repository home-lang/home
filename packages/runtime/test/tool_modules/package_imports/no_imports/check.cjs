let failed = false;
try { require("#value"); } catch { failed = true; }
module.exports = failed;
