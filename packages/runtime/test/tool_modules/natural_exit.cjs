const expected = Number(process.argv[2]);
process.exitCode = expected;
process.on("exit", function(code) {
  if (code !== expected || !process._exiting) throw new Error("wrong natural exit event");
  console.log("OK home-tool natural exit");
});
